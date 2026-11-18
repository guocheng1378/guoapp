package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"duanjuapp/native/provider"
)

// maccmswebCards 生成若干网页卡片（对齐花生真网 _hash-vodlist__item 结构）。
func maccmswebCards(rows [][3]string) string {
	var out strings.Builder
	out.WriteString(`<div class="tab-content"><ul class="_9dbe81752a1dbf17-vodlist">`)
	for _, row := range rows {
		// row = {sourceID, title, remark}
		out.WriteString(`<li class="_9dbe81752a1dbf17-vodlist__item"><a class="_9dbe81752a1dbf17-vodlist__thumb" href="/zywview/`)
		out.WriteString(row[0])
		out.WriteString(`.html" title="`)
		out.WriteString(row[1])
		out.WriteString(`" data-original="https://img.example/`)
		out.WriteString(row[0])
		out.WriteString(`.jpg"><span class="pic-text">`)
		out.WriteString(row[2])
		out.WriteString(`</span></a><h4 class="_9dbe81752a1dbf17-vodlist__title"><a href="/zywview/`)
		out.WriteString(row[0])
		out.WriteString(`.html" title="`)
		out.WriteString(row[1])
		out.WriteString(`">`)
		out.WriteString(row[1])
		out.WriteString(`</a></h4></li>`)
	}
	out.WriteString(`</ul></div>`)
	return out.String()
}

// maccmswebDetail 生成详情页（分集容器为 playlink，Go/JS 的 EP_CLASSES 均覆盖）。
func maccmswebDetail(serverURL, sourceID string) string {
	var out strings.Builder
	out.WriteString(`<html><head><title>`)
	out.WriteString("短剧《测试主剧》全集在线观看_站点")
	out.WriteString(`</title><meta name="description" content="测试简介正文"></head><body>`)
	out.WriteString(`<h3 class="module-info-heading">测试主剧</h3>`)
	out.WriteString(`<div class="module-item-pic"><img data-original="https://img.example/`)
	out.WriteString(sourceID)
	out.WriteString(`.jpg"></div>`)
	out.WriteString(`<ul class="playlink clearfix">`)
	out.WriteString(`<li><a title="APP播放" href="/heji.html">APP播放</a></li>`)
	out.WriteString(`<li><a title="第2集" href="/zywplay/`)
	out.WriteString(sourceID)
	out.WriteString(`-2-1.html">第2集</a></li>`)
	out.WriteString(`<li><a title="第1集" href="/zywplay/`)
	out.WriteString(sourceID)
	out.WriteString(`-1-1.html">第1集</a></li>`)
	out.WriteString(`</ul></body></html>`)
	return out.String()
}

// fakeMaccmswebServer 覆盖 4 套 profile 的目录/搜索/详情路径，并记录所有请求 URI。
func fakeMaccmswebServer(t *testing.T) (*httptest.Server, *[]string) {
	t.Helper()
	var mu sync.Mutex
	paths := []string{}
	var serverURL string
	handler := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		paths = append(paths, r.URL.RequestURI())
		mu.Unlock()
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		path := r.URL.Path
		switch {
		case path == "/":
			_, _ = w.Write([]byte(maccmswebCards([][3]string{
				{"20523", "不做替身后被长公主截胡赐婚", "全集"},
				{"27562", "暗潮涌动", "已完结"},
				{"1", "征服短剧", "更新至3集"},
			})))
		case path == "/search.html":
			if r.URL.Query().Get("searchword") != "" {
				_, _ = w.Write([]byte(maccmswebCards([][3]string{{"96476", "战神归来", "全集"}})))
			} else {
				_, _ = w.Write([]byte(maccmswebCards([][3]string{{"20523", "分类剧", "全集"}})))
			}
		case strings.HasPrefix(path, "/zywview/"),
			strings.HasPrefix(path, "/zywdetail/"),
			strings.HasPrefix(path, "/detail/"):
			id := strings.TrimSuffix(strings.TrimPrefix(path, "/"), ".html")
			parts := strings.Split(id, "/")
			sourceID := parts[len(parts)-1]
			_, _ = w.Write([]byte(maccmswebDetail(serverURL, sourceID)))
		case strings.HasPrefix(path, "/zywplay/"):
			// 播放页正文带转义斜杠的 player_aaaa，验证 PlayerURL + NormalizePlaybackURL。
			body := `<html><body><script>var player_aaaa={"url":"` + serverURL + `/real.mp4"};</script></body></html>`
			body = strings.ReplaceAll(body, serverURL+`/real.mp4`, strings.ReplaceAll(serverURL+`/real.mp4`, `/`, `\/`))
			_, _ = w.Write([]byte(body))
		case path == "/show/duanju-----------.html",
			strings.HasPrefix(path, "/xzyxvt/"),
			strings.HasPrefix(path, "/index.php/vod/type/"):
			_, _ = w.Write([]byte(maccmswebCards([][3]string{{"52279", "劫得摄政王心宠", "完结"}})))
		case strings.HasPrefix(path, "/search/") && strings.HasSuffix(path, "----------1---.html"),
			strings.HasPrefix(path, "/xzyxvc/"),
			strings.HasPrefix(path, "/index.php/vod/search/"):
			_, _ = w.Write([]byte(maccmswebCards([][3]string{{"52279", "搜索命中", "全集"}})))
		case strings.HasPrefix(path, "/vod/"),
			strings.HasPrefix(path, "/xzyxvd/"),
			strings.HasPrefix(path, "/index.php/vod/detail/"):
			parts := strings.Split(strings.TrimSuffix(path, ".html"), "/")
			sourceID := parts[len(parts)-1]
			_, _ = w.Write([]byte(maccmswebDetail(serverURL, sourceID)))
		default:
			http.NotFound(w, r)
		}
	})
	server := httptest.NewServer(handler)
	serverURL = server.URL
	t.Cleanup(server.Close)
	return server, &paths
}

