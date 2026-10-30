package core

// 真果·鉴线路切换测试：resolve 全线路过滤/排序、Label 归一、预拉合并、
// 详情分集去重、nativeSelectPlayback 按索引选线、封面集数来源回归。

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// dongpiandiRouteServer 假扮真果·鉴 API + 资源站媒体。
type dongpiandiRouteServer struct {
	server   *httptest.Server
	catalog  string // /v1/catalog/{id} 响应体
	resolve  string // /v1/playback/resolve/{token} 响应体
	apiCalls atomic.Int32
}

func newDongpiandiRouteServer(catalog, resolve string) *dongpiandiRouteServer {
	s := &dongpiandiRouteServer{catalog: catalog, resolve: resolve}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/catalog/", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, s.catalog)
	})
	mux.HandleFunc("/v1/playback/resolve/", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, s.resolve)
	})
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// 媒体地址：存活探测与 playlist 拉取。/v 前缀的存活，其它（如
		// /dead.mp4）404 模拟失效线路。
		if !strings.HasPrefix(r.URL.Path, "/v") {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("0123456789abcdef"))
	})
	s.server = httptest.NewServer(mux)
	return s
}

func (s *dongpiandiRouteServer) close() { s.server.Close() }

// withDongpiandiBaseURL 临时热更站点根地址（测试后恢复）。
func withDongpiandiBaseURL(t *testing.T, base string) {
	t.Helper()
	prev := dongpiandiBaseURL()
	setDongpiandiBaseURL(base)
	t.Cleanup(func() { setDongpiandiBaseURL(prev) })
}

func dongpiandiLineOptionsJSON(lines []map[string]any) string {
	raw, _ := json.Marshal(map[string]any{"object": "playback.resolve", "line_options": lines})
	return string(raw)
}

func TestDongpiandiResolveLinesFilterAndOrder(t *testing.T) {
	client := dongpiandiStubClient(dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": "https://a.test/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 790, "selected": true},
		{"id": "l2", "label": "索尼资源", "url": "https://b.test/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 845},
		{"id": "l3", "label": "票据线", "url": "resolve://ticket", "url_kind": "resolve_ticket", "resolved": false},
		{"id": "l4", "label": "空地址", "url": "", "url_kind": "m3u8", "resolved": true},
		{"id": "l5", "label": "网页线", "url": "https://c.test/player/1", "url_kind": "page", "resolved": true},
	}))
	lines, err := dongpiandiResolveLines(context.Background(), client, "token1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 {
		t.Fatalf("want 2 resolved m3u8 lines, got %d: %+v", len(lines), lines)
	}
	// 权重+selected 计分：l1=790+10000+5000=15790 > l2=845+10000=10845
	if lines[0].Label != "无水印资源" || lines[1].Label != "索尼资源" {
		t.Fatalf("order wrong: %+v", lines)
	}
}

func TestDongpiandiResolveLinesProbeFallbackKeepsOrder(t *testing.T) {
	// 线路 URL 均不可达（保留 IP 拒绝连接），probe 全挂 → 保持权重序
	client := dongpiandiStubClient(dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "慢线", "url": "http://127.0.0.1:1/slow/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900},
		{"id": "l2", "label": "快线", "url": "http://127.0.0.1:2/fast/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 800},
	}))
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	lines, err := dongpiandiResolveLines(ctx, client, "token1", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 || lines[0].Label != "慢线" {
		t.Fatalf("probe fallback should keep weight order: %+v", lines)
	}
}

func TestDongpiandiLineMediaLabel(t *testing.T) {
	cases := []struct {
		line dongpiandiLine
		want string
	}{
		{dongpiandiLine{Label: "无水印资源", ProviderName: "无水印", PlayFrom: "wsym3u8"}, "无水印资源"},
		{dongpiandiLine{Label: "  ", ProviderName: "索尼资源", PlayFrom: "snm3u8"}, "索尼资源"},
		{dongpiandiLine{ProviderName: "", PlayFrom: "ffm3u8"}, "ffm3u8"},
		{dongpiandiLine{}, ""},
	}
	for _, c := range cases {
		if got := dongpiandiLineMedia(c.line).Label; got != c.want {
			t.Fatalf("label want %q got %q", c.want, got)
		}
	}
}

