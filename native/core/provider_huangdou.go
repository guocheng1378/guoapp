package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	huangdouBaseURL    = "https://seiopcc.icu"
	huangdouVersion    = "2.0.0"
	huangdouDeviceType = "web"
)

// huangdouPlatformKeys — 黄豆短剧加密平台 key 列表（xiadasy/qx-scripts 2026-09 V6）。
// 不同镜像节点可能用不同 key；请求/响应必须用同一个 key 加解密。
// 首 key 为主用，其余 key 在第一个 key 解密失败时降级尝试。
var huangdouPlatformKeys = []string{
	"7961beb44246e3012ce228d6b5ced05a",
	"6be13f303785864aac6a6cc2cb3c9dc6",
	"c10ca2986a31fb46d4481ce8631c2725",
}

// huangdouAPIMirrors — 黄豆短剧站源镜像池（2026-10 双线路全活）。
// 线路 A：hdou api.js（CF Pages 版）里的 10 个 host，由 Cloudflare 代理后端。
// 线路 B：d.txt 解密出的 7 个新 mirror（seiopcc/halobloom/mintgate 等）。
// 所有 17 个 host 均存活：POST /api/drama/{navList,list,rank,detail,play} 加密 API + GET /api/drama/hls/{id}/{seq}/play.m3u8?line=free|vip 直出。
// 并行探测，第一个成功胜出。
var huangdouAPIMirrors = []string{
	// 线路 A：hdou api.js（CF Pages）
	"ahgehbki.cc",
	"jpgrmkkn.cc",
	"ufufukpq.cc",
	"nhuhkizw.cc",
	"hddj01.com",
	"hddj02.com",
	"hddj03.com",
	"hddj08.com",
	"hddj09.com",
	"hddj22.com",
	// 线路 B：d.txt 解密新 mirror
	"seiopcc.icu",
	"halobloom.cc",
	"mintgate.top",
	"vtqzwlyffd.cc",
	"bikhonslkt.cc",
	"mclkhiskya.cc",
	"momodrift.top",
}

// huangdouQuickHosts — 并行快速探测池（17 个 host 双线路）。
// 不共享 context，各自独立超时，第一个成功胜出。
func huangdouQuickHosts() []string {
	return huangdouAPIMirrors
}

type huangdouAPIClient struct {
	d         *Downloader
	host      string
	sessionID string
	deviceID  string
}

func newHuangdouAPIClient(d *Downloader) *huangdouAPIClient {
	id := randomHex(16)
	if id == "" {
		id = strconv.FormatInt(time.Now().UnixNano(), 16)
	}
	host := d.providerBaseURL(sourceHuangdou)
	d.providerMu.Lock()
	if preferred := d.providerHosts[sourceHuangdou]; preferred != "" {
		host = preferred
	}
	d.providerMu.Unlock()
	return &huangdouAPIClient{d: d, host: host, sessionID: id, deviceID: id}
}

func (d *Downloader) fetchHuangdouChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	sourceID = strings.TrimPrefix(strings.TrimSpace(sourceID), "rp_")
	data, err := d.huangdouDetail(ctx, sourceID)
	if err != nil {
		return "", nil, err
	}
	title := firstNonEmpty(mapString(data, "name", "title", "t"), sourceID)
	episodes := huangdouList(data["episodes"])
	count := atoiDefault(firstNonEmpty(mapString(data, "episode_count"), mapString(data, "free_episodes")), len(episodes))
	if count <= 0 {
		count = len(episodes)
	}
	if count <= 0 || count > 10000 {
		return title, nil, fmt.Errorf("黄豆返回了无效集数: %d", count)
	}
	chapters := make([]Chapter, 0, count)
	if len(episodes) > 0 {
		for i, ep := range episodes {
			seq := atoiDefault(firstNonEmpty(mapString(ep, "seq"), mapString(ep, "episode"), mapString(ep, "ep")), i+1)
			if seq <= 0 {
				seq = i + 1
			}
			titleText := firstNonEmpty(mapString(ep, "name", "title"), fmt.Sprintf("第%d集", seq))
			chapters = append(chapters, Chapter{VIP: huangdouEpisodeVIP(data, ep, seq), ID: providerChapterID(sourceHuangdou, sourceID, strconv.Itoa(seq)), Source: sourceHuangdou, Title: titleText, CurrentEpisode: rawEpisode(seq)})
		}
	} else {
		for i := 1; i <= count; i++ {
			chapters = append(chapters, Chapter{VIP: huangdouEpisodeVIP(data, nil, i), ID: providerChapterID(sourceHuangdou, sourceID, strconv.Itoa(i)), Source: sourceHuangdou, Title: fmt.Sprintf("第%d集", i), CurrentEpisode: rawEpisode(i)})
		}
	}
	sortProviderChapters(chapters)
	return title, uniqueChapters(chapters), nil
}

