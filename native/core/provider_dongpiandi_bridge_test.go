package core

// 跨源借真果·鉴跳过预设（bridge 层）回归测试。
// 站点经 httptest stub（setDongpiandiBaseURL 热更）+ 请求计数取证。

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func setupDongpiandiBridgeTest(t *testing.T) {
	t.Helper()
	dongpiandiBridgeMu.Lock()
	dongpiandiBridgeCache = map[string]dongpiandiBridgeEntry{}
	dongpiandiBridgeCool = map[string]time.Time{}
	dongpiandiBridgeMu.Unlock()
	dongpiandiBridgeFlight = sync.Map{}
	dongpiandiSkipMu.Lock()
	dongpiandiSkipCache = map[string]dongpiandiSkipPreset{}
	dongpiandiSkipMu.Unlock()
	t.Cleanup(func() {
		setDongpiandiBaseURL(dongpiandiBaseURLDefault)
	})
}

func TestDongpiandiBridgeNormalizeTitle(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"嫁金枝", "嫁金枝"},
		{"《嫁金枝 》", "嫁金枝"},
		{"  嫁 金 枝  ", "嫁金枝"},
		{"嫁金枝!", "嫁金枝"},
		{"嫁金枝：完整版", "嫁金枝完整版"},
		{"AB Cd", "abcd"},
		{"", ""},
		{"　", ""}, // 全角空格
	}
	for _, c := range cases {
		if got := normalizeDongpiandiLookupTitle(c.in); got != c.want {
			t.Errorf("normalize(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

// goSeedBridge 写一条测试映射与预设（同步零网络路径用）。
func goSeedBridge(t *testing.T, norm, variantID string, preset dongpiandiSkipPreset) {
	t.Helper()
	dongpiandiBridgeMu.Lock()
	dongpiandiBridgeCache[norm] = dongpiandiBridgeEntry{VariantID: variantID, HasPreset: true}
	dongpiandiBridgeMu.Unlock()
	dongpiandiCacheSkipPreset(variantID, preset)
}

// waitForBridgeFlightIdle 等待所有后台补映射 goroutine 收尾（flight 清空）。
// PrimeAsync 的 flight 占位在调用方同步完成，ApplySkip 返回后 flight 必然
// 已有占位——清空即代表 goroutine 已执行完 defer Delete，之后不再触碰
// bridge 全局状态。必须在测试 return 前调用，否则下一个用例 setup 整表
// 替换 dongpiandiBridgeFlight 会与残存 goroutine 的 Delete 数据竞争。
func waitForBridgeFlightIdle(t *testing.T) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		busy := false
		dongpiandiBridgeFlight.Range(func(any, any) bool { busy = true; return false })
		if !busy {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("后台补映射 goroutine 未在 3s 内收尾")
}

func TestDongpiandiBridgeApplySkipOfflineZeroNetwork(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		t.Errorf("同步 ApplySkip 路径不应发起任何网络请求: %s", r.URL.Path)
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	goSeedBridge(t, "嫁金枝", "v-100", dongpiandiSkipPreset{
		Source: "community_median", IntroEndSeconds: 12.4, OutroFromEndSeconds: 8.6, SampleCount: 5,
	})

	var choice nativePlaybackChoice
	(&Downloader{}).dongpiandiBridgeApplySkip("《嫁金枝 》", &choice)
	if choice.skipIntro != 12 || choice.skipOutroFromEnd != 9 {
		t.Fatalf("choice = (%d,%d), want (12,9)", choice.skipIntro, choice.skipOutroFromEnd)
	}
}

func TestDongpiandiBridgeApplySkipMissDoesNotBlock(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	// stub 卡住所有响应：若实现改为同步补映射，ApplySkip 必然超过时限。
	release := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		<-release
		_, _ = w.Write([]byte(`{"suggestions":[]}`))
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	var choice nativePlaybackChoice
	start := time.Now()
	(&Downloader{}).dongpiandiBridgeApplySkip("无此剧", &choice)
	if elapsed := time.Since(start); elapsed > 200*time.Millisecond {
		t.Fatalf("未命中时 ApplySkip 阻塞了 %v（应立即返回，补映射在后台）", elapsed)
	}
	if choice.skipIntro != 0 || choice.skipOutroFromEnd != 0 {
		t.Fatalf("未命中不应填充 choice: %+v", choice)
	}
	// 放行卡住的请求，再等后台补映射 goroutine 收尾，避免它拖着旧
	// 标题在下一个用例的 stub 上发请求（全局 baseURL 时序竞态）。
	close(release)
	waitForBridgeFlightIdle(t)
}

func TestDongpiandiBridgePrimeHitChain(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	var suggestCalls, catalogCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/suggest"):
			suggestCalls.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"object":"list","query":"嫁金枝","suggestions":[
				{"label":"嫁金枝第二季","target":{"variant_id":"v-other"}},
				{"label":"《嫁金枝》","target":{"variant_id":"v-100"}}
			]}`))
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			catalogCalls.Add(1)
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"id":"v-100","title":"嫁金枝","episodes":[],
				"playback_skip_settings_preset":{"source":"community_median","intro_end_seconds":12.4,"outro_from_end_seconds":8.6,"sample_count":5}}`))
		default:
			w.WriteHeader(http.StatusOK)
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	d := &Downloader{}
	d.dongpiandiBridgePrime(normalizeDongpiandiLookupTitle("嫁金枝"), "嫁金枝")
	if suggestCalls.Load() != 1 || catalogCalls.Load() != 1 {
		t.Fatalf("calls suggest=%d catalog=%d, want 1/1", suggestCalls.Load(), catalogCalls.Load())
	}

	entry, ok := dongpiandiBridgeLookup("嫁金枝")
	if !ok || entry.VariantID != "v-100" || !entry.HasPreset {
		t.Fatalf("bridge entry = %+v ok=%v", entry, ok)
	}
	if preset, ok := dongpiandiCachedSkipPreset("v-100"); !ok || !preset.valid() {
		t.Fatalf("skip cache miss after prime: %+v ok=%v", preset, ok)
	}

	// 二次 ApplySkip：走同步缓存，零网络，choice 正确。
	before := catalogCalls.Load()
	var choice nativePlaybackChoice
	d.dongpiandiBridgeApplySkip("嫁 金 枝!", &choice)
	if choice.skipIntro != 12 || choice.skipOutroFromEnd != 9 {
		t.Fatalf("choice = (%d,%d), want (12,9)", choice.skipIntro, choice.skipOutroFromEnd)
	}
	if catalogCalls.Load() != before {
		t.Fatalf("二次应用不应回源: %d -> %d", before, catalogCalls.Load())
	}
}