func TestMergeDongpiandiRoutes(t *testing.T) {
	d := &Downloader{}
	media := &providerMedia{URL: "https://a.test/index.m3u8"}
	lines := []dongpiandiLine{
		{Label: "主线", URL: "https://a.test/index.m3u8"},
		{Label: "备线", URL: "https://b.test/index.m3u8"},
		{Label: "三线", URL: "https://c.test/index.m3u8"},
		{Label: "重复", URL: "https://b.test/index.m3u8"},
	}
	d.mergeDongpiandiRoutes(media, lines)
	if media.URL != "https://a.test/index.m3u8" {
		t.Fatal("primary URL moved")
	}
	if media.Label != "主线" {
		t.Fatalf("primary label not filled: %q", media.Label)
	}
	if len(media.Variants) != 2 || media.Variants[0].Label != "备线" || media.Variants[1].Label != "三线" {
		t.Fatalf("variants wrong: %+v", media.Variants)
	}
	// 空线路不合并
	d.mergeDongpiandiRoutes(media, nil)
	if len(media.Variants) != 2 {
		t.Fatal("nil lines changed variants")
	}
}

func TestResolveDongpiandiMediaAliveAttachesRoutes(t *testing.T) {
	srv := newDongpiandiRouteServer(
		`{"id":"d1","title":"测试剧","episodes":[{"id":"e1","key":"e-0001","token":"t1"}]}`,
		dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "主线", "url": "PLACEHOLDER/v1.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900, "selected": true},
			{"id": "l2", "label": "备线", "url": "PLACEHOLDER/v2.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 800},
		}),
	)
	defer srv.close()
	srv.resolve = strings.ReplaceAll(srv.resolve, "PLACEHOLDER", srv.server.URL)
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	task := Task{
		DramaID: providerDramaID(sourceDongpiandi, "d1"),
		Chapter: Chapter{
			ID:       providerDramaID(sourceDongpiandi, "e1"),
			Source:   sourceDongpiandi,
			VideoURL: srv.server.URL + "/v1.mp4",
			PageURL:  srv.server.URL + "/player/d1",
		},
	}
	media, err := d.resolveDongpiandiMedia(context.Background(), task)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != srv.server.URL+"/v1.mp4" {
		t.Fatalf("primary URL changed: %q", media.URL)
	}
	if media.Label != "主线" {
		t.Fatalf("label not attached: %q", media.Label)
	}
	if len(media.Variants) != 1 || media.Variants[0].URL != srv.server.URL+"/v2.mp4" || media.Variants[0].Label != "备线" {
		t.Fatalf("routes not attached: %+v", media.Variants)
	}
	// Variants 经 nativePlaybackChoices 展开成多线路
	choices := nativePlaybackChoices(media, 0)
	if len(choices.media) != 2 {
		t.Fatalf("choices lost routes: %+v", choices.media)
	}
}

func TestResolveDongpiandiMediaDeadRefreshesAllRoutes(t *testing.T) {
	srv := newDongpiandiRouteServer(
		`{"id":"d1","title":"测试剧","episodes":[{"id":"e1","key":"e-0001","token":"t1"}]}`,
		dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "主线", "url": "PLACEHOLDER/v1.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900, "selected": true},
			{"id": "l2", "label": "备线", "url": "PLACEHOLDER/v2.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 800},
		}),
	)
	defer srv.close()
	srv.resolve = strings.ReplaceAll(srv.resolve, "PLACEHOLDER", srv.server.URL)
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	task := Task{
		DramaID: providerDramaID(sourceDongpiandi, "d1"),
		Chapter: Chapter{
			ID:       providerDramaID(sourceDongpiandi, "e1"),
			Source:   sourceDongpiandi,
			VideoURL: srv.server.URL + "/dead.mp4", // 404 → 走失效路径
			PageURL:  srv.server.URL + "/player/d1",
		},
	}
	media, err := d.resolveDongpiandiMedia(context.Background(), task)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != srv.server.URL+"/v1.mp4" || media.Label != "主线" {
		t.Fatalf("refresh primary wrong: %+v", media)
	}
	if len(media.Variants) != 1 || media.Variants[0].Label != "备线" {
		t.Fatalf("refresh variants wrong: %+v", media.Variants)
	}
}

