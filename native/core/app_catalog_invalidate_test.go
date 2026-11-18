package core

import (
	"testing"
	"time"
)

// TestInvalidateSourceCatalogClearsFreshKeepsOthers 验证模块升级清缓存：
// 指定源的目录条目/游标/分类选项被清，nativeCached 变 Fresh=false；
// 其它源不受影响。
func TestInvalidateSourceCatalogClearsFreshKeepsOthers(t *testing.T) {
	engine := &nativeEngine{
		catalogs:       map[string][]nativeDrama{},
		catalogStates:  map[string]nativeCatalogState{},
		categoryOptions: map[string][]nativeCategory{},
	}
	now := time.Now()
	engine.catalogs["huangguoai"] = []nativeDrama{{ID: "huangguoai:1", Source: "huangguoai", Title: "旧模块数据"}}
	engine.catalogs["huangguoai|ai-duanju"] = []nativeDrama{{ID: "huangguoai:2", Source: "huangguoai", Title: "旧分类"}}
	engine.catalogs["huangguoai|sort:heat"] = []nativeDrama{{ID: "huangguoai:3", Source: "huangguoai", Title: "旧排序"}}
	engine.catalogs["yaguo"] = []nativeDrama{{ID: "yaguo:1", Source: "yaguo", Title: "别的源"}}
	engine.catalogStates["huangguoai"] = nativeCatalogState{UpdatedAt: now, Page: 3}
	engine.catalogStates["yaguo"] = nativeCatalogState{UpdatedAt: now, Page: 2}
	engine.categoryOptions["huangguoai"] = []nativeCategory{{ID: "ai-duanju", Name: "AI短剧"}}
	engine.categoryOptions["yaguo"] = []nativeCategory{{ID: "1", Name: "剧集"}}

	if !engine.nativeCached("huangguoai").Fresh {
		t.Fatal("清理前该源应为 fresh")
	}
	engine.invalidateSourceCatalog("huangguoai")

	got := engine.nativeCached("huangguoai")
	if got.Fresh || len(got.Items) != 0 {
		t.Fatalf("清理后该源应为空且非 fresh：%+v", got)
	}
	if len(engine.catalogs["huangguoai|ai-duanju"]) != 0 ||
		len(engine.catalogs["huangguoai|sort:heat"]) != 0 {
		t.Fatal("分类/排序派生键未清")
	}
	if len(engine.categoryOptions["huangguoai"]) != 0 {
		t.Fatal("分类选项未清")
	}
	if !engine.nativeCached("yaguo").Fresh || len(engine.catalogs["yaguo"]) != 1 ||
		len(engine.categoryOptions["yaguo"]) != 1 {
		t.Fatal("清缓存误伤了其它源")
	}
}
