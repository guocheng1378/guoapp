package core

// 真果·鉴「官方源」相关回归（2026-10-24 用户反馈四连）：
//  1. 一会儿有一回没官方源 —— 快路径有直连线时跳过兑换；
//  2. 有时连选源都没有 —— 线路面板只在 routeCount>=2 时出现，1 秒等待窗超时即空；
//  3. 官方源显示的不全 —— 无直连时只兑首张票据；
//  4. 让他默认就进官方源 —— 官方线排序/实测恒优先。
// 另含主页集数：批次剧（key=range-0001-0020）总集数解析与旧磁盘缓存集数清洗。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func resetDongpiandiLineCache(t *testing.T) {
	t.Helper()
	dongpiandiLinesMu.Lock()
	dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
	dongpiandiLinesMu.Unlock()
	t.Cleanup(func() {
		dongpiandiLinesMu.Lock()
		dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
		dongpiandiLinesMu.Unlock()
	})
}

// 详情/播放器线路列表路径（probe=false, full=true）：即使有三方直连线，
// 官方票据也必须全部兑出来——「一会儿有一回没官方源」「官方源显示的不全」
// 的回归护栏。
func TestDongpiandiResolveLinesAllKeepsEveryOfficial(t *testing.T) {
	stub := &dongpiandiRedeemStub{
		resolve: dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "新浪资源", "url": "http://127.0.0.1:1/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900, "selected": true},
			{"id": "l2", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 500},
			{"id": "l3", "label": "官方线乙", "url": "resolve://tk-b", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 400},
		}),
		tickets: map[string]dongpiandiLine{
			"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/a/clip.mp4", URLKind: "mp4"},
			"tk-b": {Label: "官方线乙", URL: "http://127.0.0.1:9/b/clip.mp4", URLKind: "mp4"},
		},
	}
	lines, err := dongpiandiResolveLinesAll(context.Background(), newDongpiandiRedeemClient(stub), "token1")
	if err != nil {
		t.Fatal(err)
	}
	if len(lines) != 3 {
		t.Fatalf("官方票据必须全部兑换并与直连线并存，得到 %d 条: %+v", len(lines), lines)
	}
	if stub.redeemCalls != 2 {
		t.Fatalf("两张官方票据都要兑换，实际 %d 次", stub.redeemCalls)
	}
	// 官方线权重(=500/400) 低于三方(900)，仍必须排在最前（默认进官方源）。
	if !lines[0].Official || !lines[1].Official {
		t.Fatalf("官方线必须排在前面: %+v", lines)
	}
	if lines[0].ID != "l2" || lines[1].ID != "l3" {
		t.Fatalf("官方线内部按权重降序: %+v", lines)
	}
	if lines[2].ID != "l1" {
		t.Fatalf("三方直连线排官方线之后: %+v", lines)
	}
}

// 官方线 score 必须压过任意三方线（含 selected + 高权重）。
func TestDongpiandiLineScoreOfficialWins(t *testing.T) {
	third := dongpiandiLine{Resolved: true, Selected: true, DefaultPriority: true, PreferenceWeight: 999, URLKind: "m3u8", URL: "http://a.test/v.m3u8"}
	official := dongpiandiLine{Resolved: true, Official: true, PreferenceWeight: 100, URLKind: "m3u8", URL: "http://a.test/o.m3u8"}
	if dongpiandiLineScore(official) <= dongpiandiLineScore(third) {
		t.Fatalf("官方线必须恒优先: official=%d third=%d", dongpiandiLineScore(official), dongpiandiLineScore(third))
	}
}