func TestResolveDongpiandiMediaColdStartUsesCache(t *testing.T) {
	// 缓存优先起播回归：同一集第二次冷起播（无地址）直接吃线路缓存，
	// 零 API 往返；地址非空（失效重解析）时仍强制全链刷新。
	srv := newDongpiandiRouteServer(
		`{"id":"d1","title":"测试剧","episodes":[{"id":"e-cache-1","key":"e-0001","token":"t1"}]}`,
		dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "主线", "url": "PLACEHOLDER/v1.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900, "selected": true},
		}),
	)
	defer srv.close()
	srv.resolve = strings.ReplaceAll(srv.resolve, "PLACEHOLDER", srv.server.URL)
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	task := Task{
		DramaID: providerDramaID(sourceDongpiandi, "d1"),
		Chapter: Chapter{
			ID:      providerDramaID(sourceDongpiandi, "e-cache-1"),
			Source:  sourceDongpiandi,
			PageURL: srv.server.URL + "/player/d1",
		},
	}
	// 第一次冷起播：全链解析并把线路写进缓存。
	media, err := d.resolveDongpiandiMedia(context.Background(), task)
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != srv.server.URL+"/v1.mp4" {
		t.Fatalf("first cold start wrong: %+v", media)
	}
	if len(dongpiandiCachedLines("e-cache-1")) == 0 {
		t.Fatal("expected lines cached after first resolve")
	}
	srv.apiCalls.Store(0)

	// 第二次冷起播：缓存命中，不打 /v1/ 接口。
	media, err = d.resolveDongpiandiMedia(context.Background(), task)
	if err != nil {
		t.Fatal(err)
	}
	if got := srv.apiCalls.Load(); got != 0 {
		t.Fatalf("cache hit should skip API calls, got %d", got)
	}
	if media.URL != srv.server.URL+"/v1.mp4" || media.Label != "主线" {
		t.Fatalf("cache-first media wrong: %+v", media)
	}

	// 地址存在但已死：必须走全链刷新（会打 API）。
	srv.apiCalls.Store(0)
	deadTask := task
	deadTask.Chapter.VideoURL = srv.server.URL + "/dead.mp4"
	if _, err := d.resolveDongpiandiMedia(context.Background(), deadTask); err != nil {
		t.Fatal(err)
	}
	if got := srv.apiCalls.Load(); got == 0 {
		t.Fatal("dead address must refresh via API, cache bypassed")
	}
}

func TestFetchDongpiandiDetailDedup(t *testing.T) {
	srv := newDongpiandiRouteServer(
		`{"id":"d1","title":"测试剧","episodes":[
			{"id":"e1","key":"e-0001","number":1,"token":"t1"},
			{"id":"e1","key":"e-0001","number":1,"token":"t1"},
			{"id":"","key":"e-0002","number":2,"token":"t2"},
			{"id":"e3","key":"e-0003","number":3,"token":""},
			{"id":"e4","key":"e-0004","number":4,"token":"t4"}
		]}`,
		dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "主线", "url": "https://a.test/v.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900},
		}),
	)
	defer srv.close()
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	drama, chapters, err := d.fetchDongpiandiDetail(context.Background(), "d1")
	if err != nil {
		t.Fatal(err)
	}
	if drama.ID != providerDramaID(sourceDongpiandi, "d1") {
		t.Fatalf("drama id wrong: %q", drama.ID)
	}
	// e1 去重后 1 条 + e4 一条；空 ID/空 token 剔除
	if len(chapters) != 2 {
		t.Fatalf("dedup want 2 chapters got %d: %+v", len(chapters), chapters)
	}
	if chapters[0].ID != providerDramaID(sourceDongpiandi, "e1") || chapters[1].ID != providerDramaID(sourceDongpiandi, "e4") {
		t.Fatalf("chapters order/identity wrong: %+v", chapters)
	}
}