func (d *Downloader) resolveHuangdouPlayback(ctx context.Context, client *huangdouAPIClient, sourceID string, seq int) (providerMedia, error) {
	// 先试 free hls（surge-modules 端到端验证不鉴权线路，付费集也能播）。
	if freeMedia, err := d.huangdouFreeHLSPlayback(ctx, sourceID, seq); err == nil {
		return freeMedia, nil
	}

	var decoded any
	if err := client.call(ctx, "/drama/play", map[string]any{"id": sourceID, "seq": strconv.Itoa(seq)}, &decoded); err != nil {
		return providerMedia{}, err
	}
	data := huangdouDataMap(decoded)
	media := firstNonEmpty(mapString(data, "m3u8"), mapString(data, "url"), mapString(data, "play_url"), mapString(data, "playUrl"))
	if huangdouPreviewOnly(data, media, client.host) {
		// preview 时再试一次 free hls 兜底
		if freeMedia, err := d.huangdouFreeHLSPlayback(ctx, sourceID, seq); err == nil {
			return freeMedia, nil
		}
		return providerMedia{}, &huangdouAPIError{code: "preview", message: "黄豆仅提供试看，未取得该集正片；不会把试看内容当作完整分集"}
	}
	if media == "" {
		if freeMedia, err := d.huangdouFreeHLSPlayback(ctx, sourceID, seq); err == nil {
			return freeMedia, nil
		}
		return providerMedia{}, errors.New("黄豆未提供有效的播放地址，备用播放列表也不可用")
	}
	media = resolveProviderURL(client.host+"/", media)
	if !isProviderHTTPMediaURL(media) {
		return providerMedia{}, errors.New("黄豆播放地址不是 HTTP/HTTPS URL")
	}
	result := providerMedia{URL: media, Referer: client.host + "/home"}
	if rawKey := mapString(data, "hls_key"); rawKey != "" {
		key, err := hex.DecodeString(rawKey)
		if err != nil || len(key) != aes.BlockSize {
			return providerMedia{}, errors.New("黄豆返回了无效的 HLS 密钥")
		}
		result.HLSKey = key
	}
	if duration, err := strconv.ParseFloat(mapString(data, "duration"), 64); err == nil && duration > 0 {
		result.Duration = time.Duration(duration * float64(time.Second))
	}
	return result, nil
}

// huangdouFreeHLSPlayback — 并行试 huangdouAPIMirrors 里所有 host 的 free hls 线路，
// 直出 GET /api/drama/hls/{id}/{seq}/play.m3u8?line=free（所有 17 个 host 上均存活）。
// 先于加密 API 尝试，4s 内返回第一个成功的 m3u8。
func (d *Downloader) huangdouFreeHLSPlayback(ctx context.Context, sourceID string, seq int) (providerMedia, error) {
	sourceID = strings.TrimPrefix(strings.TrimSpace(sourceID), "rp_")
	hosts := huangdouAPIMirrors // 全部 17 个 host 上 free hls 均存活
	resultCh := make(chan providerMedia, len(hosts))
	for _, h := range hosts {
		go func(h string) {
			u := fmt.Sprintf("https://%s/api/drama/hls/%s/%d/play.m3u8?line=free", h, url.PathEscape(sourceID), seq)
			pl, err := d.fetchProviderText(ctx, u, "https://"+h+"/home")
			if err == nil && strings.HasPrefix(strings.TrimSpace(pl), "#EXTM3U") {
				select {
				case resultCh <- providerMedia{URL: u, Referer: "https://" + h + "/home"}:
				default:
				}
			}
		}(h)
	}
	for i := 0; i < len(hosts); i++ {
		select {
		case m := <-resultCh:
			return m, nil
		case <-time.After(15 * time.Second):
			return providerMedia{}, errors.New("free hls 线路探测超时")
		}
	}
	return providerMedia{}, errors.New("free hls 线路不可用")
}