// 官方线权重低时不能被「全局 top4」挤出实测候选。
func TestDongpiandiProbeCandidatesKeepOfficial(t *testing.T) {
	lines := []dongpiandiLine{
		{URL: "http://a.test/1.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 950},
		{URL: "http://a.test/2.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 940},
		{URL: "http://a.test/3.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 930},
		{URL: "http://a.test/4.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 920},
		{URL: "http://a.test/official.m3u8", URLKind: "m3u8", Resolved: true, Official: true, PreferenceWeight: 100},
	}
	candidates := dongpiandiProbeCandidates(context.Background(), lines)
	var found bool
	for _, line := range candidates {
		if line.Official {
			found = true
		}
	}
	if !found {
		t.Fatalf("官方线必须进入实测候选: %+v", candidates)
	}
}

// dongpiandiProbeServer 提供可实测的 m3u8 + 分片。
func dongpiandiProbeServer(t *testing.T, segBytes int) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, ".m3u8") {
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			fmt.Fprintf(w, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\n%s/seg.ts\n#EXT-X-ENDLIST\n", "http://"+r.Host)
			return
		}
		w.Header().Set("Content-Type", "video/mp2t")
		_, _ = w.Write(make([]byte, segBytes))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// 官方线可达时即使三方线更快也选官方（用户定调默认进官方源）。
func TestDongpiandiProbeBestPrefersOfficial(t *testing.T) {
	officialSrv := dongpiandiProbeServer(t, 128*1024)
	thirdSrv := dongpiandiProbeServer(t, 512*1024)
	official := dongpiandiLine{URL: officialSrv.URL + "/v/index.m3u8", URLKind: "m3u8", Resolved: true, Official: true, PreferenceWeight: 100}
	third := dongpiandiLine{URL: thirdSrv.URL + "/v/index.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 999, Selected: true}
	got := dongpiandiProbeBest(context.Background(), []dongpiandiLine{third, official})
	if got != official.URL {
		t.Fatalf("官方线可达时必须默认官方，got=%s want=%s", got, official.URL)
	}
}

// 官方线整体不可达才降级三方。
func TestDongpiandiProbeBestFallsBackWhenOfficialDead(t *testing.T) {
	thirdSrv := dongpiandiProbeServer(t, 128*1024)
	official := dongpiandiLine{URL: "http://127.0.0.1:1/v/index.m3u8", URLKind: "m3u8", Resolved: true, Official: true}
	third := dongpiandiLine{URL: thirdSrv.URL + "/v/index.m3u8", URLKind: "m3u8", Resolved: true, PreferenceWeight: 900}
	got := dongpiandiProbeBest(context.Background(), []dongpiandiLine{official, third})
	if got != third.URL {
		t.Fatalf("官方线全挂时应降级三方，got=%s want=%s", got, third.URL)
	}
}

// 批次分集（短剧 20 集打成一个播放列表）的总集数解析。
func TestDongpiandiBatchTotal(t *testing.T) {
	eps := []dongpiandiEpisode{
		{Key: "range-0001-0020", Title: "第1-20集"},
		{Key: "range-0021-0040", Title: "第21-40集"},
		{Key: "range-0061-0096", Title: "第61-96集"},
	}
	if got := dongpiandiBatchTotal(eps); got != 96 {
		t.Fatalf("批次覆盖最大集号应为 96，得到 %d", got)
	}
	// 单集/综艺期数没有区间，不能瞎猜。
	if got := dongpiandiBatchTotal([]dongpiandiEpisode{{Title: "第1集"}, {Title: "第20261015期"}}); got != 0 {
		t.Fatalf("无区间标题应返回 0，得到 %d", got)
	}
	// 只有 key 没有标题也要认。
	if got := dongpiandiBatchTotal([]dongpiandiEpisode{{Key: "range-0001-0030"}}); got != 30 {
		t.Fatalf("仅 key 时应解析出 30，得到 %d", got)
	}
}

// 旧磁盘缓存里真果·鉴的集数可能是播放量残留（「共 1150 集」），
// 元数据版本升级后加载即清零，刷新后由 playback_groups 重算。
func TestMigrateNativeDramaClearsLegacyDongpiandiEpisodes(t *testing.T) {
	legacy := migrateNativeDrama(nativeDrama{MetadataSchema: 1, Source: sourceDongpiandi, Episodes: 1150})
	if legacy.Episodes != 0 || legacy.MetadataSchema != nativeDramaMetadataSchema {
		t.Fatalf("旧版真果·鉴集数应清零并升级版本: %+v", legacy)
	}
	fresh := migrateNativeDrama(nativeDrama{MetadataSchema: nativeDramaMetadataSchema, Source: sourceDongpiandi, Episodes: 96})
	if fresh.Episodes != 96 {
		t.Fatalf("当前版本集数必须保留: %+v", fresh)
	}
	other := migrateNativeDrama(nativeDrama{MetadataSchema: 1, Source: "hongguo", Episodes: 40})
	if other.Episodes != 40 {
		t.Fatalf("其它源集数不受影响: %+v", other)
	}
}

// 播放期线路列表优先用详情解析缓存（零网络），官方线一条不少。
func TestDongpiandiRouteLinesUsesCachedLines(t *testing.T) {
	resetDongpiandiLineCache(t)
	epID := providerDramaID(sourceDongpiandi, "av_cached")
	// 缓存 key 与 detail 写入保持一致：分集源 ID（不带源前缀）。
	dongpiandiCacheLines("av_cached", []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "官方线甲", Resolved: true, Official: true},
		{URL: "http://cached.test/third.m3u8", Label: "新浪资源", Resolved: true},
	}, true)
	// 站点根指向拒绝连接地址：缓存命中时不应发起任何网络请求。
	withDongpiandiBaseURL(t, "http://127.0.0.1:1")
	downloader := &Downloader{}
	lines := downloader.dongpiandiRouteLines(context.Background(), Task{Chapter: Chapter{
		ID:      epID,
		PageURL: "http://127.0.0.1:1/player/av_cached",
	}})
	if len(lines) != 2 || lines[0].Label != "官方线甲" || !lines[0].Official {
		t.Fatalf("应命中缓存的完整线路表: %+v", lines)
	}
}

// 详情解析：全量兑换官方票据、默认地址落在官方线、线路表进缓存。
func TestDongpiandiDetailRedeemsOfficialsAndCaches(t *testing.T) {
	resetDongpiandiLineCache(t)
	var srv *httptest.Server
	var catalogCalls, redeemCalls atomic.Int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			catalogCalls.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"id":"av_d1","title":"测试剧","content_kind":"short_drama","available_episode_count":1,"total_episode_count":20,"episodes":[{"id":"av_e1","key":"range-0001-0020","title":"第1-20集","token":"tk-ep"}]}`)
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"object":"playback.resolve","line_options":[
				{"id":"l1","label":"新浪资源","url":"%s/third/index.m3u8","url_kind":"m3u8","resolved":true,"preference_weight":900,"selected":true},
				{"id":"l2","label":"1080P-官方S","url":"resolve://tk-official","url_kind":"resolve_ticket","resolved":false,"preference_weight":300}]}`, srv.URL)
		case r.URL.Path == "/v1/users/anonymous":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{}`))
		case r.URL.Path == "/v1/playback/resolve-line":
			redeemCalls.Add(1)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{"line":{"label":"1080P-官方S","url":"%s/official/clip.mp4","url_kind":"mp4"}}`, srv.URL)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	srv = httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	withDongpiandiBaseURL(t, srv.URL)

	downloader := &Downloader{}
	drama, chapters, err := downloader.fetchDongpiandiDetail(context.Background(), "av_d1")
	if err != nil {
		t.Fatal(err)
	}
	if catalogCalls.Load() != 1 {
		t.Fatalf("详情只应拉一次 catalog，实际 %d", catalogCalls.Load())
	}
	if redeemCalls.Load() != 1 {
		t.Fatalf("官方票据必须兑换，实际 %d 次", redeemCalls.Load())
	}
	if drama.EpisodeCount != 20 {
		t.Fatalf("批次剧总集数应为 20（或 total_episode_count），得到 %d", drama.EpisodeCount)
	}
	if len(chapters) != 1 {
		t.Fatalf("章节数应为 1，得到 %d", len(chapters))
	}
	if want := srv.URL + "/official/clip.mp4"; chapters[0].VideoURL != want {
		t.Fatalf("详情地址必须默认官方线: got=%s want=%s", chapters[0].VideoURL, want)
	}
	cached := dongpiandiCachedLines("av_e1")
	if len(cached) != 2 || !cached[0].Official {
		t.Fatalf("线路表应写入缓存且官方线在首位: %+v", cached)
	}
	// 缓存内容是可 JSON 往返的（不含不可序列化字段），供播放期直接转 Variants。
	if _, err := json.Marshal(cached); err != nil {
		t.Fatalf("cache must be marshable: %v", err)
	}
}

