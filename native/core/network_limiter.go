package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"time"
)

type requestGate struct {
	busy      bool
	lastStart time.Time
}

type requestBackoff struct {
	host   string
	until  time.Time
	status int
	reason string
}

func (backoff *requestBackoff) Error() string {
	reason := ""
	if backoff.reason != "" {
		reason = "：" + backoff.reason
	}
	seconds := max(1, int(time.Until(backoff.until).Seconds()+0.999))
	return fmt.Sprintf("%s HTTP %d%s，请在 %d 秒后重试", backoff.host, backoff.status, reason, seconds)
}

func catalogResponseBlockReason(response *http.Response, body []byte) string {
	if len(body) > 64*1024 {
		body = body[:64*1024]
	}
	page := strings.ToLower(string(body))
	reason := ""
	if strings.Contains(page, "cloudflare") && (strings.Contains(page, "sorry, you have been blocked") || strings.Contains(page, "you are unable to access")) {
		reason = "Cloudflare 拒绝了当前请求"
	} else if strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge") || strings.Contains(page, "_cf_chl_opt") || strings.Contains(page, "<title>just a moment") && strings.Contains(page, "cloudflare") {
		reason = "站点要求浏览器验证，当前请求无法通过"
	}
	return reason
}

func (d *Downloader) catalogResponseError(request *http.Request, response *http.Response, body []byte) error {
	reason := catalogResponseBlockReason(response, body)
	if d.limiter != nil && reason != "" && response.StatusCode >= 200 && response.StatusCode < 300 {
		d.limiter.observeBlock(request, response)
	}

	host := strings.ToLower(request.URL.Hostname())
	if d.limiter != nil && (response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusTooManyRequests || reason != "") {
		d.limiter.mu.Lock()
		backoffs := d.limiter.backoffs
		if isolatedBackoff(request.Context()) &&
			!(response.StatusCode == http.StatusTooManyRequests && rateLimitBackoffShared(request.Context())) {
			backoffs = d.limiter.backgroundBackoffs
		}
		if previous := backoffs[host]; previous != nil && previous.status == response.StatusCode {
			updated := *previous
			if reason != "" {
				updated.reason = reason
			}
			backoffs[host] = &updated
			d.limiter.mu.Unlock()
			return &updated
		}
		d.limiter.mu.Unlock()
	}
	if reason != "" {
		return fmt.Errorf("%s HTTP %d：%s", host, response.StatusCode, reason)
	}
	return fmt.Errorf("%s HTTP %d", host, response.StatusCode)
}

type requestLimiter struct {
	concurrency        int
	active             int
	foregroundWaiting  int
	lastForeground     time.Time
	interval           time.Duration
	mu                 sync.Mutex
	gates              map[string]*requestGate
	backoffs           map[string]*requestBackoff
	backgroundBackoffs map[string]*requestBackoff
	blocks             map[string]*requestBlock
	changed            chan struct{}
}

// requestBlock 记录某域名的连续失败计数（达到阈值才触发 host 级暂停）。
type requestBlock struct {
	count int
	at    time.Time
}

type backgroundCatalogKey struct{}

// backgroundBackoffKey 标记「冷却隔离」车道：请求失败只记进自己的冷却表，
// 不污染前台冷却表。给详情后台预取用——预取的失败不该让用户点播同源剧时挨罚。
// 与 backgroundCatalogKey 的区别：本车道不让位给前台（低优先级会让预取被
// 滚屏时的封面请求饿死），仍正常排队，只隔离冷却表。
type backgroundBackoffKey struct{}

type probeBackoffSkipKey struct{}

// isolatedBackoff：请求失败是否只记进自己的冷却表。
//   - backgroundCatalogKey（预载/补齐/弹幕等纯后台）：记进后台表；
//   - backgroundBackoffKey（详情预取）：同样记进后台表；
//   - 其余（前台请求）：记进前台表。
func isolatedBackoff(ctx context.Context) bool {
	if v, _ := ctx.Value(backgroundBackoffKey{}).(bool); v {
		return true
	}
	v, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	return v
}

