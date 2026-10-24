package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"sync/atomic"
	"testing"
	"time"
)

func doubanFixture(start, total int, items []map[string]any) []byte {
	payload := map[string]any{
		"start":                    start,
		"count":                    len(items),
		"total":                    total,
		"subject_collection_items": items,
	}
	raw, _ := json.Marshal(payload)
	return raw
}

func doubanItems() []map[string]any {
	return []map[string]any{
		{
			"id": "37068446", "rank": 1, "rank_value": 1,
			"title":         "加密火车",
			"cover_url":     "https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2936442661.jpg",
			"card_subtitle": "2026 / 德国 法国 / 科幻 惊悚",
			"description":   "医疗速递员意外深陷全城失控的病毒浩劫。",
			"rating":        map[string]any{"value": 8.5, "count": 123456},
			"tags": []map[string]any{
				{"name": "院线热映", "type": "manual"},
				{"name": "恐怖", "type": "manual"},
			},
		},
		{
			"id": "36179101", "rank": 2, "rank_value": 2,
			"title":         "希望",
			"rating":        map[string]any{"value": 7.3},
			"card_subtitle": "2003 / 中国香港",
		},
		{
			"id": "36179999", "rank": 3, "rank_value": 3,
			"title":         "未开分",
			"card_subtitle": "2027 / 美国",
		},
	}
}