func TestDongpiandiBridgePrimeExactMatchOnly(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"suggestions":[
			{"label":"嫁金枝2","target":{"variant_id":"v-2"}},
			{"label":"嫁金枝（卫视版）","target":{"variant_id":"v-tv"}},
			{"label":"嫁金枝之凤鸣朝阳","target":{"variant_id":"v-spin"}}
		]}`))
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	d := &Downloader{}
	d.dongpiandiBridgePrime("嫁金枝", "嫁金枝")
	if _, ok := dongpiandiBridgeLookup("嫁金枝"); ok {
		t.Fatal("近似标题不应建立映射")
	}
	if until, ok := dongpiandiBridgeCooldownUntil("嫁金枝"); !ok || until.Before(time.Now().Add(time.Hour)) {
		t.Fatalf("未收录应有长冷却: until=%v ok=%v", until, ok)
	}
}

func TestDongpiandiBridgeNegativeCacheSuppressesRetry(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	var suggestCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/suggest") {
			suggestCalls.Add(1)
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"suggestions":[]}`))
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	norm := normalizeDongpiandiLookupTitle("无名之辈")
	d := &Downloader{}
	d.dongpiandiBridgePrime(norm, "无名之辈")
	d.dongpiandiBridgePrime(norm, "无名之辈")
	if got := suggestCalls.Load(); got != 1 {
		t.Fatalf("负缓存未抑制重试: suggest 调用 %d 次, want 1", got)
	}
}

