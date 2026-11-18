package core

import (
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// TestHuangdouModuleLoads 验证黄豆短剧 H5 模块（1.1.0 双传版）能被本地
// goja 运行时加载：清单合法、导出齐全、依赖的 host 原语都在。
func TestHuangdouModuleLoads(t *testing.T) {
	restore := withBundledFS(os.DirFS("bundled"))
	defer restore()

	module, err := bundledDirModule("huangdou")
	if err != nil {
		t.Fatalf("读取黄豆模块失败: %v", err)
	}
	manifest := module.manifest
	if manifest.ID != "huangdou" {
		t.Fatalf("模块 id = %s", manifest.ID)
	}
	if !manifest.RequiresAllSources {
		t.Fatal("黄豆须声明 requiresAllSources，保持只在全源变体可见")
	}
	if manifest.Version != "1.1.0" {
		t.Fatalf("模块版本 = %s", manifest.Version)
	}
	if manifest.API != jsModuleAPIVersion {
		t.Fatalf("api = %d, want %d", manifest.API, jsModuleAPIVersion)
	}
	if manifest.Category != "shortDrama" || !manifest.adult() {
		t.Fatalf("分类/受限标记异常: category=%s adult=%v", manifest.Category, manifest.adult())
	}
	for _, capability := range []string{"catalog", "detail", "search", "media"} {
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
		t.Fatalf("goja 加载黄豆模块失败: %v", err)
	}
	for _, function := range []string{"categories", "catalogPage", "detail", "search", "resolveMedia"} {
		if !runtime.hasExport(function) {
			t.Errorf("模块缺少导出 %s", function)
		}
	}
}

// TestHuangdouModuleTakesOver 验证以 huangdou id 注册的模块会覆盖内置 spec，
// 把 Family 改写成 FamilyDuanju 并声明四项主能力——这是 catalog/detail/search/media
// 门控放行、由模块真正接管黄豆的前提。
func TestHuangdouModuleTakesOver(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["huangdou"]
	if !found || source.code == nil {
		t.Fatal("未找到内置黄豆模块")
	}
	previous, had := provider.Get("huangdou")
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
	if err := writeJSModuleDir(root, "huangdou", raw, source.code); err != nil {
		t.Fatal(err)
	}
	if _, err := RegisterJSModules(&Downloader{}, root); err != nil {
		t.Fatal(err)
	}
	entry, ok := provider.Get("huangdou")
	if !ok {
		t.Fatal("模块注册后 huangdou 不在 provider 注册表")
	}
	if entry.Spec().Family != provider.FamilyDuanju {
		t.Fatalf("黄豆模块 Family = %s，需为 %s 才会打开主能力门控", entry.Spec().Family, provider.FamilyDuanju)
	}
	for _, capability := range []string{"catalog", "detail", "search", "media"} {
		if !moduleDeclaresCapability("huangdou", capability) {
			t.Errorf("huangdou 未声明 %s，门控不会放行", capability)
		}
	}
	// 分类校验：模块接管的 f|... 合法，注入串仍被拒。
	if !validNativeCategory("huangdou", "f|12|new|hot") {
		t.Error("模块分类 f|12|new|hot 应放行")
	}
	if validNativeCategory("huangdou", "../other|source") {
		t.Error("注入分类不应放行")
	}
}