func TestNativeSelectPlaybackByIndex(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	media := providerMedia{URL: "https://first.test/v.mp4", Label: "无水印资源"}
	media.Variants = []providerMedia{{URL: "https://second.test/v.mp4", Label: "索尼资源"}}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	defer engine.stream.server.Close()
	if plan.RouteCount != 2 || len(plan.RouteLabels) != 2 {
		t.Fatalf("plan route info wrong: %+v", plan)
	}
	if plan.RouteLabels[0] != "无水印资源" || plan.RouteLabels[1] != "索尼资源" {
		t.Fatalf("route labels wrong: %+v", plan.RouteLabels)
	}
	if plan.RouteIndex != 0 || plan.URL == "" {
		t.Fatalf("initial route wrong: %+v", plan)
	}
	// 选第二条（plan.URL 是流代理地址，按线路区分）
	second, err := engine.nativeSelectPlayback(context.Background(), plan.Session, 1)
	if err != nil {
		t.Fatal(err)
	}
	if second.RouteIndex != 1 || second.URL == "" || second.URL == plan.URL {
		t.Fatalf("select 1 wrong: %+v", second)
	}
	if len(second.RouteLabels) != 2 || second.RouteLabels[1] != "索尼资源" {
		t.Fatalf("select lost labels: %+v", second)
	}
	// 回选第一条（每次选线都新建流会话，代理地址随之变化，只断言索引与可用性）
	back, err := engine.nativeSelectPlayback(context.Background(), plan.Session, 0)
	if err != nil {
		t.Fatal(err)
	}
	if back.RouteIndex != 0 || back.URL == "" {
		t.Fatalf("select 0 wrong: %+v", back)
	}
	// 越界与未知会话
	if _, err := engine.nativeSelectPlayback(context.Background(), plan.Session, 5); err == nil {
		t.Fatal("out of range accepted")
	}
	if _, err := engine.nativeSelectPlayback(context.Background(), plan.Session, -1); err == nil {
		t.Fatal("negative index accepted")
	}
	if _, err := engine.nativeSelectPlayback(context.Background(), "no-such-session", 0); err == nil {
		t.Fatal("unknown session accepted")
	}
	engine.nativeReleasePlayback(plan.Session)
	engine.nativeReleasePlayback(second.Session)
}

