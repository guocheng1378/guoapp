package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

// nextDataPage 按真网 <script id="__NEXT_DATA__"> 结构包一页 pageProps。
func nextDataPage(t *testing.T, props map[string]any) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{
		"props": map[string]any{"pageProps": props},
	})
	if err != nil {
		t.Fatal(err)
	}
	return `<html><script id="__NEXT_DATA__" type="application/json">` + string(raw) + `</script></html>`
}

// fakeHeguoServer 按河果真网结构提供首页/分类/详情/分集页/搜索接口。
// 首页数据在 seoColumnVos（无 bookList）；分集页 chapterInfo 故意为空，
// 但正文带 mp4 直链，验证模块回落到正则取流。
func fakeHeguoServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		switch {
		case r.URL.Path == "/":
			_, _ = w.Write([]byte(nextDataPage(t, map[string]any{
				"bannerList": []any{
					map[string]any{"bookId": "41000000001", "bookName": "横幅剧", "coverWap": "https://cdn.example/b.jpg"},
				},
				"seoColumnVos": []any{
					map[string]any{"bookInfos": []any{
						map[string]any{"bookId": "41000504487", "bookName": "接错萌娃嫁对郎", "introduction": "简介", "coverWap": "https://cdn.example/a.jpg", "totalChapterNum": 73, "statusDesc": "已完结"},
					}},
				},
			})))
		case len(r.URL.Path) > 8 && r.URL.Path[:8] == "/browse/":
			_, _ = w.Write([]byte(nextDataPage(t, map[string]any{
				"bookList": []any{
					map[string]any{"bookId": "41000504487", "bookName": "接错萌娃嫁对郎", "coverWap": "https://cdn.example/a.jpg", "totalChapterNum": 73, "statusDesc": "已完结"},
					map[string]any{"bookId": "41000504488", "bookName": "第二部", "coverWap": "https://cdn.example/c.jpg"},
				},
				"pages": 260,
				"page":  1,
			})))
		case len(r.URL.Path) > 7 && r.URL.Path[:7] == "/drama/":
			_, _ = w.Write([]byte(nextDataPage(t, map[string]any{
				"bookInfoVo": map[string]any{
					"bookId": "41000504487", "bookName": "接错萌娃嫁对郎", "introduction": "简介",
					"coverWap": "https://cdn.example/a.jpg", "categoryList": []any{"都市", "治愈"},
				},
				"chapterList": []any{
					map[string]any{"chapterId": "618957660", "chapterName": "第二集", "chapterIndex": 2,
						"chapterVideoVo": map[string]any{"mp4": "https://cdn.example/ep2.mp4"}},
					map[string]any{"chapterId": "618957659", "chapterName": "第一集", "chapterIndex": 1,
						"chapterVideoVo": map[string]any{"mp4": "https://cdn.example/ep1.mp4"}},
				},
			})))
		case len(r.URL.Path) > 9 && r.URL.Path[:9] == "/episode/":
			// chapterInfo 为空，正文里放 mp4 直链（转义斜杠），验证正则兜底。
			body := nextDataPage(t, map[string]any{"chapterInfo": map[string]any{}})
			body += `<script>window.__video="https:\/\/cdn.example\/fallback.mp4";</script>`
			_, _ = w.Write([]byte(body))
		default:
			http.NotFound(w, r)
		}
	})
	mux.HandleFunc("/seo/video/6007", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.Header.Get("pname") != "www.kuaikaw.cn" {
			http.Error(w, "bad search request", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"retCode":0,"data":{"bookList":[
			{"bookId":"41000127751","bookName":"专属回府","coverWap":"https://cdn.example/s.jpg","totalChapterNum":33,"statusDesc":"连载中"}
		]}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func installHeguoTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["heguo"]
	if !found || source.code == nil {
		t.Fatal("未找到内置河果模块")
	}
	manifest := source.manifest
	manifest.ID = "heguoclique"
	manifest.Name = "河果测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "heguoclique", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root
}

func TestBundledHeguoModuleCatalogDetailSearch(t *testing.T) {
	server := fakeHeguoServer(t)
	root := installHeguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("heguoclique")

	entry, found := provider.Get("heguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 10 || categories[0].ID != "462" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	// 首页（category 空）数据在 seoColumnVos，应拿到 2 条（横幅+栏目，去重后不同 id）。
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("首页目录 = %v %v %v", items, hasMore, err)
	}
	// 分类页有 pages=260/page=1，hasMore=true。
	items, hasMore, err = cataloguer.CatalogPage(ctx, nil, 1, "462", "")
	if err != nil || len(items) != 2 || !hasMore {
		t.Fatalf("分类目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "heguoclique:41000504487" || item.Title != "接错萌娃嫁对郎" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if fmt.Sprintf("%v", item.EpisodeCount) != "73" {
		t.Fatalf("集数映射错误：%+v", item.EpisodeCount)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "41000504487")
	if err != nil || drama.Title != "接错萌娃嫁对郎" || drama.Intro != "简介" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集数错误：%+v", chapters)
	}
	// 按 chapterIndex 排序：第一集在前；直链来自 chapterVideoVo。
	if chapters[0].ID != "heguoclique:41000504487:1" || chapters[0].VideoURL != "https://cdn.example/ep1.mp4" {
		t.Fatalf("分集排序/ID/直链错误：%+v", chapters[0])
	}
	if chapters[0].Title != "第一集" {
		t.Fatalf("分集标题错误：%+v", chapters[0].Title)
	}
	if chapters[0].PageURL == "" {
		t.Fatal("分集缺少播放页地址，resolveMedia 兜底会失效")
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "战神")
	if err != nil || len(hits) != 1 || hits[0].ID != "heguoclique:41000127751" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
	if fmt.Sprintf("%v", hits[0].EpisodeCount) != "33" {
		t.Fatalf("搜索结果集数映射错误：%+v", hits[0].EpisodeCount)
	}
}

// 导出了 resolveMedia 的模块应装配成 MediaResolver；取流走分集页正文正则兜底。
func TestBundledHeguoResolveMedia(t *testing.T) {
	server := fakeHeguoServer(t)
	root := installHeguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("heguoclique")
	entry, _ := provider.Get("heguoclique")
	resolver, ok := entry.(provider.MediaResolver)
	if !ok {
		t.Fatal("模块应实现 MediaResolver")
	}

	// 分集自带直链时直接用它，不再抓分集页。
	media, err := resolver.ResolveMedia(t.Context(), nil, provider.Task{
		Chapter: provider.Chapter{
			ID:       "heguoclique:41000504487:1",
			VideoURL: "https://cdn.example/direct.mp4",
			Referer:  server.URL + "/",
		},
	})
	if err != nil || media.URL != "https://cdn.example/direct.mp4" || media.Referer != server.URL+"/" {
		t.Fatalf("自带直链取流 = %+v %v", media, err)
	}

	// 无直链时抓分集页，chapterInfo 为空 → 正则取正文里的 mp4（转义斜杠需还原）。
	media, err = resolver.ResolveMedia(t.Context(), nil, provider.Task{
		Chapter: provider.Chapter{
			ID:      "heguoclique:41000504487:2",
			PageURL: server.URL + "/episode/41000504487/618957660",
			Referer: server.URL + "/",
		},
	})
	if err != nil || media.URL != "https://cdn.example/fallback.mp4" {
		t.Fatalf("正则兜底取流 = %+v %v", media, err)
	}
}

// 河果模块以真实 id 安装时应接管内置 Go provider。
func TestBundledHeguoTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("heguo")
	if !had {
		t.Fatal("内置河果源应已注册")
	}
	server := fakeHeguoServer(t)
	modules, _ := readBundledJSModules()
	source := modules["heguo"]
	manifest := source.manifest
	manifest.Base = server.URL
	manifest.BaseURL = ""
	manifest.Referer = server.URL + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "heguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("heguo")
	if !found {
		t.Fatal("河果源未注册")
	}
	if _, ok := entry.(*jsModuleMediaProvider); !ok {
		t.Fatalf("河果源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(context.Background(), nil, 1, "462", "")
	if err != nil || len(items) != 2 || items[0].Title != "接错萌娃嫁对郎" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}

// 真网冒烟：GUOAPP_HEGUO_LIVE=1 时跑一遍分类/目录/详情/搜索/取流。
func TestHeguoLiveNetworkSmoke(t *testing.T) {
	if os.Getenv("GUOAPP_HEGUO_LIVE") == "" {
		t.Skip("未设置 GUOAPP_HEGUO_LIVE，跳过真网冒烟")
	}
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["heguo"]
	if !found {
		t.Fatal("未找到内置河果模块")
	}
	previous, had := provider.Get("heguo")
	raw, err := json.Marshal(source.manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "heguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: &http.Client{Timeout: 30 * time.Second}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, _ := provider.Get("heguo")
	ctx := context.Background()
	categories, err := entry.(provider.Cataloguer).Categories(ctx, nil)
	if err != nil || len(categories) == 0 {
		t.Fatalf("真网分类 = %d %v", len(categories), err)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(ctx, nil, 1, categories[0].ID, "")
	if err != nil || len(items) == 0 {
		t.Fatalf("真网目录 = %d %v", len(items), err)
	}
	t.Logf("真网目录 %d 条，首条 = %s [%s]", len(items), items[0].Title, items[0].ID)
	drama, chapters, err := entry.(provider.Detailer).Detail(ctx, nil, items[0].SourceID)
	if err != nil || len(chapters) == 0 {
		t.Fatalf("真网详情 = %v %v", drama.Title, err)
	}
	t.Logf("真网详情 %s 共 %d 集，首集 = %s %s", drama.Title, len(chapters), chapters[0].Title, chapters[0].VideoURL)
	hits, err := entry.(provider.Searcher).Search(ctx, nil, "战神")
	if err != nil {
		t.Fatalf("真网搜索失败：%v", err)
	}
	t.Logf("真网搜索「战神」命中 %d 条", len(hits))
	if resolver, ok := entry.(provider.MediaResolver); ok && chapters[0].VideoURL != "" {
		media, err := resolver.ResolveMedia(ctx, nil, provider.Task{Chapter: chapters[0]})
		if err != nil || media.URL == "" {
			t.Fatalf("真网取流失败：%+v %v", media, err)
		}
		t.Logf("真网取流 = %s", media.URL)
	}
}