// call 并行探测全部 mirror host（各自独立超时），第一个成功的胜出。
// 单个 host 被限流（403/429/退避）只跳过该节点，不影响其他节点；
// 只有全部节点都受限时才返回池级错误，并带上最短的重试时间。
// 只有用户手动配置 HuangdouURL 时才走串行单 host。
func (c *huangdouAPIClient) call(ctx context.Context, path string, data map[string]any, out *any) error {
	if c.d.cfg.HuangdouURL != "" {
		return c.callOnceAllKeys(ctx, path, data, out)
	}
	quick := huangdouQuickHosts()
	resultCh := make(chan error, len(quick))
	var winner sync.Once
	for _, host := range quick {
		go func(h string) {
			cc := *c
			cc.host = "https://" + h
			var dec any
			err := cc.callOnceAllKeys(ctx, path, data, &dec)
			if err == nil {
				winner.Do(func() {
					*out = dec
					c.d.providerMu.Lock()
					c.d.providerHosts[sourceHuangdou] = cc.host
					c.d.providerMu.Unlock()
				})
			}
			resultCh <- err
		}(host)
	}
	var (
		lastErr  error
		failures int
		blocked  int
		retryAt  time.Time
	)
	for failures < len(quick) {
		select {
		case err := <-resultCh:
			if err == nil {
				return nil
			}
			lastErr = err
			failures++
			if until, limited := huangdouRateLimitedUntil(err); limited {
				blocked++
				if !until.IsZero() && (retryAt.IsZero() || until.Before(retryAt)) {
					retryAt = until
				}
			}
		case <-time.After(20 * time.Second):
			if blocked > 0 {
				return &huangdouPoolLimitError{hosts: len(quick), retryAt: retryAt}
			}
			if lastErr != nil {
				return lastErr
			}
			return fmt.Errorf("黄豆节点探测超时（20s）")
		}
	}
	// 全部节点都受限：说明整池被站点限流，而不是单个镜像节点的问题
	if blocked == len(quick) {
		return &huangdouPoolLimitError{hosts: len(quick), retryAt: retryAt}
	}
	if blocked > 0 && lastErr != nil {
		return fmt.Errorf("黄豆 %d/%d 个镜像节点被限流，其余节点不可用：%w", blocked, len(quick), lastErr)
	}
	if lastErr != nil {
		return lastErr
	}
	return fmt.Errorf("所有黄豆节点均不可用：请检查网络或切换代理")
}

// huangdouPoolLimitError 表示整个镜像池都被站点限流。
// Unwrap 返回带最短等待时间的退避对象，站源任务据此设置整体重试时间。
type huangdouPoolLimitError struct {
	hosts   int
	retryAt time.Time
}

func (failure *huangdouPoolLimitError) Error() string {
	if failure.retryAt.IsZero() {
		return fmt.Sprintf("黄豆 %d 个镜像节点都被限流，请稍后重试或切换网络 / 代理", failure.hosts)
	}
	seconds := max(1, int(time.Until(failure.retryAt).Seconds()+0.999))
	return fmt.Sprintf("黄豆 %d 个镜像节点都被限流，约 %d 秒后可重试；已保留已加载内容，也可切换网络 / 代理", failure.hosts, seconds)
}

func (failure *huangdouPoolLimitError) Unwrap() error {
	if failure.retryAt.IsZero() {
		return nil
	}
	return &requestBackoff{host: "黄豆镜像池", until: failure.retryAt, status: http.StatusForbidden}
}