func TestDoubanRankingParsesPicCover(t *testing.T) {
	// TV 剧集合集（tv_domestic）的封面是 pic 对象（large/normal），不是
	// cover_url 字符串；两种格式都必须出图。
	board, _ := findRankingBoard("douban-tv-domestic")
	rows := []map[string]any{
		{
			"id": "37123456", "rank_value": 1,
			"title": "嫁金钗",
			"pic": map[string]any{
				"large":  "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2936594583.jpg",
				"normal": "https://img3.doubanio.com/view/photo/s_ratio_poster/public/p2936594583.jpg",
			},
			"rating": map[string]any{"value": 7.9, "count": 20431},
		},
		{
			"id": "37123457", "rank_value": 2,
			"title": "醉梦",
			"pic":   map[string]any{"normal": "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p111.jpg"},
		},
	}
	result, err := parseDoubanRanking(doubanFixture(0, 25, rows), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	firstCover, ok := result.Items[0].Drama.Cover.(string)
	if !ok || firstCover != "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2936594583.jpg" {
		t.Fatalf("pic.large must win: %+v", result.Items[0].Drama.Cover)
	}
	secondCover, ok := result.Items[1].Drama.Cover.(string)
	if !ok || secondCover != "https://img1.doubanio.com/view/photo/s_ratio_poster/public/p111.jpg" {
		t.Fatalf("pic.normal fallback: %+v", result.Items[1].Drama.Cover)
	}
	if result.Items[0].Drama.CoverURL == "" {
		t.Fatal("CoverURL must mirror Cover")
	}
}

func TestDoubanRankingParsesCoverDict(t *testing.T) {
	// 电影合集（movie_showing / movie_latest）的封面是 cover 对象（url +
	// 尺寸元数据），cover_url 为空串、无 pic；第三种形态都必须出图。
	board, _ := findRankingBoard("douban-showing")
	rows := []map[string]any{
		{
			"id": "37123458", "rank_value": 1,
			"title": "生化危机：爆发夜",
			"cover": map[string]any{
				"url":    "https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2936442661.jpg",
				"height": 5500, "width": 4400, "shape": "rectangle",
			},
			"rating": map[string]any{"value": 6.2, "count": 8921},
		},
		{
			// cover 对象缺 url 时回退 pic（若有），全空则无封面不报错。
			"id": "37123459", "rank_value": 2,
			"title": "鲸口脱险",
			"cover": map[string]any{"height": 4199},
			"pic":   map[string]any{"large": "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2935800697.jpg"},
		},
	}
	result, err := parseDoubanRanking(doubanFixture(0, 25, rows), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	firstCover, ok := result.Items[0].Drama.Cover.(string)
	if !ok || firstCover != "https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2936442661.jpg" {
		t.Fatalf("cover.url must be extracted: %+v", result.Items[0].Drama.Cover)
	}
	if result.Items[0].Drama.CoverURL == "" {
		t.Fatal("CoverURL must mirror Cover")
	}
	secondCover, ok := result.Items[1].Drama.Cover.(string)
	if !ok || secondCover != "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2935800697.jpg" {
		t.Fatalf("empty cover.url must fall through to pic: %+v", result.Items[1].Drama.Cover)
	}
}

func TestDoubanRankingParsesCollection(t *testing.T) {
	board, _ := findRankingBoard("douban-weekly")
	result, err := parseDoubanRanking(doubanFixture(0, 25, doubanItems()), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 3 || !result.HasMore {
		t.Fatalf("unexpected page: %+v", result)
	}
	first := result.Items[0]
	if first.Rank != 1 || first.Drama.SourceID != "37068446" || first.Drama.ChannelName != "豆瓣" {
		t.Fatalf("first item lost its identity: %+v", first)
	}
	if first.Drama.Score != "8.5" || first.Metric != "8.5分 · 12.3万人评价 · 2026" {
		t.Fatalf("rating metric must carry the card_subtitle year: %+v", first)
	}
	if cover, ok := first.Drama.Cover.(string); !ok || cover == "" {
		t.Fatalf("cover_url must survive: %+v", first.Drama.Cover)
	}
	if len(first.Drama.Tags) != 2 || first.Drama.CategoryName != "院线热映" {
		t.Fatalf("tags lost: %+v", first.Drama.Tags)
	}
	second := result.Items[1]
	if second.Metric != "7.3分 · 2003" {
		t.Fatalf("rating without count must keep a plain metric plus year: %+v", second.Metric)
	}
	third := result.Items[2]
	if third.Drama.Score != "" || third.Metric != "暂无评分 · 2027" {
		t.Fatalf("unrated items must fall back to an explicit no-rating label: %+v", third)
	}
}

func TestDoubanRankingPagination(t *testing.T) {
	board, _ := findRankingBoard("douban-top250")
	rows := doubanItems()
	rows[0]["rank_value"] = 21
	rows[1]["rank_value"] = 22
	rows[2]["rank_value"] = 23
	second, err := parseDoubanRanking(doubanFixture(20, 25, rows), board, 2)
	if err != nil {
		t.Fatal(err)
	}
	if !second.HasMore || second.Items[0].Rank != 21 {
		t.Fatalf("page 2 must keep upstream rank_value and continue paging: %+v", second)
	}
	if _, err := parseDoubanRanking(doubanFixture(0, 25, doubanItems()), board, 2); err == nil {
		t.Fatal("start must match the requested page")
	}
	last, err := parseDoubanRanking(doubanFixture(20, 22, rows), board, 2)
	if err != nil {
		t.Fatal(err)
	}
	if last.HasMore {
		t.Fatal("start+count == total must have no more pages")
	}
}

func TestDoubanRankingSkipsBadRows(t *testing.T) {
	board, _ := findRankingBoard("douban-realtime")
	rows := doubanItems()
	rows[0]["title"] = ""
	result, err := parseDoubanRanking(doubanFixture(0, 25, rows), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 || result.Items[0].Drama.SourceID != "36179101" {
		t.Fatalf("an empty-title row must be skipped, not fail the page: %+v", result)
	}
	rows = doubanItems()
	rows[1]["id"] = rows[0]["id"]
	result, err = parseDoubanRanking(doubanFixture(0, 25, rows), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 {
		t.Fatalf("a duplicate-id row must be skipped: %+v", result)
	}
	rows = doubanItems()
	rows[1]["rank_value"] = 1
	result, err = parseDoubanRanking(doubanFixture(0, 25, rows), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 {
		t.Fatalf("a non-ascending row must be skipped: %+v", result)
	}
	if _, err := parseDoubanRanking([]byte("not json"), board, 1); err == nil {
		t.Fatal("a non-JSON body must still fail")
	}
	rows = []map[string]any{{"id": "x", "title": ""}}
	if _, err := parseDoubanRanking(doubanFixture(0, 25, rows), board, 1); err == nil {
		t.Fatal("an all-bad page with more pages must fail loudly")
	}
	if page, err := parseDoubanRanking(doubanFixture(0, 1, rows), board, 1); err != nil || len(page.Items) != 0 {
		t.Fatalf("an all-bad final page must come back empty instead of erroring: %+v %+v", page, err)
	}
}

func TestDoubanRankingRegisteredBoards(t *testing.T) {
	expectations := map[string]time.Duration{
		"douban-realtime":      0,
		"douban-weekly":        time.Hour,
		"douban-top250":        12 * time.Hour,
		"douban-showing":       time.Hour,
		"douban-latest":        time.Hour,
		"douban-tv-hot":        0,
		"douban-tv-domestic":   time.Hour,
		"douban-tv-american":   6 * time.Hour,
		"douban-tv-japanese":   6 * time.Hour,
		"douban-tv-korean":     6 * time.Hour,
		"douban-show-domestic": time.Hour,
		"douban-show-foreign":  6 * time.Hour,
	}
	seen := map[string]bool{}
	doubanCount := 0
	for _, board := range rankingBoards {
		if seen[board.ID] {
			t.Fatalf("duplicate board id %s", board.ID)
		}
		seen[board.ID] = true
		if board.Source != sourceDouban {
			// 站源目录榜（provider_rankings_stations_test.go 覆盖）。
			continue
		}
		doubanCount++
		if board.upstreamKey == "" {
			t.Fatalf("douban board %s must bind a collection id", board.ID)
		}
		if board.Name == "" {
			t.Fatalf("board %s lost its display name", board.ID)
		}
		want, ok := expectations[board.ID]
		if !ok {
			t.Fatalf("board %s is not covered by the ttl expectations", board.ID)
		}
		if board.ttl != want {
			t.Fatalf("board %s ttl = %v, want %v", board.ID, board.ttl, want)
		}
	}
	if doubanCount != len(expectations) {
		t.Fatalf("registry has %d douban boards, expectations cover %d", doubanCount, len(expectations))
	}
	if !nativeSourceAvailable(sourceDouban) {
		t.Fatal("douban must stay available in every build variant (ranking-only source)")
	}
}

// doubanRankingServer：按请求的 collection 返回合成豆瓣数据。
func doubanRankingServer(t *testing.T) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(doubanFixture(0, 25, doubanItems()))
	}))
	t.Cleanup(srv.Close)
	return srv
}

// doubanSwapBaseURL：把 rexxar 基址指到测试服务器，返回还原函数。
func doubanSwapBaseURL(t *testing.T, srv *httptest.Server) func() {
	t.Helper()
	backup := doubanRexxarBaseURL
	doubanRexxarBaseURL = srv.URL
	return func() { doubanRexxarBaseURL = backup }
}

func TestDoubanRankingCacheStaleRecoveryAndConcurrency(t *testing.T) {
	board, _ := findRankingBoard("douban-realtime")
	defer doubanSwapBaseURL(t, doubanRankingServer(t))()

	d := &Downloader{cfg: Config{dataDir: t.TempDir()}}
	d.loadRankingCache()
	first, err := d.loadRankingPage(context.Background(), board, 1, false)
	if err != nil || len(first.Items) != 3 {
		t.Fatalf("first fetch failed: %+v %v", first, err)
	}
	again, err := d.loadRankingPage(context.Background(), board, 1, false)
	if err != nil || len(again.Items) != 3 || !again.FetchedAt.Equal(first.FetchedAt) {
		t.Fatalf("TTL 内必须直接命中内存缓存: %+v %v", again, err)
	}
	if again.Stale || again.Warning != "" {
		t.Fatalf("cached page must not be flagged stale: %+v", again)
	}

	// 网络失败回退过期缓存：force 绕过缓存，服务端仍可用旧内存页兜底。
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer srv.Close()
	defer doubanSwapBaseURL(t, srv)()
	stale, err := d.loadRankingPage(context.Background(), board, 1, true)
	if err != nil || !stale.Stale || stale.Warning == "" || len(stale.Items) != 3 {
		t.Fatalf("network failure must fall back to the cached page: %+v %v", stale, err)
	}

	// 并发去重：空缓存下并发拉同页只打一次网络。
	d2 := &Downloader{cfg: Config{dataDir: t.TempDir()}}
	d2.loadRankingCache()
	defer doubanSwapBaseURL(t, doubanRankingServer(t))()
	const workers = 5
	results := make(chan int, workers)
	for i := 0; i < workers; i++ {
		go func() {
			page, err := d2.loadRankingPage(context.Background(), board, 1, false)
			if err != nil {
				results <- -1
				return
			}
			results <- len(page.Items)
		}()
	}
	for i := 0; i < workers; i++ {
		if count := <-results; count != 3 {
			t.Fatalf("concurrent fetch returned %d items", count)
		}
	}
}

func TestDoubanRankingRetriesTransientFailures(t *testing.T) {
	board, _ := findRankingBoard("douban-realtime")
	var calls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch atomic.AddInt32(&calls, 1) {
		case 1:
			w.WriteHeader(http.StatusForbidden)
		default:
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write(doubanFixture(0, 25, doubanItems()))
		}
	}))
	defer srv.Close()
	backup := doubanRexxarBaseURL
	doubanRexxarBaseURL = srv.URL
	t.Cleanup(func() { doubanRexxarBaseURL = backup })

	downloader := &Downloader{}
	page, err := downloader.fetchDoubanRankingPage(context.Background(), board, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(page.Items) != 3 {
		t.Fatalf("retry after 403 must succeed: %+v", page)
	}
	if atomic.LoadInt32(&calls) != 2 {
		t.Fatalf("expected exactly one retry after 403, got %d calls", calls)
	}

	atomic.StoreInt32(&calls, 0)
	srv.Config.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&calls, 1)
		w.WriteHeader(http.StatusBadRequest)
	})
	if _, err := downloader.fetchDoubanRankingPage(context.Background(), board, 1); err == nil {
		t.Fatal("400 must surface as an error")
	}
	if atomic.LoadInt32(&calls) != 1 {
		t.Fatalf("400 must not be retried, got %d calls", calls)
	}
}

