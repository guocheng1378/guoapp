package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func limiterTestRequest(t *testing.T, url string, ctx context.Context) *http.Request {
	t.Helper()
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		t.Fatal(err)
	}
	return request
}

func limiterTestResponse(status int) *http.Response {
	return &http.Response{StatusCode: status, Header: http.Header{}}
}

// 详情后台预取吃到 429/403 时，冷却只记进自己的表，不污染前台冷却表——
// 否则用户点播同源剧会被自己的预取卡住。
func TestPrefetchBackoffStaysOutOfForegroundTable(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	ctx := context.WithValue(context.Background(), backgroundBackoffKey{}, true)
	request := limiterTestRequest(t, "https://prefetch.example.test/a", ctx)

	limiter.observe(request, limiterTestResponse(http.StatusTooManyRequests))

	limiter.mu.Lock()
	foreground := limiter.backoffs["prefetch.example.test"]
	background := limiter.backgroundBackoffs["prefetch.example.test"]
	limiter.mu.Unlock()
	if foreground != nil {
		t.Fatal("prefetch 429 polluted the foreground cooldown table")
	}
	if background == nil {
		t.Fatal("prefetch 429 was not recorded in its own cooldown table")
	}
}

// 纯后台车道（预载/补齐/弹幕）的 429 仍要冷却所有人：那是源站全局限流，
// 继续加压只会更糟。这条语义不能被本次改动带偏。
func TestBackgroundCatalogStillSharesRateLimitCooldown(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	ctx := context.WithValue(context.Background(), backgroundCatalogKey{}, true)
	request := limiterTestRequest(t, "https://bgcat.example.test/a", ctx)

	limiter.observe(request, limiterTestResponse(http.StatusTooManyRequests))

	limiter.mu.Lock()
	foreground := limiter.backoffs["bgcat.example.test"]
	background := limiter.backgroundBackoffs["bgcat.example.test"]
	limiter.mu.Unlock()
	if foreground == nil {
		t.Fatal("background 429 must still cool the foreground down")
	}
	if background != nil {
		t.Fatal("background 429 must not be recorded twice")
	}
}

// 前台请求的 429 照旧记进前台冷却表（回归护栏）。
func TestForegroundBackoffUnchanged(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	request := limiterTestRequest(t, "https://foreground.example.test/a", context.Background())

	limiter.observe(request, limiterTestResponse(http.StatusTooManyRequests))

	limiter.mu.Lock()
	foreground := limiter.backoffs["foreground.example.test"]
	limiter.mu.Unlock()
	if foreground == nil {
		t.Fatal("foreground 429 lost its cooldown")
	}
}

// 冷却隔离：后台冷却表挡得住预取自己，挡不住前台。
func TestPrefetchCooldownBlocksOnlyItsOwnLane(t *testing.T) {
	limiter := newRequestLimiter(3, 0)
	const host = "lane.example.test"
	limiter.mu.Lock()
	limiter.backgroundBackoffs[host] = &requestBackoff{
		host: host, until: time.Now().Add(time.Minute), status: http.StatusTooManyRequests,
	}
	limiter.mu.Unlock()

	foreground := limiterTestRequest(t, "https://"+host+"/a", context.Background())
	release, err := limiter.acquire(foreground.Context(), foreground)
	if err != nil {
		t.Fatalf("foreground request blocked by a background cooldown: %v", err)
	}
	release()

	prefetchCtx := context.WithValue(context.Background(), backgroundBackoffKey{}, true)
	prefetch := limiterTestRequest(t, "https://"+host+"/b", prefetchCtx)
	if _, err := limiter.acquire(prefetch.Context(), prefetch); err == nil {
		t.Fatal("prefetch lane ignored its own cooldown")
	}
}

// 预取车道不让位给前台：标成 backgroundCatalogKey 会等「前台全空闲」，
// 滚屏时封面请求不断，预取会被彻底饿死——那预取就没意义了。
func TestPrefetchLaneDoesNotYieldToForeground(t *testing.T) {
	limiter := newRequestLimiter(2, 0)
	limiter.mu.Lock()
	limiter.foregroundWaiting = 1
	limiter.mu.Unlock()

	prefetchCtx := context.WithValue(context.Background(), backgroundBackoffKey{}, true)
	prefetch := limiterTestRequest(t, "https://yield.example.test/a", prefetchCtx)
	release, err := limiter.acquire(prefetch.Context(), prefetch)
	if err != nil {
		t.Fatalf("prefetch lane must not yield to a waiting foreground request: %v", err)
	}
	release()

	backgroundCtx, cancel := context.WithTimeout(
		context.WithValue(context.Background(), backgroundCatalogKey{}, true), 200*time.Millisecond)
	defer cancel()
	background := limiterTestRequest(t, "https://yield.example.test/b", backgroundCtx)
	if _, err := limiter.acquire(background.Context(), background); err == nil {
		t.Fatal("background lane must yield to a waiting foreground request")
	}
}

// 端到端：detail 动作带 background 标记时，429 只进后台冷却表；
// 不带标记（用户点播）时照旧进前台冷却表。
func TestDetailActionHonoursBackgroundCooldownIsolation(t *testing.T) {
	// 影视工厂是 all-sources 专属源，默认单源构建下 detail 会被站源门禁
	// 直接拦掉（根本走不到 HTTP），所以这里临时切到全源变体。
	previousVariant := buildAllSources
	buildAllSources = "true"
	t.Cleanup(func() {
		buildAllSources = previousVariant
		syncBuildVariant()
	})

	host := ""
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		if host == "" {
			host = request.URL.Hostname()
		}
		return sourceFixtureResponse(request, http.StatusTooManyRequests, "slow down"), nil
	})
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
	})

	drama := nativeDrama{ID: "yingshigongchang:1", Source: "yingshigongchang", SourceID: "1"}
	_, detailErr := nativeDispatch(nativeInput{Action: "detail", Drama: drama, Background: true})
	if host == "" {
		t.Fatalf("the detail request never reached the transport (err=%v)", detailErr)
	}
	limiter := engine.downloader.limiter
	limiter.mu.Lock()
	foreground := limiter.backoffs[host]
	background := limiter.backgroundBackoffs[host]
	limiter.mu.Unlock()
	if foreground != nil {
		t.Fatalf("detail prefetch polluted the foreground cooldown table (%s)", host)
	}
	if background == nil {
		t.Fatal("detail prefetch cooldown was not recorded in its own table")
	}

	// 用户点播（无 background 标记）：同样的 429 走前台冷却表。
	limiter.mu.Lock()
	limiter.backoffs = map[string]*requestBackoff{}
	limiter.backgroundBackoffs = map[string]*requestBackoff{}
	limiter.mu.Unlock()
	if _, err := nativeDispatch(nativeInput{Action: "detail", Drama: drama}); err == nil {
		t.Fatal("detail request was expected to fail")
	}
	limiter.mu.Lock()
	foreground = limiter.backoffs[host]
	limiter.mu.Unlock()
	if foreground == nil {
		t.Fatal("a foreground detail 429 must still cool the foreground down")
	}
}