// rateLimitBackoffShared：限流（429）是否要让前台一起冷却。
// 纯后台请求（预载/补齐/弹幕）遇 429 仍冷却所有人，避免继续加压；
// 详情预取只隔离自己的冷却——预取被限流不该把用户点播一起卡住。
func rateLimitBackoffShared(ctx context.Context) bool {
	if v, _ := ctx.Value(backgroundBackoffKey{}).(bool); v {
		return false
	}
	v, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	return v
}

func withoutBackoffRecording(ctx context.Context) context.Context {
	return context.WithValue(ctx, probeBackoffSkipKey{}, true)
}

func newRequestLimiter(concurrency int, interval time.Duration) *requestLimiter {
	if concurrency < 1 {
		concurrency = 1
	}
	return &requestLimiter{concurrency: concurrency, interval: interval, gates: map[string]*requestGate{}, backoffs: map[string]*requestBackoff{}, backgroundBackoffs: map[string]*requestBackoff{}, changed: make(chan struct{})}
}

func (limiter *requestLimiter) notifyLocked() {
	close(limiter.changed)
	limiter.changed = make(chan struct{})
}

func (limiter *requestLimiter) acquire(ctx context.Context, request *http.Request) (func(), error) {
	background, _ := ctx.Value(backgroundCatalogKey{}).(bool)
	host := strings.ToLower(request.URL.Hostname())
	source := providerSourceForURL(request.URL.String())
	if source == "" {
		source = host
		if strings.HasSuffix(host, ".cloudfront.net") {
			source = "cloudfront"
		}
	}
	limiter.mu.Lock()
	if !background {
		limiter.foregroundWaiting++
		defer func() {
			limiter.mu.Lock()
			limiter.foregroundWaiting--
			limiter.notifyLocked()
			limiter.mu.Unlock()
		}()
	}
	gate := limiter.gates[source]
	if gate == nil {
		gate = &requestGate{}
		limiter.gates[source] = gate
	}
	limiter.mu.Unlock()
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		limiter.mu.Lock()
		if backoff := limiter.backoffs[host]; backoff != nil && time.Now().Before(backoff.until) {
			limiter.mu.Unlock()
			return nil, backoff
		}
		if backoff := limiter.backgroundBackoffs[host]; isolatedBackoff(ctx) && backoff != nil && time.Now().Before(backoff.until) {
			limiter.mu.Unlock()
			return nil, backoff
		}
		delay := time.Until(gate.lastStart.Add(limiter.interval))
		if background {

			if idleDelay := time.Until(limiter.lastForeground.Add(limiter.interval)); idleDelay > delay {
				delay = idleDelay
			}
		}
		lowPriorityReady := !background || limiter.foregroundWaiting == 0 && limiter.active == 0
		if lowPriorityReady && !gate.busy && limiter.active < limiter.concurrency && delay <= 0 {
			gate.busy = true
			gate.lastStart = time.Now()
			limiter.active++
			limiter.mu.Unlock()
			break
		}
		changed := limiter.changed
		limiter.mu.Unlock()
		var timer *time.Timer
		var deadline <-chan time.Time
		if delay > 0 {
			timer = time.NewTimer(delay)
			deadline = timer.C
		}
		select {
		case <-changed:
		case <-deadline:
		case <-ctx.Done():
		}
		if timer != nil {
			timer.Stop()
		}
	}
	var once sync.Once
	return func() {
		once.Do(func() {
			limiter.mu.Lock()
			limiter.active--
			gate.busy = false
			if !background {
				limiter.lastForeground = time.Now()
			}
			limiter.notifyLocked()
			limiter.mu.Unlock()
		})
	}, nil
}

func (limiter *requestLimiter) observe(request *http.Request, response *http.Response) {
	if request.Context().Value(probeBackoffSkipKey{}) != nil {
		return
	}
	if response.StatusCode != http.StatusForbidden && response.StatusCode != http.StatusTooManyRequests && !strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge") {
		return
	}
	limiter.observeBlock(request, response)
}

// observeMedia 用于媒体分片请求。媒体 CDN 偶发 403 是常态（热点防盗链、
// 瞬时限流），应由播放器的换址/重试处理；若像目录请求那样记成 host 级
// 1 分钟退避，会把同一个 CDN 上的后续分片全部冻住，表现为播放中途断链、
// 恢复始终失败。与上游一致：媒体 403（非 Cloudflare 挑战）不记退避。
func (limiter *requestLimiter) observeMedia(request *http.Request, response *http.Response) {
	if response.StatusCode == http.StatusForbidden && !strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge") {
		return
	}
	limiter.observe(request, response)
}