// 封面集数回归：卡片集数取 playback_groups[].episode_count（探针实测与
// remarks「全N集」吻合的权威字段）；playback_count 是总播放量，绝不能
// 当集数（早期 bug：封面「共 N 集」实为播放量，进详情才自愈）。
func TestDongpiandiCardEpisodeCountFromPlaybackGroups(t *testing.T) {
	card := dongpiandiCatalogCard{
		ID:    "av_x",
		Title: "御狐之绊",
		// 总播放量 216——若被当集数，封面会显示「共 216 集」。
		PlaybackCount: 216,
		PlaybackGroups: []dongpiandiPlaybackGroup{
			{ID: "yjplayer", Label: "网页播放器", Type: "player", EpisodeCount: 12},
			{ID: "yjm3u8", Label: "m3u8", Type: "m3u8", EpisodeCount: 12},
			{ID: "yjapi", Label: "YJ API", Type: "api", EpisodeCount: 12},
		},
	}
	drama := dongpiandiDramaFromCard(card)
	if drama.EpisodeCount != 12 || drama.TotalEpisode != 12 {
		t.Fatalf("封面集数应取 playback_groups.episode_count=12，得到 EpisodeCount=%d TotalEpisode=%d", drama.EpisodeCount, drama.TotalEpisode)
	}
	// 无播放组时回落 0（Dart 侧 episodes<=0 不渲染「共 N 集」）
	bare := dongpiandiDramaFromCard(dongpiandiCatalogCard{ID: "av_y", Title: "短剧甲", PlaybackCount: 9999})
	if bare.EpisodeCount != 0 || bare.TotalEpisode != 0 {
		t.Fatalf("无播放组时集数应为 0，得到 %d/%d", bare.EpisodeCount, bare.TotalEpisode)
	}
	// 多播放组取最大值兜底
	mixed := dongpiandiDramaFromCard(dongpiandiCatalogCard{
		ID: "av_z", Title: "混合剧",
		PlaybackGroups: []dongpiandiPlaybackGroup{
			{ID: "a", EpisodeCount: 5},
			{ID: "b", EpisodeCount: 43},
		},
	})
	if mixed.EpisodeCount != 43 {
		t.Fatalf("多播放组应取最大集数 43，得到 %d", mixed.EpisodeCount)
	}
}

// ---------- 官方线两步兑换（resolve:// 票据 → resolve-line 直链） ----------

// dongpiandiRedeemStub 按路径分发的确定性桩：resolve 前缀回预置响应，
// 匿名建号可模拟失败，票据兑换按请求体里的 ticket 返回预置直链（与
// 兑换 goroutine 的到达顺序无关）。
type dongpiandiRedeemStub struct {
	resolve     string
	tickets     map[string]dongpiandiLine
	anonStatus  int            // 非 0 且非 200 时模拟建号失败
	failFirst   map[string]int // 票据 → 前 N 次兑换返回空响应（模拟站点偶发限流）
	mu          sync.Mutex
	anonCalls   int
	redeemCalls int
	redeemBody  string
}

func (s *dongpiandiRedeemStub) reply(req *http.Request, code int, body string) *http.Response {
	return &http.Response{
		StatusCode: code,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    req,
	}
}

func (s *dongpiandiRedeemStub) RoundTrip(req *http.Request) (*http.Response, error) {
	switch {
	case strings.HasPrefix(req.URL.Path, "/v1/playback/resolve/"):
		return s.reply(req, http.StatusOK, s.resolve), nil
	case req.URL.Path == "/v1/users/anonymous":
		s.mu.Lock()
		s.anonCalls++
		s.mu.Unlock()
		if s.anonStatus != 0 && s.anonStatus != http.StatusOK {
			return s.reply(req, s.anonStatus, `{"error":"no session"}`), nil
		}
		return s.reply(req, http.StatusOK, "{}"), nil
	case req.URL.Path == "/v1/playback/resolve-line":
		raw, _ := io.ReadAll(req.Body)
		s.mu.Lock()
		s.redeemCalls++
		s.redeemBody = string(raw)
		s.mu.Unlock()
		var parsed struct {
			Ticket string `json:"ticket"`
		}
		_ = json.Unmarshal(raw, &parsed)
		s.mu.Lock()
		failures := s.failFirst[parsed.Ticket]
		if failures > 0 {
			s.failFirst[parsed.Ticket] = failures - 1
		}
		s.mu.Unlock()
		if failures > 0 {
			return s.reply(req, http.StatusOK, "{}"), nil
		}
		line, ok := s.tickets[parsed.Ticket]
		if !ok {
			return s.reply(req, http.StatusOK, "{}"), nil
		}
		ack, _ := json.Marshal(map[string]dongpiandiLine{"line": line})
		return s.reply(req, http.StatusOK, string(ack)), nil
	}
	return s.reply(req, http.StatusOK, "{}"), nil
}

