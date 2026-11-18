package core

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// 每个内置模块都必须声明站源分类：首页分组、模块管理页的归类与成人源的
// 解锁隐藏全靠它；漏写会让模块被一律当成短剧类（鬼片曾因此进错分组）。
func TestBundledModulesDeclareCategory(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	if len(modules) == 0 {
		t.Fatal("内置模块清单为空")
	}
	valid := map[string]bool{"shortDrama": true, "video": true, "adult": true}
	for id, module := range modules {
		category := strings.TrimSpace(module.manifest.Category)
		if category == "" {
			t.Errorf("内置模块 %s 缺少 category，会被归到短剧类", id)
			continue
		}
		if !valid[category] {
			t.Errorf("内置模块 %s 的分类 %q 不在 shortDrama/video/adult 之内", id, category)
		}
		// adult 在上游语义里是「受限」（黄果系也标 true，分类仍可是短剧/视频），
		// 所以只能单向约束：成人类必须标受限，否则解锁隐藏会漏掉它。
		if category == "adult" && !module.manifest.adult() {
			t.Errorf("内置模块 %s 归成人类却没标 adult，解锁隐藏会漏掉它", id)
		}
	}
}

// fakeMaccmsServer 起一个假的 maccms 采集站接口。
func fakeMaccmsServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mux.HandleFunc("/api.php/provide/vod/", func(w http.ResponseWriter, r *http.Request) {
		query := r.URL.Query()
		w.Header().Set("Content-Type", "application/json")
		switch {
		case query.Get("ac") == "detail":
			_, _ = w.Write([]byte(`{"code":1,"pagecount":1,"total":1,"list":[{
				"vod_id":42,"vod_name":"测试剧","type_id":12,"type_name":"短剧",
				"vod_pic":"https://img.example/cover.jpg",
				"vod_content":"<p>简介&nbsp;正文</p>","vod_remarks":"更新至3集",
				"vod_actor":"演员甲、演员乙","vod_time":"2026-05-06 12:00:00",
				"vod_area":"内地","vod_year":2026,"vod_score":"8.5","vod_duration":"45:12",
				"vod_play_from":"kankun$$$other",
				"vod_play_url":"第1集$https://cdn.example/a.m3u8#第2集$https://cdn.example/b.m3u8$$$第1集$https://site.example/play/1/1.html"
			}]}`))
		case query.Get("wd") != "":
			_, _ = w.Write([]byte(`{"code":1,"page":1,"pagecount":1,"total":1,"list":[{
				"vod_id":99,"vod_name":"搜索命中","type_id":12,"type_name":"短剧","vod_pic":"","vod_content":"","vod_remarks":"","vod_time":""
			}]}`))
		default:
			_, _ = w.Write([]byte(`{"code":1,"page":1,"pagecount":2,"total":2,"list":[{
				"vod_id":42,"vod_name":"测试剧","type_id":12,"type_name":"短剧",
				"vod_pic":"https://img.example/cover.jpg","vod_content":"<p>简介&nbsp;正文</p>",
				"vod_remarks":"更新至3集","vod_actor":"演员甲、演员乙","vod_time":"2026-05-06 12:00:00",
				"vod_area":"内地","vod_year":2026,"vod_score":"8.5","vod_duration":"45:12"
			}]}`))
		}
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server
}

// installBundledTestModule 把内置模块装进临时目录：换成测试基址与测试标识。
func installBundledTestModule(t *testing.T, id, base string) (string, []byte) {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["yingshigongchang"]
	if !found || source.code == nil {
		t.Fatal("未找到内置 maccms 实现")
	}
	manifest := source.manifest
	manifest.ID = id
	manifest.Name = "测试采集站"
	manifest.Base = base
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root, source.code
}

func TestBundledMaccmsModuleServesCatalogDetailSearch(t *testing.T) {
	server := fakeMaccmsServer(t)
	root, _ := installBundledTestModule(t, "maccmstest", server.URL)
	d := &Downloader{client: server.Client()}
	ids, err := RegisterJSModules(d, root)
	if err != nil || len(ids) != 1 || ids[0] != "maccmstest" {
		t.Fatalf("模块注册失败：%v %v", ids, err)
	}
	defer provider.Unregister("maccmstest")
	entry, found := provider.Get("maccmstest")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	ctx := t.Context()
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) < 2 {
		t.Fatalf("分类 = %v %v", categories, err)
	}
	if categories[0].ID != "" || categories[0].Name != "全部" {
		t.Fatalf("首个分类应为全部：%+v", categories[0])
	}
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "12", "")
	if err != nil || len(items) != 1 || !hasMore {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.Source != "maccmstest" || item.SourceID != "42" || item.Title != "测试剧" {
		t.Fatalf("条目基础字段错误：%+v", item)
	}
	if item.Desc != "简介 正文" {
		t.Fatalf("简介未清洗 HTML 实体：%q", item.Desc)
	}
	if item.Score != "8.5" || item.Area != "内地" || item.Year != "2026" {
		t.Fatalf("评分/地区/年份错误：%+v", item)
	}
	if item.OnlineDate != "2026-05-06" {
		t.Fatalf("上线日期错误：%q", item.OnlineDate)
	}
	if item.Duration == nil {
		t.Fatalf("时长缺失：%+v", item)
	}
	if len(item.Actors) != 2 || item.Actors[0] != "演员甲" {
		t.Fatalf("主演解析错误：%+v", item.Actors)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "42")
	if err != nil || drama.Title != "测试剧" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("直链线路应只保留直链集数：%+v", chapters)
	}
	if chapters[0].VideoURL != "https://cdn.example/a.m3u8" || chapters[0].PageURL != "" {
		t.Fatalf("首集地址错误：%+v", chapters[0])
	}
	if chapters[1].Title != "第2集" {
		t.Fatalf("分集标题错误：%+v", chapters[1])
	}
	if !strings.HasSuffix(chapters[0].Referer, "/") {
		t.Fatalf("分集 Referer 应指向基址：%+v", chapters[0])
	}
	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	searchHits, err := searcher.Search(ctx, nil, "测试")
	if err != nil || len(searchHits) != 1 || searchHits[0].Title != "搜索命中" {
		t.Fatalf("搜索 = %v %v", searchHits, err)
	}
}

