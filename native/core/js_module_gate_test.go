package core

import (
	"encoding/json"
	"testing"

	"duanjuapp/native/provider"
)

// TestModuleDeclaresCapabilityGate 锁定主链路 opt-in 门控的核心安全属性：
//   - 只有 manifest 显式声明的 catalog/detail 能力才返回 true（模块接管）；
//   - 未声明的能力、未注册的源、Go 内置 provider 都返回 false（走 Go 直连兜底）。
//
// 这保证从上游抄来的、只写了 search/rankings 的模块不会误伤 catalog/detail。
func TestModuleDeclaresCapabilityGate(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	module, found := modules["huangguoai"]
	if !found {
		t.Fatal("未找到内置 huangguoai 模块")
	}

	previous, had := provider.Get("huangguoai")
	raw, err := json.Marshal(module.manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "huangguoai", raw, module.code); err != nil {
		t.Fatal(err)
	}
	if _, err := RegisterJSModules(&Downloader{}, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()

	// huangguoai manifest 已声明 catalog/detail/search/media/rankings。
	for _, capability := range []string{"catalog", "detail", "search", "media", "rankings"} {
		if !moduleDeclaresCapability("huangguoai", capability) {
			t.Errorf("huangguoai 应声明 %s", capability)
		}
	}
	// 未声明的能力（如 cover/danmaku）必须为 false——主能力门控只认显式声明。
	if moduleDeclaresCapability("huangguoai", "cover") {
		t.Error("huangguoai 未声明 cover，门控不应为 true")
	}
	// 未注册的源必须为 false。
	if moduleDeclaresCapability("__nonexistent_source__", "catalog") {
		t.Error("未注册源的门控应为 false")
	}
}
