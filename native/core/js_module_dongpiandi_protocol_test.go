package core

import (
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// TestDongpiandiModuleSignature 验证 JS 模块的 HMAC 签名与 Go dongpiandiSign 逐字节一致。
func TestDongpiandiModuleSignature(t *testing.T) {
	var gotMethod, gotSignature, gotTS, gotNonce, gotPath string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod, gotSignature = r.Method, r.Header.Get("x-ai-movie-signature")
		gotTS, gotNonce = r.Header.Get("x-ai-movie-timestamp"), r.Header.Get("x-ai-movie-nonce")
		gotPath = r.URL.RequestURI()
		if r.Header.Get("x-ai-movie-site-host") != "dongpiandi.ai" {
			t.Errorf("site-host = %q", r.Header.Get("x-ai-movie-site-host"))
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"catalog","cards":[],"pagination":{"has_more":false}}`)
	}))
	defer server.Close()

	root := installDongpiandiTestModule(t, server.URL, "dpsigclique")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer provider.Unregister("dpsigclique")
	entry, _ := provider.Get("dpsigclique")
	if _, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), d.host(), 2, "short_drama", ""); err != nil {
		t.Fatal(err)
	}

	payload := gotMethod + "\n" + gotPath + "\n" + gotTS + "\n" + gotNonce
	mac := hmac.New(sha256.New, []byte(dongpiandiSignKey))
	_, _ = mac.Write([]byte(payload))
	want := hex.EncodeToString(mac.Sum(nil))
	// JS 用 pathWithQuery（不含 host），Go 侧 gotPath 是 RequestURI（含 query），一致。
	if !strings.HasPrefix(gotPath, "/v1/browse/catalog?") {
		t.Fatalf("请求路径异常: %q", gotPath)
	}
	if gotSignature != want {
		t.Fatalf("JS 签名与 Go 不一致: js=%s go=%s (payload=%q)", gotSignature, want, payload)
	}
}

// fakeDongpiandiServer 按真网结构提供目录/详情/取流/建议接口。
func fakeDongpiandiServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/browse/catalog", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		q := r.URL.Query()
		if q.Get("q") != "" {
			_, _ = fmt.Fprint(w, `{"object":"catalog","cards":[
				{"id":"a1","title":"测试搜索剧","content_kind":"short_drama","poster_url":"https://img.example/a.jpg","playback_groups":[{"episode_count":12}],"remarks":"全12集","score":9.2,"heat_value":35000},
				{"id":"a2","title":"无关剧","content_kind":"series","playback_groups":[{"episode_count":5}]}
			],"pagination":{"has_more":false}}`)
			return
		}
		_, _ = fmt.Fprint(w, `{"object":"catalog","cards":[
			{"id":"d1","title":"测试剧第一季","normalized_title":"测试剧","content_kind":"short_drama","year":2026,"area":"内地","genres":["总裁","逆袭"],"actors":["甲","乙"],"poster_url":"https://img.example/cover.jpg","score":8.5,"remarks":"更新至74集","heat_value":120000,"playback_groups":[{"episode_count":74}]}
		],"pagination":{"has_more":false}}`)
	})
	mux.HandleFunc("/v1/catalog/d1", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"catalog","id":"d1","title":"测试剧第一季","content_kind":"short_drama","year":2026,"area":"内地","genres":["总裁"],"actors":["甲"],"poster_url":"https://img.example/cover.jpg",
			"description":"简介正文","available_episode_count":74,"total_episode_count":100,"update_status":"ongoing","episode_progress_text":"更新至74集",
			"episodes":[
				{"id":"d1e1","title":"第1集","number":1,"token":"tk-1"},
				{"id":"d1e2","title":"第2集","number":2,"token":"tk-2"}
			],
			"playback_skip_settings_preset":{"intro_end_seconds":90,"outro_from_end_seconds":30}}
			`)
	})
	mux.HandleFunc("/v1/playback/resolve/tk-1", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(w, `{"object":"playback.resolve","token":"tk-1","line_options":[
			{"id":"l1","label":"新浪资源","url":"%s/third/index.m3u8","url_kind":"m3u8","resolved":true,"preference_weight":900,"selected":true}
		]}`, "http://"+r.Host)
	})
	mux.HandleFunc("/v1/suggest", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"suggest","query":"测试","suggestions":[
			{"label":"测试剧","subtitle":"短剧","intent":"play","prompt":"测试剧","target":{"variant_id":"d1","title":"测试剧","direct_playable":true}},
			{"label":"测试剧第二季","subtitle":"","intent":"search","prompt":"","action":{"type":"search","prompt":"搜测试剧"}}
		]}`)
	})
	mux.HandleFunc("/media/ep1.m3u8", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = fmt.Fprint(w, "#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10.0,\nseg1.ts\n#EXT-X-ENDLIST\n")
	})
	mux.HandleFunc("/v1/feed/home", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"feed.home","expires_at":"2026-11-20T00:00:00Z","sections":[
			{"id":"sec1","title":"大家都在看","subtitle":"热门","type":"collection","role":"primary","priority":100,
			 "browse":{"label":"查看完整榜单","path":"/v1/browse/catalog","params":{"kind":"short_drama"}},
			 "cards":[{"id":"d1","title":"测试剧第一季","content_kind":"short_drama","poster_url":"https://img.example/cover.jpg","playback_groups":[{"episode_count":74}],"remarks":"更新至74集"}]},
			{"id":"sec2","title":"新剧速递","subtitle":"","type":"trend","role":"secondary","priority":50,
			 "browse":{"label":"","path":"","params":{}},
			 "cards":[{"id":"a1","title":"测试搜索剧","content_kind":"short_drama","poster_url":"https://img.example/a.jpg","playback_groups":[{"episode_count":12}]}]}
		]}`)
	})
	mux.HandleFunc("/v1/watch-calendar", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"watch-calendar","title":"本周追剧","days":[{"date":"2026-11-19","label":"周四","groups":{"series":{"preview":[{"id":"d1","title":"测试剧第一季","content_kind":"series","poster_url":"https://img.example/cover.jpg","latest_episode_label":"更新至12集","season_label":"第一季","heat_score":5000,"forecast":{"label":"今日更新","kind":"episode"}}]}}},{"date":"2026-11-20","label":"周五","groups":{"series":{"preview":[{"variant_id":"a1","title":"测试搜索剧","content_kind":"series","poster_url":"https://img.example/a.jpg","latest_episode_label":"第3集"}]}}}]}`)
	})
	mux.HandleFunc("/v1/comments", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, `{"object":"comments","returned_count":4,"has_more":false,"next_cursor":"","results":[
			{"id":"c1","content":"第一条  弹幕","status":"visible","metadata":{"playback_context":{"episode_id":"d1e1","position_seconds":3.5}}},
			{"id":"c2","content":"折叠评论","status":"folded","metadata":{"playback_context":{"episode_id":"d1e1","position_seconds":10}}},
			{"id":"c3","content":"别集评论","status":"visible","metadata":{"playback_context":{"episode_id":"d1e2","position_seconds":12}}},
			{"id":"c4","content":"第二条","status":"visible","metadata":{"playback_context":{"episode_id":"d1e1","position_seconds":"95.2"}}}
		]}`)
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func installDongpiandiTestModule(t *testing.T, base, id string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["dongpiandi"]
	if !found || source.code == nil {
		t.Fatal("未找到内置真果鉴模块")
	}
	manifest := source.manifest
	manifest.ID = id
	manifest.Name = "真果鉴测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, source.code); err != nil {
		t.Fatal(err)
	}
	return root
}

// TestDongpiandiModuleProtocol 验证 JS 端口的字段映射与签名头：目录/搜索/详情/建议。
func TestDongpiandiModuleProtocol(t *testing.T) {
	server := fakeDongpiandiServer(t)
	root := installDongpiandiTestModule(t, server.URL, "dptestclique")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer provider.Unregister("dptestclique")

	entry, found := provider.Get("dptestclique")
	if !found {
		t.Fatal("模块未注册")
	}
	cataloguer := entry.(provider.Cataloguer)
	ctx := t.Context()

	cats, err := cataloguer.Categories(ctx, d.host())
	if err != nil || len(cats) < 6 || cats[1].ID != "short_drama" {
		t.Fatalf("categories = %v %v", cats, err)
	}

	items, more, err := cataloguer.CatalogPage(ctx, d.host(), 1, "", "")
	if err != nil || len(items) != 1 || more {
		t.Fatalf("catalog = %d more=%v err=%v", len(items), more, err)
	}
	first := items[0]
	if first.Title != "测试剧第一季" || first.SourceID != "d1" {
		t.Fatalf("目录字段错位: title=%q sourceID=%q", first.Title, first.SourceID)
	}
	if fmt.Sprintf("%v", first.EpisodeCount) != "74" {
		t.Fatalf("集数 = %v, want 74", first.EpisodeCount)
	}
	if first.ReleaseStatus != "ongoing" {
		t.Fatalf("连载状态 = %s", first.ReleaseStatus)
	}
	if first.Category != "短剧" || first.ContentKind != "short" {
		t.Fatalf("分类错位: category=%s contentKind=%s", first.Category, first.ContentKind)
	}

	detailer := entry.(provider.Detailer)
	drama, chapters, err := detailer.Detail(ctx, d.host(), "d1")
	if err != nil {
		t.Fatal(err)
	}
	if drama.Title != "测试剧第一季" || len(chapters) != 2 {
		t.Fatalf("详情错位: title=%q chapters=%d", drama.Title, len(chapters))
	}
	if fmt.Sprintf("%v", drama.EpisodeCount) != "74" || drama.ReleaseStatus != "ongoing" {
		t.Fatalf("详情集数/状态 = %v/%s", drama.EpisodeCount, drama.ReleaseStatus)
	}
	if !strings.Contains(chapters[0].ID, "d1e1") || string(chapters[0].CurrentEpisode) != "1" {
		t.Fatalf("分集错位: id=%s ep=%s", chapters[0].ID, chapters[0].CurrentEpisode)
	}

	// 跳过预设：detail 已缓存，模块能力应读出并进位（90→90，30→30）。
	if skip, ok := entry.(moduleSkipPresetProvider); ok {
		introSec, outroSec, presetOK := skip.ModuleSkipPreset(ctx, d.host(), Task{DramaID: "dptestclique:d1"})
		if !presetOK || introSec != 90 || outroSec != 30 {
			t.Fatalf("跳过预设 = %d/%d ok=%v", introSec, outroSec, presetOK)
		}
	} else {
		t.Error("模块未提供 skipPreset 能力")
	}

	searcher := entry.(provider.Searcher)
	searchItems, err := searcher.Search(ctx, d.host(), "测试")
	if err != nil || len(searchItems) != 1 || searchItems[0].Title != "测试搜索剧" {
		t.Fatalf("搜索 = %v err=%v", searchItems, err)
	}

	suggester := entry.(moduleSuggester)
	names, err := suggester.ModuleSuggestions(ctx, d.host(), "测试")
	if err != nil || len(names) != 2 || names[0] != "测试剧" {
		t.Fatalf("建议 = %v err=%v", names, err)
	}

	// 直达建议：第一条带 variantId/directPlayable，第二条 prompt 回退 action.prompt。
	direct, ok := entry.(moduleDirectSuggester)
	if !ok {
		t.Fatal("模块未提供 suggestDirect 能力")
	}
	suggestions, err := direct.ModuleDirectSuggestions(ctx, d.host(), "测试")
	if err != nil || len(suggestions) != 2 {
		t.Fatalf("直达建议 = %v err=%v", suggestions, err)
	}
	if suggestions[0].VariantID != "d1" || !suggestions[0].DirectPlayable {
		t.Fatalf("第一条直达建议 = %+v", suggestions[0])
	}
	if suggestions[1].Prompt != "搜测试剧" || suggestions[1].VariantID != "" {
		t.Fatalf("第二条直达建议 = %+v", suggestions[1])
	}

	// 取流：模块的 resolveMedia 应从 chapter.videoUrl 直接产出媒体。
	resolver := entry.(provider.MediaResolver)
	mediaURL := server.URL + "/media/ep1.m3u8"
	media, err := resolver.ResolveMedia(ctx, d.host(), Task{
		DramaID: "dptestclique:d1",
		Chapter: Chapter{ID: "dptestclique:d1:d1e1", Source: "dptestclique", VideoURL: mediaURL},
	})
	if err != nil || media.URL != mediaURL {
		t.Fatalf("resolveMedia = %+v err=%v", media, err)
	}

	// 线路面板：模块解析出完整线路表（含 label/official/quality）。
	routesProvider, ok := entry.(moduleRoutesProvider)
	if !ok {
		t.Fatal("模块未提供 routes 能力")
	}
	lines, err := routesProvider.ModuleRoutes(ctx, d.host(), Task{
		DramaID: "dptestclique:d1",
		Chapter: Chapter{ID: "dptestclique:d1:d1e1", Source: "dptestclique", PageURL: server.URL + "/player/d1"},
	})
	if err != nil || len(lines) != 1 {
		t.Fatalf("routes = %+v err=%v", lines, err)
	}
	if !strings.Contains(lines[0].URL, "/third/index.m3u8") || lines[0].Label != "新浪资源" {
		t.Fatalf("线路字段错位: %+v", lines[0])
	}
}

// TestDongpiandiModuleDanmaku 验证弹幕能力：IDs 提取 + 窗口分页 + 文本/状态过滤。
func TestDongpiandiModuleDanmaku(t *testing.T) {
	server := fakeDongpiandiServer(t)
	root := installDongpiandiTestModule(t, server.URL, "dpdanmakuclique")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer provider.Unregister("dpdanmakuclique")
	entry, _ := provider.Get("dpdanmakuclique")
	danmaku, ok := entry.(moduleDanmakuProvider)
	if !ok {
		t.Fatal("模块未提供弹幕能力")
	}
	ctx := t.Context()
	series, video, ok := danmaku.ModuleDanmakuIDs(ctx, d.host(), Task{
		DramaID: "dpdanmakuclique:d1",
		Chapter: Chapter{ID: "dpdanmakuclique:d1:d1e1", Source: "dpdanmakuclique"},
	})
	if !ok || series != "d1" || video != "d1e1" {
		t.Fatalf("弹幕 IDs = %q/%q ok=%v", series, video, ok)
	}

	// start=0, duration=120000：命中 c1(3500ms) 与 c4(95200ms)，折叠/别集被过滤。
	page, err := danmaku.ModuleDanmaku(ctx, d.host(), series, video, 0, 120000)
	if err != nil {
		t.Fatal(err)
	}
	if page.EpisodeID != "d1e1" || page.StartMS != 0 || page.Total != 2 {
		t.Fatalf("弹幕页元信息 = %+v", page)
	}
	if len(page.Items) != 2 {
		t.Fatalf("弹幕条数 = %d, want 2 (%+v)", len(page.Items), page.Items)
	}
	if page.Items[0].Text != "第一条 弹幕" || page.Items[0].TimeMS != 3500 {
		t.Fatalf("首条弹幕 = %+v", page.Items[0])
	}
	if page.Items[1].Text != "第二条" || page.Items[1].TimeMS != 95200 {
		t.Fatalf("末条弹幕 = %+v", page.Items[1])
	}
	// 未截断：next = 最晚(95200)+30000 = 125200，夹到 duration=120000。
	if page.NextMS != 120000 {
		t.Fatalf("nextMs = %d, want 120000", page.NextMS)
	}
}

// TestDongpiandiModuleHome 验证首页板块/翻页/追剧周表能力。
func TestDongpiandiModuleHome(t *testing.T) {
	server := fakeDongpiandiServer(t)
	root := installDongpiandiTestModule(t, server.URL, "dphomeclique")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer provider.Unregister("dphomeclique")
	entry, _ := provider.Get("dphomeclique")
	home, ok := entry.(moduleHomeProvider)
	if !ok {
		t.Fatal("模块未提供 homeProvider 能力")
	}
	ctx := t.Context()

	raw, err := home.ModuleHomeFeed(ctx, d.host(), false)
	if err != nil {
		t.Fatal(err)
	}
	var feed struct {
		Items     []map[string]any `json:"items"`
		ExpiresAt int64            `json:"expiresAt"`
	}
	if err := json.Unmarshal(raw, &feed); err != nil {
		t.Fatal(err)
	}
	if len(feed.Items) != 2 || feed.Items[0]["title"] != "大家都在看" {
		t.Fatalf("homeFeed = %s", string(raw))
	}
	if feed.ExpiresAt <= 0 {
		t.Fatalf("expiresAt = %d", feed.ExpiresAt)
	}

	raw, err = home.ModuleHomeSection(ctx, d.host(), "sec1", 1)
	if err != nil {
		t.Fatal(err)
	}
	var section struct {
		Items   []map[string]any `json:"items"`
		HasMore bool             `json:"hasMore"`
		Page    int              `json:"page"`
	}
	if err := json.Unmarshal(raw, &section); err != nil {
		t.Fatal(err)
	}
	if len(section.Items) == 0 || section.Page != 1 {
		t.Fatalf("homeSection = %s", string(raw))
	}

	raw, err = home.ModuleHomeCalendar(ctx, d.host(), false)
	if err != nil {
		t.Fatal(err)
	}
	var calendar struct {
		Days []struct {
			Date  string           `json:"date"`
			Label string           `json:"label"`
			Items []map[string]any `json:"items"`
		} `json:"days"`
	}
	if err := json.Unmarshal(raw, &calendar); err != nil {
		t.Fatal(err)
	}
	if len(calendar.Days) != 2 || calendar.Days[0].Date != "2026-11-19" || len(calendar.Days[0].Items) != 1 {
		t.Fatalf("homeCalendar = %s", string(raw))
	}
}