func TestDongpiandiBridgeNetworkErrorShortCooldown(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	d := &Downloader{}
	d.dongpiandiBridgePrime("嫁金枝", "嫁金枝")
	if _, ok := dongpiandiBridgeLookup("嫁金枝"); ok {
		t.Fatal("失败不应写映射")
	}
	until, ok := dongpiandiBridgeCooldownUntil("嫁金枝")
	if !ok || until.Before(time.Now().Add(dongpiandiBridgeCooldownError-time.Minute)) || until.After(time.Now().Add(dongpiandiBridgeCooldownError+time.Minute)) {
		t.Fatalf("网络失败应给 ~10min 冷却: until=%v", until)
	}
}

func TestDongpiandiBridgeNoPresetEntry(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/suggest"):
			_, _ = w.Write([]byte(`{"suggestions":[{"label":"嫁金枝","target":{"variant_id":"v-np"}}]}`))
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			_, _ = w.Write([]byte(`{"id":"v-np","title":"嫁金枝","episodes":[]}`))
		default:
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	d := &Downloader{}
	d.dongpiandiBridgePrime("嫁金枝", "嫁金枝")
	entry, ok := dongpiandiBridgeLookup("嫁金枝")
	if !ok || entry.HasPreset {
		t.Fatalf("映射应定格 HasPreset=false: %+v ok=%v", entry, ok)
	}

	var choice nativePlaybackChoice
	d.dongpiandiBridgeApplySkip("嫁金枝", &choice)
	if choice.skipIntro != 0 || choice.skipOutroFromEnd != 0 {
		t.Fatalf("无预设不应填充 choice: %+v", choice)
	}
}

func TestDongpiandiBridgeFlightDedup(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	var suggestCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasPrefix(r.URL.Path, "/v1/suggest") {
			suggestCalls.Add(1)
		}
		_, _ = w.Write([]byte(`{"suggestions":[]}`))
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	norm := normalizeDongpiandiLookupTitle("在途之剧")
	dongpiandiBridgeFlight.Store(norm, struct{}{})
	defer dongpiandiBridgeFlight.Delete(norm)

	d := &Downloader{}
	d.dongpiandiBridgePrimeAsync(norm, "在途之剧")
	time.Sleep(150 * time.Millisecond)
	if got := suggestCalls.Load(); got != 0 {
		t.Fatalf("在途去重未生效: suggest 调用 %d 次", got)
	}
}

func TestDongpiandiBridgeSkipCacheEvictedBackfills(t *testing.T) {
	setupDongpiandiBridgeTest(t)
	var catalogCalls atomic.Int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			catalogCalls.Add(1)
			_, _ = w.Write([]byte(`{"id":"v-ev","title":"逐出之剧","episodes":[],
				"playback_skip_settings_preset":{"source":"community_median","intro_end_seconds":30}}`))
		default:
			_, _ = w.Write([]byte(`{}`))
		}
	}))
	defer srv.Close()
	setDongpiandiBaseURL(srv.URL)

	goSeedBridge(t, "逐出之剧", "v-ev", dongpiandiSkipPreset{Source: "community_median", IntroEndSeconds: 30})
	dongpiandiSkipMu.Lock()
	delete(dongpiandiSkipCache, "v-ev") // 模拟容量护栏逐出
	dongpiandiSkipMu.Unlock()

	d := &Downloader{}
	var choice nativePlaybackChoice
	d.dongpiandiBridgeApplySkip("逐出之剧", &choice)
	if choice.skipIntro != 0 {
		t.Fatal("缓存已逐出，同步路径不应填值")
	}
	// 后台回填完成后再应用即恢复。
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := dongpiandiCachedSkipPreset("v-ev"); ok {
			break
		}
		time.Sleep(20 * time.Millisecond)
	}
	if _, ok := dongpiandiCachedSkipPreset("v-ev"); !ok {
		t.Fatal("逐出后后台回填失败")
	}
	choice = nativePlaybackChoice{}
	d.dongpiandiBridgeApplySkip("逐出之剧", &choice)
	if choice.skipIntro != 30 {
		t.Fatalf("回填后 choice.skipIntro = %d, want 30", choice.skipIntro)
	}
	// G2 写回 skipCache 后还要 defer flight.Delete；不等收尾就会与
	// 下一用例 setup 的 flight 变量替换数据竞争（race 实锤过）。
	waitForBridgeFlightIdle(t)
}