func newDongpiandiRedeemClient(stub *dongpiandiRedeemStub) *dongpiandiClient {
	return &dongpiandiClient{http: &http.Client{Timeout: 5 * time.Second, Transport: stub}}
}

// 播放期 probe=true：全部票据并发兑换成直链，继承原线位 ID/Selected/权重。
func TestDongpiandiResolveLinesRedeemsTicketsOnProbe(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "无水印资源", "url": "http://127.0.0.1:1/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900},
			{"id": "l2", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "selected": true, "preference_weight": 950},
			{"id": "l3", "label": "官方线乙", "url": "resolve://tk-b", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 880},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/a/index.m3u8", URLKind: "m3u8"},
			"tk-b": {Label: "官方线乙", URL: "http://127.0.0.1:9/b/clip.mp4", URLKind: "mp4"},
		},
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 3 {
		t.Fatalf("want 3 lines after redemption, got %d: %+v", len(lines), lines)
	}
	var gotA, gotB *dongpiandiLine
	for i := range lines {
		switch lines[i].ID {
		case "l2":
			gotA = &lines[i]
		case "l3":
			gotB = &lines[i]
		}
	}
	if gotA == nil || gotB == nil {
		t.Fatalf("redeemed lines lost their source IDs: %+v", lines)
	}
	if gotA.URL != "http://127.0.0.1:9/a/index.m3u8" || !gotA.Resolved || !gotA.Selected {
		t.Fatalf("official line A wrong: %+v", *gotA)
	}
	if gotB.URL != "http://127.0.0.1:9/b/clip.mp4" || !gotB.Resolved {
		t.Fatalf("official line B wrong: %+v", *gotB)
	}
	if stub.anonCalls != 1 || stub.redeemCalls != 2 {
		t.Fatalf("calls wrong: anon=%d redeem=%d", stub.anonCalls, stub.redeemCalls)
	}
}

// 详情页快速路径 probe=false：已有直连线时完全跳过兑换（防请求放大）。
func TestDongpiandiResolveLinesSkipsRedeemWhenDirectLinesExist(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "无水印资源", "url": "http://127.0.0.1:1/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900},
			{"id": "l2", "label": "官方线", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 950},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "官方线", URL: "http://127.0.0.1:9/a/index.m3u8", URLKind: "m3u8"},
		},
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 1 || lines[0].ID != "l1" {
		t.Fatalf("only direct line expected: %+v", lines)
	}
	if stub.redeemCalls != 0 || stub.anonCalls != 0 {
		t.Fatalf("redemption must be skipped on fast path: anon=%d redeem=%d", stub.anonCalls, stub.redeemCalls)
	}
}

// probe=false 无直连线：仅兑换首张票据保底可播。
func TestDongpiandiResolveLinesRedeemsFirstTicketAsFallback(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "selected": true},
			{"id": "l2", "label": "官方线乙", "url": "resolve://tk-b", "url_kind": "resolve_ticket", "resolved": false},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/a/index.m3u8", URLKind: "m3u8"},
		},
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", false)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 1 || lines[0].ID != "l1" || !lines[0].Resolved {
		t.Fatalf("first-ticket fallback wrong: %+v", lines)
	}
	if stub.redeemCalls != 1 || !strings.Contains(stub.redeemBody, "tk-a") {
		t.Fatalf("fast path must redeem exactly the first ticket: calls=%d body=%s", stub.redeemCalls, stub.redeemBody)
	}
}

// 兑换失败（空响应 / 循环票据）→ 线路丢弃而非带病上屏。probe=true 全量
// 兑换，两张票据都尝试；probe=false 快路径只兑首张（见上一用例）。
func TestDongpiandiResolveLinesDropsFailedRedemptions(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "空响应票据", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false},
			{"id": "l2", "label": "循环票据", "url": "resolve://tk-b", "url_kind": "resolve_ticket", "resolved": false},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-b": {Label: "循环票据", URL: "resolve://tk-c"},
		},
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 0 {
		t.Fatalf("failed redemptions must be dropped: %+v", lines)
	}
	// 每张票据先试一次、失败后再退避重试两次（见 dongpiandiRedeemTickets：
	// 站点 429「请求太频繁」会让官方线整条消失，所以重试给到 3 次机会）。
	if stub.redeemCalls != 6 {
		t.Fatalf("both tickets must be attempted and retried twice on probe: %d", stub.redeemCalls)
	}
}

