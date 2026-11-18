package core

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// TestDongpiandiModuleLoads 验证真果·鉴 JS 模块能被本地 goja 加载：清单合法、
// 导出齐全、依赖的 host 原语都在。
func TestDongpiandiModuleLoads(t *testing.T) {
	restore := withBundledFS(os.DirFS("bundled"))
	defer restore()

	module, err := bundledDirModule("dongpiandi")
	if err != nil {
		t.Fatalf("读取真果鉴模块失败: %v", err)
	}
	manifest := module.manifest
	if manifest.ID != "dongpiandi" {
		t.Fatalf("模块 id = %s", manifest.ID)
	}
	if manifest.API != jsModuleAPIVersion {
		t.Fatalf("api = %d", manifest.API)
	}
	if !manifest.RequiresAllSources {
		t.Fatal("真果鉴须声明 requiresAllSources")
	}
	if manifest.Category != "video" {
		t.Fatalf("category = %s, want video", manifest.Category)
	}
	for _, capability := range []string{"catalog", "detail", "search", "media", "suggestions"} {
		found := false
		for _, declared := range manifest.Capabilities {
			if strings.EqualFold(declared, capability) {
				found = true
				break
			}
		}
		if !found {
			t.Errorf("manifest 缺少能力 %s", capability)
		}
	}

	runtime, err := newJSModuleRuntime(&Downloader{client: &http.Client{}}, manifest, string(module.code))
	if err != nil {
		t.Fatalf("goja 加载真果鉴模块失败: %v", err)
	}
	for _, function := range []string{"categories", "catalogPage", "detail", "search", "suggestions", "resolveMedia"} {
		if !runtime.hasExport(function) {
			t.Errorf("模块缺少导出 %s", function)
		}
	}
}

// TestDongpiandiModuleTakesOver 验证以 dongpiandi id 注册的模块覆盖内置 spec，
// 声明四主能力并打开主链路门控。
func TestDongpiandiModuleTakesOver(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["dongpiandi"]
	if !found || source.code == nil {
		t.Fatal("未找到内置真果鉴模块")
	}
	previous, had := provider.Get("dongpiandi")
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()

	root := t.TempDir()
	raw, err := json.Marshal(source.manifest)
	if err != nil {
		t.Fatal(err)
	}
	if err := writeJSModuleDir(root, "dongpiandi", raw, source.code); err != nil {
		t.Fatal(err)
	}
	if _, err := RegisterJSModules(&Downloader{}, root); err != nil {
		t.Fatal(err)
	}
	entry, ok := provider.Get("dongpiandi")
	if !ok {
		t.Fatal("模块注册后 dongpiandi 不在 provider 注册表")
	}
	if entry.Spec().Family != provider.FamilyDuanju {
		t.Fatalf("Family = %s", entry.Spec().Family)
	}
	for _, capability := range []string{"catalog", "detail", "search", "media"} {
		if !moduleDeclaresCapability("dongpiandi", capability) {
			t.Errorf("dongpiandi 未声明 %s", capability)
		}
	}
}