// huangdouRateLimitedUntil 判断一次节点失败是否属于站点限流，并返回该节点的退避到期时间。
func huangdouRateLimitedUntil(err error) (time.Time, bool) {
	var backoff *requestBackoff
	if errors.As(err, &backoff) {
		return backoff.until, true
	}
	var httpErr *huangdouHTTPError
	if errors.As(err, &httpErr) && (httpErr.status == http.StatusForbidden || httpErr.status == http.StatusTooManyRequests) {
		return time.Time{}, true
	}
	return time.Time{}, false
}

// callOnceAllKeys 在当前 host 上尝试所有 platform key。
// 只有 huangdouKeyMismatchError（AES/gzip/JSON 解码失败）才继续换下一个 key；
// HTTP 层/网络层/业务层错误直接返回（换 key 没用，call 会换下一个 mirror host）。
func (c *huangdouAPIClient) callOnceAllKeys(ctx context.Context, path string, data map[string]any, out *any) error {
	var lastErr error
	for i, pk := range huangdouPlatformKeys {
		err := c.callOnceWithKey(ctx, path, data, pk, out)
		if err == nil {
			return nil
		}
		lastErr = err
		if _, ok := err.(*huangdouKeyMismatchError); !ok {
			// 非密钥不匹配错误：直接返回给 call 换 host
			return err
		}
		// 密钥不匹配：继续试下一个 key
		if i == len(huangdouPlatformKeys)-1 {
			return err
		}
	}
	return lastErr
}

type huangdouAPIError struct {
	code    string
	message string
}

// huangdouKeyMismatchError 表示 host 响应成功但密钥不匹配（AES 解码/gzip 解压/JSON 失败）。
// 这种错误需要换 platform key 重试，而不是换 mirror host。
type huangdouKeyMismatchError struct{ msg string }

func (e *huangdouKeyMismatchError) Error() string { return e.msg }

// huangdouHTTPError 表示网络层/HTTP 层错误（403/404/连接失败/超时）。
// 换 key 没用，必须换 mirror host。
type huangdouHTTPError struct {
	status int
	msg    string
}

func (e *huangdouHTTPError) Error() string {
	if e.status > 0 {
		return fmt.Sprintf("huangdou HTTP %d: %s", e.status, truncate(e.msg, 200))
	}
	return e.msg
}

func (failure *huangdouAPIError) Error() string {
	if failure.code != "preview" && isHuangdouAccessError(failure) {
		return failure.message + "（站点权限限制，已停止自动重试；切换代理不会解锁）"
	}
	return failure.message
}

func isHuangdouAccessError(err error) bool {
	var failure *huangdouAPIError
	if !errors.As(err, &failure) {
		return false
	}
	switch failure.code {
	case "813004", "813005", "813006", "813103", "preview":
		return true
	default:
		return false
	}
}

func huangdouPreviewOnly(data map[string]any, media, host string) bool {
	switch strings.ToLower(mapString(data, "is_preview", "isPreview")) {
	case "true", "1", "y":
		return true
	}
	if preview := mapString(data, "preview_m3u8", "preview_url"); preview != "" &&
		(media == "" || resolveProviderURL(host+"/", media) == resolveProviderURL(host+"/", preview)) {
		return true
	}
	parsed, err := url.Parse(media)
	if err != nil {
		return false
	}
	path := strings.ToLower(parsed.Path)
	return path == "preview.mp4" || path == "preview.m3u8" || strings.HasSuffix(path, "/preview.mp4") || strings.HasSuffix(path, "/preview.m3u8")
}

