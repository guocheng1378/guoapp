package core

import (
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// fakeFanguoServer 按饭果真网结构提供搜索/详情接口。
func fakeFanguoServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/xifan/search/getSearchList", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("keyword") == "" {
			http.Error(w, "missing keyword", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ret":0,"result":{"elements":[{"dataType":"dramaSearchList","contents":[
			{"duanjuVo":{"duanjuId":"1013","source":"jiuzhou","title":"无双战皇","coverImageUrl":"https://img.example/a.jpg","desc":"战皇简介","total":100,"updateStatus":"over","categories":["都市","战神"]}},
			{"duanjuVo":{"duanjuId":"1013","source":"jiuzhou","title":"无双战皇重复","total":100}}
		]}]}}`))
	})
	mux.HandleFunc("/xifan/drama/getDuanjuInfo", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("duanjuId") != "1013" || r.URL.Query().Get("source") != "jiuzhou" {
			http.Error(w, "bad id", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"ret":0,"result":{
			"duanjuId":"1013","source":"jiuzhou","title":"无双战皇","desc":"战皇简介",
			"coverImageUrl":"https://img.example/a.jpg","total":100,"current":100,"updateStatus":"over",
			"categories":["都市","战神"],
			"episodeList":[
				{"index":2,"title":"第2集 试炼","playUrl":"https://cdn.example/ep2.m3u8"},
				{"index":1,"title":"第1集 归来","playUrl":"https://cdn.example/ep1.m3u8"},
				{"index":3,"title":"无地址","playUrl":""}
			]
		}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

// installFanguoTestModule 把 bundled 的饭果模块装入临时目录，基址换成假服务器。
func installFanguoTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["fanguo"]
	if !found || source.code == nil {
		t.Fatal("未找到内置饭果模块")
	}
	manifest := source.manifest
	manifest.ID = "fanguoclique"
	manifest.Name = "饭果测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "fanguoclique", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root
}

// 饭果模块以真实 id 安装时，应接管内置 Go provider（同 id 覆盖）。
func TestBundledFanguoTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("fanguo")
	if !had {
		t.Fatal("内置饭果源应已注册")
	}
	server := fakeFanguoServer(t)
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source := modules["fanguo"]
	manifest := source.manifest
	manifest.Base = server.URL
	manifest.BaseURL = ""
	manifest.Referer = server.URL + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "fanguo", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("fanguo")
	if !found {
		t.Fatal("饭果源未注册")
	}
	if _, ok := entry.(*jsModuleProvider); !ok {
		t.Fatalf("饭果源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), nil, 1, "都市", "")
	if err != nil || len(items) != 1 || items[0].Title != "无双战皇" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}

func TestBundledFanguoModuleCatalogDetailSearch(t *testing.T) {
	server := fakeFanguoServer(t)
	root := installFanguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("fanguoclique")

	entry, found := provider.Get("fanguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	ctx := t.Context()

	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 7 || categories[0].ID != "都市" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "都市", "")
	if err != nil || len(items) != 1 || hasMore {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "fanguoclique:1013#jiuzhou" || item.Title != "无双战皇" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if item.EpisodeCount == nil || fmt.Sprintf("%v", item.EpisodeCount) != "100" {
		t.Fatalf("集数映射错误：%+v", item.EpisodeCount)
	}
	if !strings.Contains(item.Category, "都市") || len(item.Tags) != 2 {
		t.Fatalf("分类/标签映射错误：%+v", item)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "1013#jiuzhou")
	if err != nil || drama.Title != "无双战皇" || drama.ReleaseStatus != "finished" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集应只保留有直链的 2 集：%+v", chapters)
	}
	if chapters[0].ID != "fanguoclique:1013#jiuzhou:1" || chapters[0].VideoURL != "https://cdn.example/ep1.m3u8" {
		t.Fatalf("分集排序/ID/地址错误：%+v", chapters[0])
	}
	if chapters[0].Referer != server.URL+"/" {
		t.Fatalf("分集 Referer 应指向基址：%+v", chapters[0])
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "战皇")
	if err != nil || len(hits) != 1 || hits[0].Title != "无双战皇" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
}