// catalogBlockThreshold 是同一域名触发 host 级暂停前需要的连续失败次数。
// 上游同款：站点偶发一次 403/429 只是瞬时风控或单条链接失效，不该把该
// 域名后续全部请求冻结一分钟；连续多次才暂停。
const catalogBlockThreshold = 3

// catalogBlockWindow 是连续失败的计数窗口，超过则重新计数。
const catalogBlockWindow = 2 * time.Minute

func (limiter *requestLimiter) observeBlock(request *http.Request, response *http.Response) {
	delay := time.Minute
	if seconds, err := strconv.Atoi(response.Header.Get("Retry-After")); err == nil && seconds > 0 {
		delay = time.Duration(seconds) * time.Second
	} else if until, err := http.ParseTime(response.Header.Get("Retry-After")); err == nil && time.Until(until) > 0 {
		delay = time.Until(until)
	}
	if delay > 30*time.Minute {
		delay = 30 * time.Minute
	}
	host := strings.ToLower(request.URL.Hostname())
	limiter.mu.Lock()
	backoffs := limiter.backoffs
	if isolatedBackoff(request.Context()) &&
		!(response.StatusCode == http.StatusTooManyRequests && rateLimitBackoffShared(request.Context())) {
		backoffs = limiter.backgroundBackoffs
	}
	// 立即冻结的两种情况：429（站点明确限流，通常带 Retry-After）与
	// Cloudflare 挑战（明确的"你是机器人"信号）。普通 403 才需要连续失败——
	// 站点偶发一次 403 只是瞬时风控或单条链接失效，不该把该域名后续全部
	// 请求冻结一分钟。
	challenge := strings.EqualFold(response.Header.Get("Cf-Mitigated"), "challenge")
	if response.StatusCode != http.StatusTooManyRequests && !challenge {
		now := time.Now()
		if limiter.blocks == nil {
			limiter.blocks = map[string]*requestBlock{}
		}
		block := limiter.blocks[host]
		if block == nil || now.Sub(block.at) > catalogBlockWindow {
			block = &requestBlock{}
			limiter.blocks[host] = block
		}
		block.at = now
		block.count++
		if block.count < catalogBlockThreshold {
			limiter.notifyLocked()
			limiter.mu.Unlock()
			return
		}
		delete(limiter.blocks, host)
	}
	backoffs[host] = &requestBackoff{host: host, until: time.Now().Add(delay), status: response.StatusCode}
	limiter.notifyLocked()
	limiter.mu.Unlock()
}

type limitedResponseBody struct {
	io.ReadCloser
	release func()
}

func (body *limitedResponseBody) Close() error {
	err := body.ReadCloser.Close()
	body.release()
	return err
}

func (d *Downloader) doCatalogRequestWithTimeout(request *http.Request, timeout time.Duration) (*http.Response, error) {
	return d.doPreparedCatalogRequest(request, timeout, nil)
}

func (d *Downloader) doPreparedCatalogRequest(request *http.Request, timeout time.Duration, prepare func(*http.Request)) (*http.Response, error) {
	if background, _ := request.Context().Value(backgroundCatalogKey{}).(bool); background && (timeout <= 0 || timeout > 8*time.Second) {
		timeout = 8 * time.Second
	}
	// 限流器缺失（测试里手工构造的 Downloader）时跳过限流，不至于空指针。
	release := func() {}
	if d.limiter != nil {
		acquired, err := d.limiter.acquire(request.Context(), request)
		if err != nil {
			return nil, err
		}
		release = acquired
	}
	cancel := func() {}
	if timeout > 0 {
		var ctx context.Context
		ctx, cancel = context.WithTimeout(request.Context(), timeout)
		request = request.WithContext(ctx)
	}
	if prepare != nil {
		prepare(request)
	}
	response, err := d.client.Do(request)
	if err != nil {
		cancel()
		release()
		return nil, err
	}
	if d.limiter != nil {
		d.limiter.observe(request, response)
	}
	observeSourceResponse(request.Context(), response)
	response.Body = &limitedResponseBody{ReadCloser: response.Body, release: func() { cancel(); release() }}
	return response, nil
}