// 未导出 resolveMedia 的模块不应实现 MediaResolver：走核心通用的播放页解析链路。
func TestBundledModuleWithoutResolveMediaSkipsMediaResolver(t *testing.T) {
	server := fakeMaccmsServer(t)
	root, _ := installBundledTestModule(t, "maccmsnomedia", server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("maccmsnomedia")
	entry, found := provider.Get("maccmsnomedia")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	if _, ok := entry.(provider.MediaResolver); ok {
		t.Fatal("未导出 resolveMedia 的模块不应实现 MediaResolver")
	}
	if _, ok := entry.(provider.PagedSearcher); !ok {
		t.Fatal("模块应实现 PagedSearcher")
	}
}

func TestBundledModulesInstallAndUpgrade(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	if len(modules) == 0 {
		t.Fatal("内置模块为空")
	}
	root := t.TempDir()
	installed, errs := installBundledJSModules(root)
	if len(errs) > 0 {
		t.Fatalf("安装内置模块失败：%v", errs)
	}
	if len(installed) != len(modules) {
		t.Fatalf("安装数量 = %d，应为 %d", len(installed), len(modules))
	}
	// 再装一次：版本相同不重复安装。
	again, _ := installBundledJSModules(root)
	if len(again) != 0 {
		t.Fatalf("同版本不应重复安装：%v", again)
	}
	// 卸载记忆：标记后不再自动装回。
	target := installed[0]
	if err := markBundledJSModuleRemoved(root, target, true); err != nil {
		t.Fatalf("标记卸载失败：%v", err)
	}
	if err := os.RemoveAll(filepath.Join(root, target)); err != nil {
		t.Fatalf("删除模块目录失败：%v", err)
	}
	third, _ := installBundledJSModules(root)
	for _, id := range third {
		if id == target {
			t.Fatalf("已卸载的内置模块不应自动装回：%v", third)
		}
	}
	if err := markBundledJSModuleRemoved(root, target, false); err != nil {
		t.Fatalf("撤销卸载记忆失败：%v", err)
	}
	fourth, _ := installBundledJSModules(root)
	found := false
	for _, id := range fourth {
		if id == target {
			found = true
		}
	}
	if !found {
		t.Fatalf("撤销卸载记忆后应重新安装：%v", fourth)
	}
}

// 内置模块接管内置采集站：同一个 id 由 JS 模块提供（改源不必发版）。
func TestBundledModuleTakesOverBuiltinSource(t *testing.T) {
	previous, had := provider.Get("yingshigongchang")
	if !had {
		t.Fatal("内置采集源应已注册")
	}
	server := fakeMaccmsServer(t)
	root, _ := installBundledTestModule(t, "yingshigongchang", server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer func() {
		// 不用 Unregister：它会连带清掉内置源的别名/域名归属。
		// 直接把内置实现注册回去即可恢复原状。
		if had {
			provider.Register(previous)
		}
	}()
	entry, found := provider.Get("yingshigongchang")
	if !found {
		t.Fatal("内置采集源未注册")
	}
	if _, ok := entry.(*jsModuleProvider); !ok {
		t.Fatalf("内置采集源应由 JS 模块接管，实际类型 %T", entry)
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("JS 模块应实现 Cataloguer")
	}
	items, _, err := cataloguer.CatalogPage(t.Context(), nil, 1, "12", "")
	if err != nil || len(items) != 1 || items[0].Title != "测试剧" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}

func TestNewerModuleVersion(t *testing.T) {
	if !newerModuleVersion("1.0.1", "1.0.0") {
		t.Fatal("1.0.1 应比 1.0.0 新")
	}
	if newerModuleVersion("1.0.0", "1.0.1") {
		t.Fatal("1.0.0 不应比 1.0.1 新")
	}
	if newerModuleVersion("1.0.0", "1.0.0") {
		t.Fatal("同版本不应算更新")
	}
	if newerModuleVersion("1.0", "1.0.0") || newerModuleVersion("x.y.z", "1.0.0") {
		t.Fatal("非法版本号不应算更新")
	}
}

func TestBundledModuleManifestUsesUpstreamFormat(t *testing.T) {
	modules, _ := readBundledJSModules()
	module, found := modules["yingshigongchang"]
	if !found {
		t.Fatal("内置模块 yingshigongchang 缺失")
	}
	if module.manifest.API != jsModuleAPIVersion || module.manifest.Runtime != jsModuleRuntimeJS {
		t.Fatalf("清单字段不符上游：%+v", module.manifest)
	}
	if !module.manifest.RequiresAllSources {
		t.Fatal("内置采集站应受全源变体门控")
	}
	// 落盘后的目录结构：manifest.json + main.js。
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yingshigongchang", module.raw, module.code); err != nil {
		t.Fatalf("写入失败：%v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "yingshigongchang", jsModuleManifestFile)); err != nil {
		t.Fatalf("缺少 %s：%v", jsModuleManifestFile, err)
	}
	if _, err := os.Stat(filepath.Join(root, "yingshigongchang", jsModuleEntryFile)); err != nil {
		t.Fatalf("缺少 %s：%v", jsModuleEntryFile, err)
	}
}

// 上游官方模块以「一模块一目录」内置。清单必须和脚本一样从 embed FS 读：
// 把工作目录切到没有 bundled 目录的空目录后仍要能读到全部模块，
// 否则打包后（磁盘上没有 bundled/<id> 相对路径）这些模块会全部读不到。
func TestUpstreamBundledDirModulesLoadFromEmbed(t *testing.T) {
	ids := []string{
		"beabox", "dsd", "guipian", "hanime1", "hanxiaoquan", "heitao",
		"huangguo-video", "huangguoai", "huangju", "jinguoduanju", "missav",
		"yeguo",
	}
	cwd, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(t.TempDir()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chdir(cwd) })

	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	for _, id := range ids {
		module, found := modules[id]
		if !found {
			t.Errorf("内置模块 %s 缺失", id)
			continue
		}
		if module.manifest.ID != id {
			t.Errorf("内置模块 %s 的清单 id = %s", id, module.manifest.ID)
		}
		if len(module.code) == 0 {
			t.Errorf("内置模块 %s 的脚本为空", id)
		}
	}
}
