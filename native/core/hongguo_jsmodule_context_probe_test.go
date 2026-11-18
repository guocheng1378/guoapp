package core

import (
	"testing"

	"github.com/dop251/goja"
)

// catalogContext 返回 undefined，而 JS catalogPage:1902 直接读
// context.background。本用例验证这是否会让导出崩溃（决定接线前是否
// 必须先补 host 原语）。
func TestHongguoJSCatalogContextShape(t *testing.T) {
	module := &hongguoJSModule{vm: goja.New(), caches: map[string]any{}}
	vm := module.vm
	if err := vm.Set("host", module.hostObject()); err != nil {
		t.Fatal(err)
	}
	// 直接模拟 JS 在 catalogPage 里对 catalogContext 的字段访问。
	for _, expr := range []string{
		"host.catalogContext()",
		"host.catalogContext().background",
		"!host.catalogContext().background ? 1 : 2",
	} {
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Logf("[%s] PANIC: %v", expr, r)
				}
			}()
			ret, err := vm.RunString(expr)
			if err != nil {
				t.Logf("[%s] ERROR: %v", expr, err)
				return
			}
			t.Logf("[%s] OK: %v", expr, ret.Export())
		}()
	}
}
