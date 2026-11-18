package core

import (
	"testing"

	"github.com/dop251/goja"
)

// 探针：验证各 JS 导出在当前 host 原语下能否跑通，不依赖真实网络。
// 用 mock fetch 返回空结构，观察失败是「领域错误」（可接线+兜底）还是
// 「占位原语崩溃」（接线必崩，需先补 host）。
func TestHongguoJSExportsProbe(t *testing.T) {
	module := &hongguoJSModule{vm: goja.New(), caches: map[string]any{}}
	vm := module.vm
	host := module.hostObject()
	host["fetch"] = func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(map[string]any{"status": 200, "body": `{}`, "headers": map[string]any{}})
	}
	host["fetchText"] = func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(map[string]any{"status": 200, "body": `{}`, "headers": map[string]any{}})
	}
	if err := vm.Set("host", host); err != nil {
		t.Fatalf("set host: %v", err)
	}
	wrapped := "(function(){var module={exports:{}};(function(module,exports){\n" +
		hongguoJSModuleSource +
		"\n})(module,module.exports);return module.exports;})()"
	value, err := vm.RunString(wrapped)
	if err != nil {
		t.Fatalf("load module: %v", err)
	}
	exports := value.ToObject(vm)
	module.exports = exports

	cases := []struct {
		name string
		call string
	}{
		{"categories", "exports.categories(false)"},
		{"catalogPage", "exports.catalogPage(1, '')"},
		{"search", "exports.search('测试', 1)"},
		{"detail", "exports.detail('7000000000000000001')"},
		{"suggestions", "exports.suggestions('测试')"},
		{"rankingPage", "exports.rankingPage('hongguo-hot', 1)"},
		{"danmakuIds", "exports.danmakuIds({dramaId:'hongguo:1'})"},
		{"danmaku", "exports.danmaku('1','2',0,30000)"},
		{"coverAddress", "exports.coverAddress({sourceId:'1'},'1')"},
	}
	for _, tc := range cases {
		if err := vm.Set("exports", exports); err != nil {
			t.Fatal(err)
		}
		func() {
			defer func() {
				if r := recover(); r != nil {
					t.Logf("[%s] PANIC (占位原语崩溃): %v", tc.name, r)
				}
			}()
			ret, runErr := vm.RunString("(" + tc.call + ")")
			if runErr != nil {
				t.Logf("[%s] ERROR: %v", tc.name, runErr)
				return
			}
			t.Logf("[%s] OK: %s", tc.name, ret.String())
		}()
	}
}