// 兑换被限流（429/空响应）导致官方线残缺时：三方直连照常进缓存（长效，
// 这些集不必每次播放都重新 resolve），官方部分不刷新——既不把上一次兑好的
// 官方线擦掉，也不会把残缺官方钉进缓存。
func TestDongpiandiDetailCachesThirdLineWhenRedeemIncomplete(t *testing.T) {
	resetDongpiandiLineCache(t)
	var srv *httptest.Server
	var redeemCalls atomic.Int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			fmt.Fprintf(w, `{"id":"av_d2","title":"限流剧","content_kind":"short_drama","available_episode_count":1,"total_episode_count":1,"episodes":[{"id":"av_e2","title":"第1集","token":"tk-ep2"}]}`)
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			fmt.Fprintf(w, `{"object":"playback.resolve","line_options":[
				{"id":"l1","label":"新浪资源","url":"%s/third/index.m3u8","url_kind":"m3u8","resolved":true,"preference_weight":900},
				{"id":"l2","label":"1080P-官方S","url":"resolve://tk-limited","url_kind":"resolve_ticket","resolved":false}]}`, srv.URL)
		case r.URL.Path == "/v1/users/anonymous":
			_, _ = w.Write([]byte(`{}`))
		case r.URL.Path == "/v1/playback/resolve-line":
			// 模拟站点限流：兑换永远返回空响应。
			redeemCalls.Add(1)
			_, _ = w.Write([]byte(`{}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	srv = httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	withDongpiandiBaseURL(t, srv.URL)

	downloader := &Downloader{}
	_, chapters, err := downloader.fetchDongpiandiDetail(context.Background(), "av_d2")
	if err != nil {
		t.Fatal(err)
	}
	// 详情页是批量预兑换（几十集一起跑），不允许退避重试把页面拖成分钟级
	// 转圈：单张票据只尝试一次，撞限流直接熔断。
	if redeemCalls.Load() != 1 {
		t.Fatalf("详情页兑换失败不应重试，实际尝试 %d 次", redeemCalls.Load())
	}
	if len(chapters) != 1 || chapters[0].VideoURL != srv.URL+"/third/index.m3u8" {
		t.Fatalf("兑换失败时应回退三方直链: %+v", chapters)
	}
	cached := dongpiandiCachedLines("av_e2")
	if len(cached) != 1 || cached[0].Official || !strings.Contains(cached[0].URL, "/third/index.m3u8") {
		t.Fatalf("官方残缺时应只缓存三方直连: %+v", cached)
	}
}

// 官方直链是 139 云盘预签名地址（实测 X-Amz-Expires=900），缓存必须短于
// 15 分钟；三方直连长效。两套 TTL 独立过期。
func TestDongpiandiLineCacheSplitsTTL(t *testing.T) {
	resetDongpiandiLineCache(t)
	epID := "av_ttl"
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "1080P-官方D", Official: true, Resolved: true},
		{URL: "http://cached.test/third.m3u8", Label: "新浪资源", Resolved: true},
	}, true)
	if got := dongpiandiCachedLines(epID); len(got) != 2 {
		t.Fatalf("刚写入应两条都在: %+v", got)
	}
	// 官方线过期、三方仍新鲜 → 只剩三方。
	dongpiandiLinesMu.Lock()
	entry := dongpiandiLinesCache[epID]
	entry.officialAt = time.Now().Add(-dongpiandiOfficialLineTTL - time.Minute)
	dongpiandiLinesCache[epID] = entry
	dongpiandiLinesMu.Unlock()
	if lines := dongpiandiCachedLines(epID); len(lines) != 1 || lines[0].Official {
		t.Fatalf("官方直链过期后只应保留三方: %+v", lines)
	}
	// 三方也过期 → 整条缓存失效。
	dongpiandiLinesMu.Lock()
	entry = dongpiandiLinesCache[epID]
	entry.thirdAt = time.Now().Add(-dongpiandiThirdLineTTL - time.Minute)
	dongpiandiLinesCache[epID] = entry
	dongpiandiLinesMu.Unlock()
	if got := dongpiandiCachedLines(epID); len(got) != 0 {
		t.Fatalf("两部分都过期应返回空: %+v", got)
	}
}

// 一次限流丢线（officialComplete=false）不得把上一次兑好的官方线擦掉。
func TestDongpiandiLineCacheKeepsOfficialOnIncomplete(t *testing.T) {
	resetDongpiandiLineCache(t)
	epID := "av_keep"
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "1080P-官方D", Official: true, Resolved: true},
		{URL: "http://cached.test/third.m3u8", Label: "新浪资源", Resolved: true},
	}, true)
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/third2.m3u8", Label: "索尼资源", Resolved: true},
	}, false)
	lines := dongpiandiCachedLines(epID)
	if len(lines) != 2 || !lines[0].Official || !strings.Contains(lines[1].URL, "third2") {
		t.Fatalf("残缺刷新应保留官方线并替换三方: %+v", lines)
	}
}

// 官方直链过期 + 网络不可用：线路表回退到缓存里的三方（不能整表返空，
// 也别把已失效的官方地址递给播放器）。
func TestDongpiandiRouteLinesFallsBackToThirdWhenOfficialStale(t *testing.T) {
	resetDongpiandiLineCache(t)
	epID := "av_stale"
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "1080P-官方D", Official: true, Resolved: true},
		{URL: "http://cached.test/third.m3u8", Label: "新浪资源", Resolved: true},
	}, true)
	dongpiandiLinesMu.Lock()
	entry := dongpiandiLinesCache[epID]
	entry.officialAt = time.Now().Add(-dongpiandiOfficialLineTTL - time.Minute)
	dongpiandiLinesCache[epID] = entry
	dongpiandiLinesMu.Unlock()
	withDongpiandiBaseURL(t, "http://127.0.0.1:1") // 网络必失败
	lines := (&Downloader{}).dongpiandiRouteLines(context.Background(), Task{Chapter: Chapter{
		ID:      providerDramaID(sourceDongpiandi, epID),
		PageURL: "http://127.0.0.1:1/player/av_stale",
	}})
	if len(lines) != 1 || lines[0].Official {
		t.Fatalf("官方过期且网络失败时应回退三方缓存: %+v", lines)
	}
}

// 官方直链过期 + 站点可达：重解析把官方线重兑回来并刷新缓存。
func TestDongpiandiRouteLinesRefreshesStaleOfficial(t *testing.T) {
	resetDongpiandiLineCache(t)
	var srv *httptest.Server
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/catalog/"):
			fmt.Fprint(w, `{"id":"av_r","title":"刷新剧","episodes":[{"id":"av_r1","title":"第1集","token":"tk-r"}]}`)
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			fmt.Fprintf(w, `{"object":"playback.resolve","line_options":[
				{"id":"l1","label":"新浪资源","url":"%s/third/index.m3u8","url_kind":"m3u8","resolved":true,"preference_weight":900},
				{"id":"l2","label":"1080P-官方S","url":"resolve://tk-r","url_kind":"resolve_ticket","resolved":false}]}`, srv.URL)
		case r.URL.Path == "/v1/users/anonymous":
			fmt.Fprint(w, `{}`)
		case r.URL.Path == "/v1/playback/resolve-line":
			fmt.Fprintf(w, `{"line":{"url":"%s/official/clip.mp4","url_kind":"mp4"}}`, srv.URL)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	srv = httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	withDongpiandiBaseURL(t, srv.URL)

	epID := "av_r1"
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official-old.mp4", Label: "1080P-旧", Official: true, Resolved: true},
		{URL: "http://cached.test/third-old.m3u8", Label: "旧三方", Resolved: true},
	}, true)
	dongpiandiLinesMu.Lock()
	entry := dongpiandiLinesCache[epID]
	entry.officialAt = time.Now().Add(-dongpiandiOfficialLineTTL - time.Minute)
	dongpiandiLinesCache[epID] = entry
	dongpiandiLinesMu.Unlock()

	lines := (&Downloader{}).dongpiandiRouteLines(context.Background(), Task{Chapter: Chapter{
		ID:      providerDramaID(sourceDongpiandi, epID),
		PageURL: srv.URL + "/player/av_r",
	}})
	if len(lines) != 2 || !lines[0].Official || !strings.Contains(lines[0].URL, "/official/clip.mp4") {
		t.Fatalf("官方过期应重解析并刷新官方线: %+v", lines)
	}
	if _, stale := dongpiandiCachedLinesState(epID); stale {
		t.Fatalf("重解析成功后缓存里的官方线应是新鲜的")
	}
}

// 清晰度只能从线路标签里读（站点没有独立数值字段）："1080P-官方D" → 1080。
func TestDongpiandiLineQualityFromLabel(t *testing.T) {
	cases := map[string]int{
		"1080P-官方D": 1080,
		"720P":      720,
		"1080p官方":   1080,
		"新浪资源":      0,
		"4K":        0,
		"":          0,
	}
	for label, want := range cases {
		if got := dongpiandiLineQuality(label); got != want {
			t.Fatalf("%q: got %d want %d", label, got, want)
		}
	}
	media := dongpiandiLineMedia(dongpiandiLine{URL: "http://x/a.mp4", Label: "720P-官方S", Official: true})
	if media.Quality != 720 || !media.Official {
		t.Fatalf("线路媒体应带清晰度与官方标记: %+v", media)
	}
}

// 「仅官方线路」：收敛与择优都只留官方线，关掉后恢复三方。
func TestDongpiandiOfficialOnlyFiltersThirdLines(t *testing.T) {
	t.Cleanup(func() { setDongpiandiOfficialOnly(false) })
	lines := []dongpiandiLine{
		{URL: "http://x/third.m3u8", Label: "新浪资源", Resolved: true, PreferenceWeight: 900},
		{URL: "http://x/official.mp4", Label: "1080P-官方D", Resolved: true, Official: true},
	}
	setDongpiandiOfficialOnly(true)
	if got := dongpiandiKeepOfficialOnly(lines); len(got) != 1 || !got[0].Official {
		t.Fatalf("仅官方应只剩官方线: %+v", got)
	}
	if kept := dongpiandiCurateLines(context.Background(), lines, 10*time.Millisecond); len(kept) != 1 || !kept[0].Official {
		t.Fatalf("curate 应只留官方: %+v", kept)
	}
	if cand := dongpiandiProbeCandidates(context.Background(), lines); len(cand) != 1 || !cand[0].Official {
		t.Fatalf("择优候选应只含官方: %+v", cand)
	}
	setDongpiandiOfficialOnly(false)
	if got := dongpiandiKeepOfficialOnly(lines); len(got) != 2 {
		t.Fatalf("关闭后应恢复三方: %+v", got)
	}
}

// 流代理重签：有缓存票据时只重兑一次，不走 catalog/详情，并把新直链写回缓存。
func TestDongpiandiRenewMediaRedeemsCachedTicket(t *testing.T) {
	resetDongpiandiLineCache(t)
	var srv *httptest.Server
	var redeemCalls atomic.Int32
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case r.URL.Path == "/v1/users/anonymous":
			fmt.Fprint(w, `{}`)
		case r.URL.Path == "/v1/playback/resolve-line":
			redeemCalls.Add(1)
			fmt.Fprintf(w, `{"line":{"id":"l2","label":"1080P-官方D","url":"%s/official/new.mp4","url_kind":"mp4"}}`, srv.URL)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	})
	srv = httptest.NewServer(handler)
	t.Cleanup(srv.Close)
	withDongpiandiBaseURL(t, srv.URL)

	dongpiandiCacheTickets("av_rn", []dongpiandiLine{{ID: "l2", Label: "1080P-官方D", URL: "resolve://tk-new"}})
	media, err := (&Downloader{}).dongpiandiRenewMedia(context.Background(), Task{Chapter: Chapter{
		ID: providerDramaID(sourceDongpiandi, "av_rn"),
	}})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != srv.URL+"/official/new.mp4" || media.Quality != 1080 || !media.Official {
		t.Fatalf("重兑应返回新直链、清晰度与官方标记: %+v", media)
	}
	if redeemCalls.Load() != 1 {
		t.Fatalf("只应兑换一次，实际 %d", redeemCalls.Load())
	}
	cached := dongpiandiCachedLines("av_rn")
	if len(cached) != 1 || cached[0].URL != srv.URL+"/official/new.mp4" || !cached[0].Official {
		t.Fatalf("重兑结果应刷新官方缓存: %+v", cached)
	}
}
