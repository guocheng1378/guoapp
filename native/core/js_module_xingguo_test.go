package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"duanjuapp/native/provider"
)

// fakeXingguoServer 按星果真网结构提供目录/搜索/详情接口。
func fakeXingguoServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/novel-api/app/pageModel/getResourceById", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("resourceId") != "1287" {
			http.Error(w, "bad resource", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"datalist":[
			{"id":437823882657793,"name":"千金驾到","icon":"https://img.example/a.jpg","chapterCount":80,"heat":272,"introduction":"首富千金"},
			{"id":437823882657794,"name":"test","chapterCount":10,"heat":0,"introduction":""}
		]}}`))
	})
	mux.HandleFunc("/novel-api/basedata/book/searchBook", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("key") == "" {
			http.Error(w, "missing key", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"datalist":[
			{"id":437823882657793,"name":"千金驾到","icon":"https://img.example/a.jpg","chapterCount":80,"heat":272,"introduction":"首富千金"}
		]}}`))
	})
	mux.HandleFunc("/novel-api/basedata/book/getChapterList", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("bookId") != "437823882657793" {
			http.Error(w, "bad book", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":[
			{"chapterName":"第2集","chapterIndex":2,"shortPlayList":[{"chapterShortPlayVoList":[{"shortPlayUrl":"https://cdn.example/ep2.m3u8"}]}]},
			{"chapterName":"第1集","chapterIndex":1,"shortPlayList":[{"chapterShortPlayVoList":[{"shortPlayUrl":"https://cdn.example/ep1.m3u8"}]}]},
			{"chapterName":"无地址","chapterIndex":3,"shortPlayList":[]}
		]}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func installXingguoTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["xingguo"]
	if !found || source.code == nil {
		t.Fatal("未找到内置星果模块")
	}
	manifest := source.manifest
	manifest.ID = "xingguoclique"
	manifest.Name = "星果测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "xingguoclique", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root
}

func TestBundledXingguoModuleCatalogDetailSearch(t *testing.T) {
	server := fakeXingguoServer(t)
	root := installXingguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("xingguoclique")

	entry, found := provider.Get("xingguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	ctx := t.Context()

	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 5 || categories[0].ID != "1287" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "1287", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "xingguoclique:437823882657793@首富千金" || item.Title != "千金驾到" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if item.EpisodeCount == nil || fmt.Sprintf("%v", item.EpisodeCount) != "80" {
		t.Fatalf("集数映射错误：%+v", item.EpisodeCount)
	}
	if item.Heat != "272" || item.Views != "272万播放" {
		t.Fatalf("热度映射错误：%+v", item)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "437823882657793@首富千金")
	if err != nil || drama.Intro != "首富千金" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集应只保留有直链的 2 集：%+v", chapters)
	}
	if chapters[0].ID != "xingguoclique:437823882657793@首富千金:1" || chapters[0].VideoURL != "https://cdn.example/ep1.m3u8" {
		t.Fatalf("分集排序/ID/地址错误：%+v", chapters[0])
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "千金")
	if err != nil || len(hits) != 1 || hits[0].Title != "千金驾到" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
}

// 星果模块以真实 id 安装时应接管内置 Go provider。
func TestBundledXingguoTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("xingguo")
	if !had {
		t.Fatal("内置星果源应已注册")
	}
	server := fakeXingguoServer(t)
	modules, _ := readBundledJSModules()
	source := modules["xingguo"]
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
	if err := writeJSModuleDir(root, "xingguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("xingguo")
	if !found {
		t.Fatal("星果源未注册")
	}
	if _, ok := entry.(*jsModuleProvider); !ok {
		t.Fatalf("星果源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), nil, 1, "1287", "")
	if err != nil || len(items) != 2 || items[0].Title != "千金驾到" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}
