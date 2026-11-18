package core

import (
	"context"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"duanjuapp/native/provider"
)

// writeReloadTestModule 写一个最小模块目录（纯 ASCII，规避 UTF-16 写回坑）。
func writeReloadTestModule(t *testing.T, root, id, name, manifestExtra, script string) {
	t.Helper()
	dir := filepath.Join(root, id)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	manifest := `{"id":"` + id + `","name":"` + name + `","version":"1.0.0","api":1,"runtime":"js"` + manifestExtra + `}`
	if err := os.WriteFile(filepath.Join(dir, jsModuleManifestFile), []byte(manifest), 0o600); err != nil {
		t.Fatalf("manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, jsModuleEntryFile), []byte(script), 0o600); err != nil {
		t.Fatalf("script: %v", err)
	}
}

const reloadCategoriesScript = `module.exports={categories:function(){return [{id:"",name:"all"}];}};`

func TestReloadJSModuleRefreshesOnlyTarget(t *testing.T) {
	root := t.TempDir()
	writeReloadTestModule(t, root, "alpha", "Alpha One", "", reloadCategoriesScript)
	writeReloadTestModule(t, root, "beta", "Beta One", "", reloadCategoriesScript)
	d := &Downloader{client: http.DefaultClient}
	defer provider.Unregister("alpha")
	defer provider.Unregister("beta")
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("register: %v", err)
	}
	betaBefore, found := provider.Get("beta")
	if !found {
		t.Fatal("beta not registered")
	}
	// 只更新 alpha 的清单名，重载后 alpha 变新、beta 保持原实例。
	writeReloadTestModule(t, root, "alpha", "Alpha Two", "", reloadCategoriesScript)
	if err := reloadJSModule(d, root, "alpha"); err != nil {
		t.Fatalf("reload alpha: %v", err)
	}
	alphaEntry, found := provider.Get("alpha")
	if !found || alphaEntry.Spec().Name != "Alpha Two" {
		t.Fatalf("alpha not refreshed: %+v %v", alphaEntry, found)
	}
	betaAfter, found := provider.Get("beta")
	if !found || betaAfter != betaBefore {
		t.Fatal("beta should remain the same provider instance")
	}
}

func TestModuleCapabilitiesSurviveMediaWrapper(t *testing.T) {
	root := t.TempDir()
	script := `module.exports={
		categories:function(){return [];},
		resolveMedia:function(task){return {url:"https://m.example/test.mp4"};},
		suggestions:function(q){return ["s1","s2"];}
	};`
	writeReloadTestModule(t, root, "wrapped", "Wrapped", "", script)
	d := &Downloader{client: http.DefaultClient}
	defer provider.Unregister("wrapped")
	if err := reloadJSModule(d, root, "wrapped"); err != nil {
		t.Fatalf("reload: %v", err)
	}
	base := moduleCapabilityProvider("wrapped")
	if base == nil {
		t.Fatal("module capability provider should unwrap media provider")
	}
	suggester, ok := base.(moduleSuggester)
	if !ok {
		t.Fatal("media-wrapped module lost suggestions capability")
	}
	names, err := suggester.ModuleSuggestions(context.Background(), nil, "s")
	if err != nil || len(names) != 2 || names[0] != "s1" {
		t.Fatalf("suggestions = %v, %v", names, err)
	}
	asProvider, ok := base.(*jsModuleProvider)
	if !ok || !asProvider.ProvidesCapability("suggestions") {
		t.Fatal("ProvidesCapability should report suggestions")
	}
	if asProvider.ProvidesCapability("danmaku") {
		t.Fatal("ProvidesCapability should not report undeclared/unexported danmaku")
	}
}

func TestUnregisterClearsSuffixHost(t *testing.T) {
	root := t.TempDir()
	writeReloadTestModule(t, root, "suffixmod", "Suffix", `,"hostSuffixes":[".suffix.test"]`, reloadCategoriesScript)
	d := &Downloader{client: http.DefaultClient}
	defer provider.Unregister("suffixmod")
	if err := reloadJSModule(d, root, "suffixmod"); err != nil {
		t.Fatalf("reload: %v", err)
	}
	if got := provider.ForHost("cdn.suffix.test"); got != "suffixmod" {
		t.Fatalf("suffix host not registered: %q", got)
	}
	provider.Unregister("suffixmod")
	if got := provider.ForHost("cdn.suffix.test"); got != "" {
		t.Fatalf("suffix host not cleared after unregister: %q", got)
	}
}