// callOnceWithKey 用指定 platformKey 完成单次加密 API 调用。
func (c *huangdouAPIClient) callOnceWithKey(ctx context.Context, path string, data map[string]any, platformKey string, out *any) error {
	path = "/" + strings.TrimLeft(path, "/")
	rid := uuidLike()
	key, err := huangdouKeyWith(rid, platformKey)
	if err != nil {
		return err
	}
	iv := make([]byte, aes.BlockSize)
	if _, err := rand.Read(iv); err != nil {
		return err
	}
	ridNoDash := strings.ReplaceAll(rid, "-", "")
	plain, err := json.Marshal(map[string]any{"token": "", "deviceId": ridNoDash, "data": data})
	if err != nil {
		return err
	}
	var gz bytes.Buffer
	zw := gzip.NewWriter(&gz)
	if _, err := zw.Write(plain); err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	cipherText, err := aesCBCEncrypt(gz.Bytes(), key, iv)
	if err != nil {
		return err
	}
	body := append(append([]byte{}, iv...), cipherText...)
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(c.host, "/")+"/api"+path, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120 Safari/537.36")
	req.Header.Set("Accept", "*/*")
	req.Header.Set("Origin", c.host)
	req.Header.Set("Referer", c.host+"/home")
	req.Header.Set("Content-Type", "application/octet-stream")
	req.Header.Set("version", huangdouVersion)
	req.Header.Set("deviceType", huangdouDeviceType)
	req.Header.Set("requestId", rid)
	req.Header.Set("sessionId", c.sessionID)
	resp, err := c.d.doPreparedCatalogRequest(req, 10*time.Second, func(prepared *http.Request) {
		timestamp := strconv.FormatInt(time.Now().Unix(), 10)
		ridNoDash := strings.ReplaceAll(rid, "-", "")
		signRaw := "Dart|" + ridNoDash + "|" + rid + "|" + timestamp + "|" + path
		signSum := sha256.Sum256([]byte(signRaw))
		prepared.Header.Set("time", timestamp)
		prepared.Header.Set("sign", hex.EncodeToString(signSum[:])+"-"+timestamp)
	})
	if err != nil {
		// 退避与上下文错误必须保留类型：前者决定池级重试时间，后者决定站源任务的超时 / 取消处理。
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			return backoff
		}
		if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
			return err
		}
		return &huangdouHTTPError{msg: err.Error()}
	}
	defer resp.Body.Close()
	blob, err := io.ReadAll(io.LimitReader(resp.Body, providerMaxBodyBytes+1))
	if err != nil {
		return err
	}
	if len(blob) > providerMaxBodyBytes {
		return fmt.Errorf("huangdou response exceeds %d bytes", providerMaxBodyBytes)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return &huangdouHTTPError{status: resp.StatusCode, msg: string(blob)}
	}
	decoded, err := huangdouDecode(blob, key)
	if err != nil {
		return &huangdouKeyMismatchError{msg: err.Error()}
	}
	if envelope, ok := decoded.(map[string]any); ok {
		if status := mapString(envelope, "status"); status != "" && status != "y" {
			return &huangdouAPIError{code: mapString(envelope, "errorCode", "error_code", "code"), message: "黄豆接口拒绝请求: " + firstNonEmpty(mapString(envelope, "msg", "message", "error"), status)}
		}
	}
	if out != nil {
		*out = decoded
	}
	return nil
}

// huangdouKeyWith 用指定 platformKey 派生 AES key（HMAC-SHA256(requestId, platformKey)）。
func huangdouKeyWith(rid, platformKey string) ([]byte, error) {
	clean := strings.ReplaceAll(rid, "-", "")
	b, err := hex.DecodeString(clean)
	if err != nil {
		return nil, err
	}
	mac := hmac.New(sha256.New, []byte(platformKey))
	_, _ = mac.Write(b)
	return mac.Sum(nil), nil
}

