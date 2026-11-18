package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"duanjuapp/native/provider"
)

// fakeYaguoServer 按芽果真网结构提供登录 + 分类/目录/详情/搜索接口。
func fakeYaguoServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/user/v1/account/login", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"token":"test-token-123"}}`))
	})
	// 拦截所有其它请求，验证带 authorization 头。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("authorization") != "test-token-123" {
			http.Error(w, "missing token", http.StatusUnauthorized)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/cloud/v2/theater/classes":
			_, _ = w.Write([]byte(`{"data":{"alg_class":[
				{"id":"1","class_name":"全部"},{"id":"2","class_name":"甜宠"},{"id":"9","class_name":"榜单"}
			]}}`))
		case "/cloud/v2/theater/home_page":
			if r.URL.Query().Get("theater_class_id") != "2" {
				http.Error(w, "bad class", http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte(`{"data":{"list":[
				{"theater":{"id":"1001","title":"芽果测试剧","cover_url":"https://img.example/a.jpg","total":50,"current_num":50,"tags":["甜宠","逆袭"],"descrip":"测试简介"}},
				{"theater":{"id":"1002","title":"test","total":10,"current_num":5}}
			],"total":2,"is_end":true}}`))
		case "/v2/theater_parent/detail":
			if r.URL.Query().Get("theater_parent_id") != "1001" {
				http.Error(w, "bad id", http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte(`{"data":{
				"title":"芽果测试剧","descrip":"测试简介","cover_url":"https://img.example/a.jpg",
				"total":50,"current_num":50,"is_over":2,
				"theaters":[
					{"num":2,"son_title":"第2集","son_video_url":"https://cdn.example/ep2.m3u8"},
					{"num":1,"son_title":"第1集","son_video_url":"https://cdn.example/ep1.m3u8"},
					{"num":3,"son_title":"无地址","son_video_url":""}
				]
			}}`))
		case "/v3/search":
			_, _ = w.Write([]byte(`{"data":{"list":[
				{"theater":{"id":"1001","title":"芽果测试剧","total":50,"descrip":"测试简介"}}
			]}}`))
		default:
			http.Error(w, "not found", http.StatusNotFound)
		}
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func installYaguoTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["yaguo"]
	if !found || source.code == nil {
		t.Fatal("未找到内置芽果模块")
	}
	manifest := source.manifest
	manifest.ID = "yaguoclique"
	manifest.Name = "芽果测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yaguoclique", raw, source.code); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestBundledYaguoModuleCatalogDetailSearch(t *testing.T) {
	server := fakeYaguoServer(t)
	root := installYaguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("yaguoclique")

	entry, found := provider.Get("yaguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 3 || categories[0].ID != "1" {
		t.Fatalf("分类 = %v %v", categories, err)
	}
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "2", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	if items[0].ID != "yaguoclique:1001" || items[0].Title != "芽果测试剧" {
		t.Fatalf("条目 ID/标题错误：%+v", items[0])
	}
	if items[0].EpisodeCount == nil || fmt.Sprintf("%v", items[0].EpisodeCount) != "50" {
		t.Fatalf("集数错误：%+v", items[0].EpisodeCount)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "1001")
	if err != nil || drama.Title != "芽果测试剧" || drama.ReleaseStatus != "finished" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 || chapters[0].ID != "yaguoclique:1001:1" || chapters[0].VideoURL != "https://cdn.example/ep1.m3u8" {
		t.Fatalf("分集错误：%+v", chapters)
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "芽果")
	if err != nil || len(hits) != 1 || hits[0].Title != "芽果测试剧" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
}

// 芽果模块以真实 id 安装时应接管内置 Go provider。
func TestBundledYaguoTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("yaguo")
	if !had {
		t.Fatal("内置芽果源应已注册")
	}
	server := fakeYaguoServer(t)
	modules, _ := readBundledJSModules()
	source := modules["yaguo"]
	manifest := source.manifest
	manifest.Base = server.URL
	manifest.BaseURL = ""
	manifest.Referer = server.URL + "/"
	manifest.RequiresAllSources = false
	raw, _ := json.Marshal(manifest)
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yaguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("yaguo")
	if !found {
		t.Fatal("芽果源未注册")
	}
	if _, ok := entry.(*jsModuleProvider); !ok {
		t.Fatalf("芽果源应由 JS 模块接管，实际类型 %T", entry)
	}
}
