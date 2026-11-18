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

// fakeMaoguoServer 按猫果真网结构提供目录/详情/搜索接口。
// tag/list 故意返回 404，验证模块回落到 index 的 tag_items 取分类。
func fakeMaoguoServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/api/v1/playlet/tag/list", func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "404 page not found", http.StatusNotFound)
	})
	mux.HandleFunc("/api/v1/playlet/index", func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("sign") == "" || len(r.Header.Get("sign")) != 32 {
			http.Error(w, "missing sign", http.StatusForbidden)
			return
		}
		if r.Header.Get("qm-params") == "" || r.Header.Get("X-Requested-With") != "com.duoduo.read" {
			http.Error(w, "missing qm headers", http.StatusForbidden)
			return
		}
		if tag := r.URL.Query().Get("tag_id"); tag != "571" && tag != "0" {
			http.Error(w, "bad tag", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{
			"tag_items":[
				{"tag_id":"0","tag_name":"推荐"},
				{"tag_id":"-1","tag_name":"新剧"},
				{"tag_id":"571","tag_name":"都市"}
			],
			"list":[
				{"playlet_id":"21277","image_link":"https://cdn.example/a.jpg","title":"抚远不远","intro":"简介","tags":"都市,治愈","total_episode_num":"33","is_over":"1"},
				{"playlet_id":"21278","title":"test","total_episode_num":"10","is_over":"0"}
			],
			"next_id":"2"
		}}`))
	})
	mux.HandleFunc("/player/api/v1/playlet/info", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("playlet_id") != "21277" {
			http.Error(w, "bad playlet", http.StatusBadRequest)
			return
		}
		if len(r.Header.Get("sign")) != 32 {
			http.Error(w, "missing sign", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{
			"playlet_id":"21277","image_link":"https://cdn.example/a.jpg","title":"抚远不远",
			"intro":"简介","tags":"都市,治愈","total_episode_num":"33","is_over":"1",
			"play_list":[
				{"video_url":"https://cdn.example/ep2.m3u8","sort":"2"},
				{"video_url":"https://cdn.example/ep1.m3u8","sort":"1"},
				{"video_url":""}
			]
		}}`))
	})
	mux.HandleFunc("/api/v1/playlet/search", func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Query().Get("wd") == "" {
			http.Error(w, "missing wd", http.StatusBadRequest)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"data":{"is_list_have_results":"1","list":[
			{"id":"26920","image_link":"https://cdn.example/s.jpg","title":"抚远不远","total_num":"33"}
		]}}`))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

func installMaoguoTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["maoguo"]
	if !found || source.code == nil {
		t.Fatal("未找到内置猫果模块")
	}
	manifest := source.manifest
	manifest.ID = "maoguoclique"
	manifest.Name = "猫果测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "maoguoclique", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root
}

func TestBundledMaoguoModuleCatalogDetailSearch(t *testing.T) {
	server := fakeMaoguoServer(t)
	root := installMaoguoTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("maoguoclique")

	entry, found := provider.Get("maoguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	// tag/list 已 404，分类应回落到 index 的 tag_items。
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 3 || categories[0].ID != "0" || categories[1].ID != "-1" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "571", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "maoguoclique:21277" || item.Title != "抚远不远" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if item.EpisodeCount == nil || fmt.Sprintf("%v", item.EpisodeCount) != "33" {
		t.Fatalf("集数映射错误：%+v", item.EpisodeCount)
	}
	if item.Category != "都市, 治愈" || len(item.Tags) != 2 {
		t.Fatalf("标签映射错误：%+v", item)
	}
	if item.ReleaseStatus != "finished" {
		t.Fatalf("更新状态映射错误：%+v", item.ReleaseStatus)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "21277")
	if err != nil || drama.Title != "抚远不远" || drama.Intro != "简介" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集应只保留有直链的 2 集：%+v", chapters)
	}
	if chapters[0].ID != "maoguoclique:21277:1" || chapters[0].VideoURL != "https://cdn.example/ep1.m3u8" {
		t.Fatalf("分集排序/ID/地址错误：%+v", chapters[0])
	}
	if chapters[0].Title != "第1集" {
		t.Fatalf("缺省分集标题错误：%+v", chapters[0].Title)
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "抚远")
	if err != nil || len(hits) != 1 || hits[0].ID != "maoguoclique:26920" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
	if hits[0].EpisodeCount == nil || fmt.Sprintf("%v", hits[0].EpisodeCount) != "33" {
		t.Fatalf("搜索结果集数映射错误：%+v", hits[0].EpisodeCount)
	}
}

// 猫果模块以真实 id 安装时应接管内置 Go provider。
func TestBundledMaoguoTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("maoguo")
	if !had {
		t.Fatal("内置猫果源应已注册")
	}
	server := fakeMaoguoServer(t)
	modules, _ := readBundledJSModules()
	source := modules["maoguo"]
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
	if err := writeJSModuleDir(root, "maoguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("maoguo")
	if !found {
		t.Fatal("猫果源未注册")
	}
	if _, ok := entry.(*jsModuleProvider); !ok {
		t.Fatalf("猫果源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), nil, 1, "571", "")
	if err != nil || len(items) != 2 || items[0].Title != "抚远不远" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}

// 真网冒烟：GUOAPP_MAOGUO_LIVE=1 时用真实猫果站点跑一遍分类/目录/详情/搜索。
// 默认跳过，避免常规测试依赖外网。
func TestMaoguoLiveNetworkSmoke(t *testing.T) {
	if os.Getenv("GUOAPP_MAOGUO_LIVE") == "" {
		t.Skip("未设置 GUOAPP_MAOGUO_LIVE，跳过真网冒烟")
	}
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["maoguo"]
	if !found {
		t.Fatal("未找到内置猫果模块")
	}
	previous, had := provider.Get("maoguo")
	raw, err := json.Marshal(source.manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "maoguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: &http.Client{Timeout: 30 * time.Second}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("maoguo")
	if !found {
		t.Fatal("猫果源未注册")
	}
	ctx := context.Background()
	cataloguer := entry.(provider.Cataloguer)

	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) < 5 {
		t.Fatalf("真网分类 = %d %v", len(categories), err)
	}
	t.Logf("真网分类 %d 个，首个 = %s/%s", len(categories), categories[0].ID, categories[0].Name)

	items, _, err := cataloguer.CatalogPage(ctx, nil, 1, categories[0].ID, "")
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
}