func huangdouDecode(blob, key []byte) (any, error) {
	if len(blob) > providerMaxBodyBytes {
		return nil, errors.New("黄豆响应过大")
	}
	if json.Valid(blob) {
		var direct any
		decoder := json.NewDecoder(bytes.NewReader(blob))
		decoder.UseNumber()
		if err := decoder.Decode(&direct); err != nil {
			return nil, err
		}
		return direct, nil
	}
	if len(blob) < aes.BlockSize*2 {
		return nil, fmt.Errorf("huangdou response too short")
	}
	plain, err := aesCBCDecrypt(blob[aes.BlockSize:], key, blob[:aes.BlockSize])
	if err != nil {
		return nil, err
	}
	if len(plain) >= 2 && plain[0] == 0x1f && plain[1] == 0x8b {
		zr, err := gzip.NewReader(bytes.NewReader(plain))
		if err != nil {
			return nil, err
		}
		plain, err = io.ReadAll(io.LimitReader(zr, providerMaxBodyBytes+1))
		_ = zr.Close()
		if err != nil {
			return nil, err
		}
		if len(plain) > providerMaxBodyBytes {
			return nil, errors.New("黄豆解压后响应过大")
		}
	}
	var decoded any
	if !json.Valid(plain) {
		return nil, errors.New("黄豆响应格式异常")
	}
	decoder := json.NewDecoder(bytes.NewReader(plain))
	decoder.UseNumber()
	if err := decoder.Decode(&decoded); err != nil {
		return nil, err
	}
	return decoded, nil
}

func aesCBCEncrypt(plain, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	padded := pkcs7Pad(plain, block.BlockSize())
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return out, nil
}

func aesCBCDecrypt(cipherText, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(cipherText)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("huangdou ciphertext is not block aligned")
	}
	out := make([]byte, len(cipherText))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, cipherText)
	return pkcs7Unpad(out, block.BlockSize())
}

func huangdouDramaFromMap(item map[string]any) Drama {
	sourceID := strings.TrimPrefix(firstNonEmpty(mapString(item, "id"), mapString(item, "drama_id")), "rp_")
	if sourceID == "" {
		return Drama{}
	}
	title := firstNonEmpty(mapString(item, "name", "title", "t"), sourceID)
	cover := firstNonEmpty(mapString(item, "img_y", "img_x", "img", "cover", "pic"))
	remark := firstNonEmpty(mapString(item, "update_label"), mapString(item, "corner"))
	releaseStatus := releaseStatusFromRemark(remark)
	if remark == "" {
		if eps := mapString(item, "episode_count"); eps != "" {
			remark = "全" + eps + "集"
		}
	}
	category := firstNonEmpty(mapString(item, "category", "category_name", "categoryName"), "未分类")
	return Drama{VIP: huangdouVIPFlag(item), ID: providerDramaID(sourceHuangdou, sourceID), Source: sourceHuangdou, SourceID: sourceID, Title: title, Name: title, Desc: firstNonEmpty(mapString(item, "description"), mapString(item, "summary")), Intro: firstNonEmpty(mapString(item, "description"), mapString(item, "summary")), Cover: cover, CoverURL: cover, CategoryName: category, ChannelName: "tideember.cc", Remark: remark, TotalEpisode: mapString(item, "episode_count"), EpisodeCount: mapString(item, "episode_count"), Tags: mapStringSlice(item, "tags"), ReleaseStatus: releaseStatus, Heat: mapString(item, "hot_rate"), Views: normalizeViews(mapString(item, "click")), OnlineDate: providerReleaseDate(mapString(item, "issue_date"))}
}

func huangdouDataMap(v any) map[string]any {
	m, _ := v.(map[string]any)
	if data, ok := m["data"].(map[string]any); ok {
		return data
	}
	return m
}

func huangdouList(v any) []map[string]any {
	switch x := v.(type) {
	case []any:
		out := make([]map[string]any, 0, len(x))
		for _, item := range x {
			if m, ok := item.(map[string]any); ok {
				out = append(out, m)
			}
		}
		return out
	case []map[string]any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if list := huangdouList(x[key]); len(list) > 0 {
				return list
			}
		}
	}
	return nil
}

func atoiDefault(s string, fallback int) int {
	if n, err := strconv.Atoi(strings.TrimSpace(s)); err == nil {
		return n
	}
	return fallback
}

func randomHex(n int) string {
	b := make([]byte, n)
	if _, err := rand.Read(b); err != nil {
		return ""
	}
	return hex.EncodeToString(b)
}

func uuidLike() string {
	raw := randomHex(16)
	if len(raw) != 32 {
		return raw
	}
	return raw[:8] + "-" + raw[8:12] + "-" + raw[12:16] + "-" + raw[16:20] + "-" + raw[20:]
}