func TestNativeNormalizeKeepsUnregisteredRankingSource(t *testing.T) {
	// 豆瓣不注册 provider，条目 ID 反解必失败；显式 Source 必须透传，
	// 否则 Dart 端 _passes 的榜单专用源豁免失效，整榜被站源开关滤空。
	drama := Drama{ID: providerDramaID(sourceDouban, "1292052"), Source: sourceDouban,
		SourceID: "1292052", Title: "肖申克的救赎"}
	normalized := nativeNormalize(drama)
	if normalized.Source != sourceDouban || normalized.SourceID != "1292052" {
		t.Fatalf("douban source lost: %q/%q", normalized.Source, normalized.SourceID)
	}
	// 反解失败且无显式 Source 的 legacy 脏行仍保持空源，不误归站源。
	legacy := nativeNormalize(Drama{ID: "douban:1292052"})
	if legacy.Source != "" {
		t.Fatalf("legacy dirty row must not gain a source: %q", legacy.Source)
	}
}

func TestNativeAuthorizeInputAllowsDoubanCover(t *testing.T) {
	// 「豆瓣榜单没图」根因回归：豆瓣不注册 provider，条目 ID 反解失败，
	// nativeDramaAvailable 此前恒 false → cover/prepareCover 在 build 校验
	// 层被 errNativeBuildSource 拦截，榜单封面永远显示占位图。
	douban := nativeInput{Action: "cover", Drama: nativeDrama{ID: "douban:1292052",
		Source: sourceDouban, SourceID: "1292052",
		Cover: "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2934829882.jpg"}}
	if err := nativeAuthorizeInput(douban); err != nil {
		t.Fatalf("douban cover must pass the build gate: %v", err)
	}
	douban.Action = "prepareCover"
	if err := nativeAuthorizeInput(douban); err != nil {
		t.Fatalf("douban prepareCover must pass the build gate: %v", err)
	}
	if !nativeDramaAvailable(douban.Drama) {
		t.Fatal("douban drama must stay available for entry-level reads")
	}
	// 未注册且不在榜单白名单的源仍被拒绝。
	bogus := nativeInput{Action: "cover", Drama: nativeDrama{ID: "bogus:1", Source: "bogus"}}
	if err := nativeAuthorizeInput(bogus); err != errNativeBuildSource {
		t.Fatalf("unknown source must stay rejected: %v", err)
	}
	// 注册源条目走原逻辑：正常放行，显式 Source 与 ID 不匹配仍拒绝。
	if err := nativeAuthorizeInput(nativeInput{Action: "cover",
		Drama: nativeDrama{ID: "hongguo:100", Source: sourceHongguo}}); err != nil {
		t.Fatalf("registered source cover must keep passing: %v", err)
	}
	if err := nativeAuthorizeInput(nativeInput{Action: "cover",
		Drama: nativeDrama{ID: "hongguo:100", Source: sourceHuangdou}}); err != errNativeBuildSource {
		t.Fatalf("source/id mismatch must stay rejected: %v", err)
	}
}