// installMaccmswebTestModule 把一个内置 maccmsweb 站点装进临时目录，换成测试基址与测试 id。
func installMaccmswebTestModule(t *testing.T, siteID, id, base string) {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules[siteID]
	if !found || source.code == nil {
		t.Fatalf("未找到内置模块 %s", siteID)
	}
	manifest := source.manifest
	manifest.ID = id
	manifest.Name = "网页采集测试"
	manifest.Base = base
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	// 把 root 通过全局注册函数装进去（ScanJSModules 以目录名为准）。
	d := &Downloader{client: http.DefaultClient}
	if ids, err := RegisterJSModules(d, root); err != nil || len(ids) == 0 {
		t.Fatalf("模块注册失败：%v %v", ids, err)
	}
}

func TestBundledMaccmswebCatalogDetailSearch(t *testing.T) {
	server, _ := fakeMaccmswebServer(t)
	installMaccmswebTestModule(t, "huaguo", "huaguoclique", server.URL)
	defer provider.Unregister("huaguoclique")
	entry, found := provider.Get("huaguoclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 1 || categories[0].ID != "27" || categories[0].Name != "短剧" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "", "")
	if err != nil || len(items) != 3 || !hasMore {
		t.Fatalf("首页目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "huaguoclique:20523" || item.Title != "不做替身后被长公主截胡赐婚" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if item.Cover == nil || !strings.Contains(fmt.Sprintf("%v", item.Cover), "img.example/20523.jpg") {
		t.Fatalf("封面映射错误：%+v", item.Cover)
	}
	if fmt.Sprintf("%v", item.EpisodeCount) != "1" {
		t.Fatalf("集数（全集→1）映射错误：%+v", item.EpisodeCount)
	}

	// 分类页（非首页）：走 search.html 分类分支。
	items, _, err = cataloguer.CatalogPage(ctx, nil, 2, "27", "")
	if err != nil || len(items) != 1 || items[0].Title != "分类剧" {
		t.Fatalf("分类目录 = %v %v", items, err)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "20523")
	if err != nil || drama.Title != "测试主剧" || drama.Intro != "测试简介正文" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集数（应过滤 APP）错误：%+v", chapters)
	}
	if chapters[0].ID != "huaguoclique:20523:1" || chapters[0].Title != "第1集" {
		t.Fatalf("分集排序/ID 错误：%+v", chapters[0])
	}
	if !strings.HasSuffix(chapters[0].PageURL, "/zywplay/20523-1-1.html") {
		t.Fatalf("分集播放页地址错误：%+v", chapters[0])
	}
	if !strings.HasSuffix(chapters[0].Referer, "/") {
		t.Fatalf("分集 Referer 应指向基址：%+v", chapters[0])
	}
	if fmt.Sprintf("%v", drama.EpisodeCount) != "2" {
		t.Fatalf("详情集数错误：%+v", drama.EpisodeCount)
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "战神")
	if err != nil || len(hits) != 1 || hits[0].ID != "huaguoclique:96476" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
}

// 导出了 resolveMedia 的网页型模块应装配成 MediaResolver；播放页正文提取直链。
func TestBundledMaccmswebResolveMedia(t *testing.T) {
	server, _ := fakeMaccmswebServer(t)
	installMaccmswebTestModule(t, "huaguo", "huaguomediaclique", server.URL)
	defer provider.Unregister("huaguomediaclique")
	entry, found := provider.Get("huaguomediaclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	resolver, ok := entry.(provider.MediaResolver)
	if !ok {
		t.Fatal("模块应实现 MediaResolver")
	}
	media, err := resolver.ResolveMedia(t.Context(), nil, provider.Task{
		Chapter: provider.Chapter{
			ID:      "huaguomediaclique:20523:1",
			PageURL: server.URL + "/zywplay/20523-1-1.html",
			Referer: server.URL + "/",
		},
	})
	if err != nil || media.URL != server.URL+"/real.mp4" || media.Referer != server.URL+"/" {
		t.Fatalf("取流 = %+v %v", media, err)
	}
}

// 4 套 profile 的目录/搜索 URL 构造正确性（以请求 URI 取证）。
func TestBundledMaccmswebURLProfiles(t *testing.T) {
	cases := []struct {
		site      string
		id        string
		wantCata  string
		wantQuery string
	}{
		{"huaguo", "huaguoprofile", "/", "/search.html?searchword=%E6%88%98%E7%A5%9E"},
		{"wangguo", "wangguoprofile", "/show/duanju-----------.html", "/search/%E6%88%98%E7%A5%9E----------1---.html"},
		{"faguo", "faguoprofile", "/xzyxvt/1zmn.html", "/xzyxvc/%E6%88%98%E7%A5%9E-wdyswzqun1num.html"},
		{"wuguo", "wuguoprofile", "/", "/index.php/vod/search/page/1/wd/%E6%88%98%E7%A5%9E.html"},
	}
	for _, tc := range cases {
		t.Run(tc.site, func(t *testing.T) {
			server, paths := fakeMaccmswebServer(t)
			installMaccmswebTestModule(t, tc.site, tc.id, server.URL)
			defer provider.Unregister(tc.id)
			entry, found := provider.Get(tc.id)
			if !found {
				t.Fatal("模块未进入注册表")
			}
			cataloguer := entry.(provider.Cataloguer)
			if _, _, err := cataloguer.CatalogPage(t.Context(), nil, 1, "", ""); err != nil {
				t.Fatalf("目录失败：%v", err)
			}
			if _, err := entry.(provider.Searcher).Search(t.Context(), nil, "战神"); err != nil {
				t.Fatalf("搜索失败：%v", err)
			}
			mu := sync.Mutex{}
			_ = mu
			joined := ""
			for _, p := range *paths {
				joined += p + "\n"
			}
			if !strings.Contains(joined, tc.wantCata) {
				t.Fatalf("目录路径 %q 未出现，实际请求：\n%s", tc.wantCata, joined)
			}
			if !strings.Contains(joined, tc.wantQuery) {
				t.Fatalf("搜索路径 %q 未出现，实际请求：\n%s", tc.wantQuery, joined)
			}
		})
	}
}

// 网页型模块以真实 id 安装时应接管内置 Go provider。
func TestBundledMaccmswebTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("huaguo")
	if !had {
		t.Fatal("内置花生源应已注册")
	}
	server, _ := fakeMaccmswebServer(t)
	modules, _ := readBundledJSModules()
	source := modules["huaguo"]
	manifest := source.manifest
	manifest.Base = server.URL
	manifest.Referer = server.URL + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "huaguo", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() { if had { provider.Register(previous) } }()

	entry, found := provider.Get("huaguo")
	if !found {
		t.Fatal("花生源未注册")
	}
	if _, ok := entry.(*jsModuleMediaProvider); !ok {
		t.Fatalf("花生源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(context.Background(), nil, 1, "", "")
	if err != nil || len(items) != 3 || items[0].Title != "不做替身后被长公主截胡赐婚" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}
