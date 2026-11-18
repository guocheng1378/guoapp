package core

import (
	"testing"

	"duanjuapp/native/provider"
)

// 回归：模块只导出 search、没导出 searchWithWarning 时必须回落到普通分页搜索。
//
// searchDuanjuPage 优先走 WarningSearcher（jsModuleProvider 总是实现了该接口），
// 若直接 return 它的 errModuleCapabilityUnsupported，maccms 系模块（影视工厂/
// 360/魔都/电影天堂…）的搜索会被静默判死——真机上表现为「搜索只剩真果·鉴」，
// 以及「点豆瓣榜单只跳转真果鉴」（跨源同名搜索同链路）。
func TestSearchDuanjuFallsBackWhenWarningSearchAbsent(t *testing.T) {
	server := fakeMaccmsServer(t)
	root, _ := installBundledTestModule(t, "maccmstest", server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("maccmstest")

	items, more, warning, err := d.searchDuanjuPage(
		t.Context(), "maccmstest", "命中", 1,
	)
	if err != nil {
		t.Fatalf("搜索失败（未回落普通分页搜索）：%v", err)
	}
	if len(items) != 1 || items[0].Title != "搜索命中" || items[0].Source != "maccmstest" {
		t.Fatalf("搜索结果错误：%+v", items)
	}
	if more || warning != "" {
		t.Fatalf("more=%v warning=%q", more, warning)
	}
}