// 偶发失败（站点限流）重试一次后要把官方线补回来：真网探针实锤同一集 3 张
// 票据串行逐张全成功、并发批量偶尔只兑出 2 张，是「官方源显示不全」的来源。
func TestDongpiandiRedeemRetriesTransientFailure(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false},
			{"id": "l2", "label": "官方线乙", "url": "resolve://tk-b", "url_kind": "resolve_ticket", "resolved": false},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/a/clip.mp4", URLKind: "mp4"},
			"tk-b": {Label: "官方线乙", URL: "http://127.0.0.1:9/b/clip.mp4", URLKind: "mp4"},
		},
		failFirst: map[string]int{"tk-a": 1},
	}
	lines, err := dongpiandiResolveLinesAll(context.Background(), newDongpiandiRedeemClient(stub), "token1")
	if err != nil {
		t.Fatal(err)
	}
	official := 0
	for _, line := range lines {
		if line.Official {
			official++
		}
	}
	if official != 2 || len(lines) != 2 {
		t.Fatalf("首次失败重试后两条官方线都应在: lines=%d official=%d %+v", len(lines), official, lines)
	}
}

// 建号失败：兑换静默放弃（不固化错误，下次重试），票据线全部丢弃。
func TestDongpiandiResolveLinesAnonFailureDropsTickets(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		anonStatus: http.StatusInternalServerError,
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "官方线", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false},
		}),
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 0 {
		t.Fatalf("tickets without a session must be dropped: %+v", lines)
	}
	if stub.anonCalls != 1 || stub.redeemCalls != 0 {
		t.Fatalf("anon failed so no redemption: anon=%d redeem=%d", stub.anonCalls, stub.redeemCalls)
	}
}

// ---------- 直链判定（官方线结论反转：兑换产物=全片直链，不再按场景过滤） ----------

// probe3 真网取证推翻了「官方线是预告」的旧结论：官方票据兑换产物与三方直链
// 时长一致（m3u8 2890–2926s / mp4 mvhd 2891s，均为全片）。scenario 黑名单已删，
// 直链判定改为：URLKind 优先 → URL 后缀兜底 → http(s) 前缀保底（兑换产物常无
// 媒体后缀，按后缀硬判会误杀官方线）。
func TestDongpiandiDirectMediaLine(t *testing.T) {
	cases := []struct {
		name string
		line dongpiandiLine
		want bool
	}{
		{"票据", dongpiandiLine{URL: "resolve://tk-a", URLKind: "resolve_ticket"}, false},
		{"空地址", dongpiandiLine{}, false},
		{"URLKind m3u8", dongpiandiLine{URL: "http://a.test/v/index", URLKind: "m3u8"}, true},
		{"URLKind mp4", dongpiandiLine{URL: "http://a.test/v/clip", URLKind: "mp4"}, true},
		{"后缀 m3u8", dongpiandiLine{URL: "http://a.test/v/index.m3u8"}, true},
		{"后缀 mp4", dongpiandiLine{URL: "http://a.test/v/clip.mp4"}, true},
		{"无后缀 http 保底", dongpiandiLine{URL: "http://a.test/v/clip.image.image"}, true},
		{"无后缀 https 保底", dongpiandiLine{URL: "https://a.test/v/clip"}, true},
		{"page 网页线恒否", dongpiandiLine{URL: "https://c.test/player/1", URLKind: "page"}, false},
		{"非 http 协议", dongpiandiLine{URL: "ftp://a.test/v/clip.bin"}, false},
	}
	for _, c := range cases {
		if got := dongpiandiDirectMediaLine(c.line); got != c.want {
			t.Fatalf("%s: want %v got %v (%+v)", c.name, c.want, got, c.line)
		}
	}
}

// 复刻 probe3 真网形态：官方票据（高权重+selected）兑换出全片 mp4。
// 官方线必须与三方直链并存，且凭站点权重（selected+980）排在首位。
func TestDongpiandiResolveLinesKeepsOfficialRedemptions(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "1080P-官方S", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "selected": true, "preference_weight": 980},
			{"id": "l2", "label": "无水印资源", "url": "http://127.0.0.1:1/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "token_scenario": "direct_zero", "preference_weight": 790},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "1080P-官方S", URL: "http://127.0.0.1:9/intro/clip.mp4", URLKind: "mp4", TokenScenario: "series_intro_zero"},
		},
	}
	lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", true)
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 2 {
		t.Fatalf("official redemption must be kept beside the direct line: %+v", lines)
	}
	if lines[0].ID != "l1" || lines[0].URL != "http://127.0.0.1:9/intro/clip.mp4" || !lines[0].Resolved {
		t.Fatalf("official line must rank first with redeemed URL: %+v", lines[0])
	}
	if lines[1].ID != "l2" || lines[1].URL != "http://127.0.0.1:1/v/index.m3u8" {
		t.Fatalf("direct line must be kept second: %+v", lines[1])
	}
	if stub.redeemCalls != 1 {
		t.Fatalf("ticket must be redeemed once: %d", stub.redeemCalls)
	}
}

// 该集只有官方票据（三方全无）→ 兑换出的全片直链就是唯一可播线路，
// probe=true（播放期全量兑换）与 probe=false（无直连时兑换保底）两条路径
// 都必须产出它。
func TestDongpiandiResolveLinesOfficialOnlyEpisodeYieldsRedeemedLine(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "1080P-官方S", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "selected": true},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "1080P-官方S", URL: "http://127.0.0.1:9/intro/clip.mp4", URLKind: "mp4", TokenScenario: "series_intro_zero"},
		},
	}
	for _, probe := range []bool{true, false} {
		lines, err := dongpiandiResolveLines(context.Background(), newDongpiandiRedeemClient(stub), "token1", probe)
		if err != nil {
			t.Fatal(err)
		}
		if len(lines) != 1 || lines[0].URL != "http://127.0.0.1:9/intro/clip.mp4" || !lines[0].Resolved {
			t.Fatalf("probe=%v official-only episode must yield the redeemed line: %+v", probe, lines)
		}
	}
}

// probe3 实锤：官方兑换产物常无媒体后缀且 CDN 误标 image/jpeg，但字节流是
// 正片 mp4。探测与存活验证都必须按 ftyp/moov 魔数放行，真图片不得误判。
func TestDongpiandiSuffixlessMP4ProbeAndAlive(t *testing.T) {
	mp4Head := "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom\x00\x00\x00\x08moov"
	jpegHead := "\xff\xd8\xff\xe0JFIF\x00\x01"
	mux := http.NewServeMux()
	mux.HandleFunc("/mp4", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte(mp4Head))
	})
	mux.HandleFunc("/jpg", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "image/jpeg")
		_, _ = w.Write([]byte(jpegHead))
	})
	srv := httptest.NewServer(mux)
	defer srv.Close()
	ctx := context.Background()
	if !dongpiandiMediaAlive(ctx, srv.URL+"/mp4") {
		t.Fatal("suffix-less mp4 (ftyp/moov magic) must be considered alive")
	}
	if dongpiandiMediaAlive(ctx, srv.URL+"/jpg") {
		t.Fatal("jpeg payload must not be considered alive")
	}
	res := dongpiandiProbeLine(ctx, srv.URL+"/mp4")
	if !res.ready || res.segBytes <= 0 {
		t.Fatalf("suffix-less mp4 must probe ready: %+v", res)
	}
}
