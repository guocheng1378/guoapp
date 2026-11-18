package core

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// fakeModuleStoreServer 起一个假的模块仓库：索引 + 模块文件。
func fakeModuleStoreServer(t *testing.T, moduleID string) (*httptest.Server, map[string]string) {
	t.Helper()
	manifest := `{"id":"` + moduleID + `","name":"在线测试模块","version":"1.0.0","api":1,"runtime":"js","adult":false,"base":"https://site.example"}`
	code := `module.exports = { categories: function () { return [{ id: "", name: "全部" }]; } };`
	sums := map[string]string{}
	for name, content := range map[string]string{jsModuleManifestFile: manifest, jsModuleEntryFile: code} {
		sum := sha256.Sum256([]byte(content))
		sums[name] = hex.EncodeToString(sum[:])
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/index.json", func(w http.ResponseWriter, r *http.Request) {
		index := map[string]any{
			"format": jsModuleIndexFormat,
			"modules": []map[string]any{{
				"id": moduleID, "name": "在线测试模块", "version": "1.0.0",
				"description": "在线仓库测试", "api": jsModuleAPIVersion,
				"repo": "owner/repo", "tag": "v1.0.0", "sha256": sums,
			}},
		}
		_ = json.NewEncoder(w).Encode(index)
	})
	mux.HandleFunc("/owner/repo/v1.0.0/"+jsModuleManifestFile, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(manifest))
	})
	mux.HandleFunc("/owner/repo/v1.0.0/"+jsModuleEntryFile, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(code))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server, sums
}

func TestParseModuleIndexFiltersUnusableEntries(t *testing.T) {
	good := map[string]string{
		jsModuleManifestFile: strings.Repeat("a", 64),
		jsModuleEntryFile:    strings.Repeat("b", 64),
	}
	raw := `{"format":1,"modules":[
		{"id":"good","name":"好模块","api":1,"repo":"owner/repo","tag":"v1.0.0","sha256":` + mustJSON(good) + `},
		{"id":"future","name":"未来接口","api":2,"repo":"owner/repo","tag":"v1.0.0","sha256":` + mustJSON(good) + `},
		{"id":"Bad-ID","name":"非法标识","api":1,"repo":"owner/repo","tag":"v1.0.0","sha256":` + mustJSON(good) + `},
		{"id":"badrepo","name":"非法仓库","api":1,"repo":"../evil","tag":"v1.0.0","sha256":` + mustJSON(good) + `},
		{"id":"badtag","name":"非法标签","api":1,"repo":"owner/repo","tag":"latest","sha256":` + mustJSON(good) + `},
		{"id":"badhash","name":"非法校验和","api":1,"repo":"owner/repo","tag":"v1.0.0","sha256":{"` + jsModuleManifestFile + `":"zz","` + jsModuleEntryFile + `":"zz"}},
		{"id":"noname","api":1,"repo":"owner/repo","tag":"v1.0.0","sha256":` + mustJSON(good) + `}
	]}`
	entries, err := parseModuleIndex([]byte(raw))
	if err != nil {
		t.Fatalf("索引解析失败：%v", err)
	}
	if len(entries) != 1 || entries[0].ID != "good" {
		t.Fatalf("应只保留可用条目：%+v", entries)
	}
	if _, err := parseModuleIndex([]byte(`{"format":2,"modules":[]}`)); err == nil {
		t.Fatal("索引格式版本不匹配时应报错")
	}
}

func mustJSON(value map[string]string) string {
	raw, _ := json.Marshal(value)
	return string(raw)
}

func TestJSModuleStoreAndOnlineInstall(t *testing.T) {
	server, _ := fakeModuleStoreServer(t, "jsmoduletest")
	originalIndex := jsModuleIndexAddresses
	originalFiles := jsModuleFileAddresses
	defer func() {
		jsModuleIndexAddresses = originalIndex
		jsModuleFileAddresses = originalFiles
	}()
	jsModuleIndexAddresses = []string{server.URL + "/index.json"}
	jsModuleFileAddresses = []string{server.URL + "/%s/%s/%s"}

	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{client: server.Client()}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	store, err := engine.jsModuleStore(context.Background())
	if err != nil {
		t.Fatalf("模块商店读取失败：%v", err)
	}
	items, _ := store["items"].([]moduleIndexEntry)
	ids := map[string]bool{}
	for _, item := range items {
		ids[item.ID] = true
	}
	if !ids["jsmoduletest"] {
		t.Fatalf("商店应包含在线模块：%+v", items)
	}
	if !ids["yingshigongchang"] {
		t.Fatalf("商店应包含内置模块：%+v", items)
	}

	result, err := engine.nativeJSModuleInstallOnline(context.Background(), "jsmoduletest")
	if err != nil {
		t.Fatalf("在线安装失败：%v", err)
	}
	payload, _ := result.(map[string]any)
	if payload["id"] != "jsmoduletest" {
		t.Fatalf("安装结果异常：%+v", payload)
	}
	defer provider.Unregister("jsmoduletest")
	if _, err := os.Stat(filepath.Join(jsModuleRootPath, "jsmoduletest", jsModuleManifestFile)); err != nil {
		t.Fatalf("模块未落盘：%v", err)
	}
	entry, found := provider.Get("jsmoduletest")
	if !found {
		t.Fatal("在线模块未注册")
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("在线模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(context.Background(), nil)
	if err != nil || len(categories) != 1 || categories[0].Name != "全部" {
		t.Fatalf("在线模块分类 = %v %v", categories, err)
	}
}

func TestJSModuleOnlineInstallRejectsBadChecksum(t *testing.T) {
	server, _ := fakeModuleStoreServer(t, "jsmodulebad")
	originalIndex := jsModuleIndexAddresses
	originalFiles := jsModuleFileAddresses
	defer func() {
		jsModuleIndexAddresses = originalIndex
		jsModuleFileAddresses = originalFiles
	}()
	jsModuleIndexAddresses = []string{server.URL + "/index.json"}
	jsModuleFileAddresses = []string{server.URL + "/%s/%s/%s"}
	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{client: server.Client()}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	// 篡改索引里的校验和：下载内容与校验和不符，必须拒绝安装。
	original := jsModuleIndexAddresses[0]
	_ = original
	entries, _, err := engine.jsModuleIndex(context.Background())
	if err != nil || len(entries) != 1 {
		t.Fatalf("索引读取异常：%v %v", entries, err)
	}
	entries[0].SHA256[jsModuleManifestFile] = strings.Repeat("0", 64)
	if _, err := engine.fetchIndexedJSFile(context.Background(), entries[0], 0, jsModuleManifestFile, jsModuleManifestBytes); err == nil {
		t.Fatal("校验和不符时必须报错")
	}
}

// 从地址安装：第三方模块给个 zip 直链就能装，不必上架索引。
func TestJSModuleInstallFromAddress(t *testing.T) {
	manifest := `{"id":"addrinstall","name":"地址安装测试","version":"1.0.0","api":1,"runtime":"js"}`
	code := `module.exports = { categories: function () { return [{ id: "", name: "全部" }]; } };`
	pack, err := zipJSModuleFiles([]byte(manifest), []byte(code))
	if err != nil {
		t.Fatalf("组包失败：%v", err)
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write(pack)
	}))
	defer server.Close()

	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{client: server.Client()}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	result, err := engine.nativeJSModuleInstallAddress(context.Background(), server.URL+"/module.zip")
	if err != nil {
		t.Fatalf("地址安装失败：%v", err)
	}
	payload, _ := result.(map[string]any)
	if payload["id"] != "addrinstall" {
		t.Fatalf("安装结果异常：%+v", payload)
	}
	defer provider.Unregister("addrinstall")
	entry, found := provider.Get("addrinstall")
	if !found {
		t.Fatal("地址安装的模块未注册")
	}
	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(context.Background(), nil)
	if err != nil || len(categories) != 1 || categories[0].Name != "全部" {
		t.Fatalf("分类 = %v %v", categories, err)
	}
}

func TestJSModuleInstallFromAddressRejectsBadURL(t *testing.T) {
	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	for _, address := range []string{"", "ftp://example.test/module.zip", "not-a-url"} {
		if _, err := engine.nativeJSModuleInstallAddress(context.Background(), address); err == nil {
			t.Fatalf("地址 %q 应被拒绝", address)
		}
	}
}

// 更新覆盖：同一个 id 重新安装后注册表指向新实现，无需重启应用。
func TestJSModuleReinstallTakesEffectWithoutRestart(t *testing.T) {
	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{client: http.DefaultClient}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	defer provider.Unregister("hotupdate")

	write := func(name string) {
		manifest := `{"id":"hotupdate","name":"热更新测试","version":"` + name + `","api":1,"runtime":"js"}`
		code := `module.exports = { categories: function () { return [{ id: "", name: "` + name + `" }]; } };`
		if err := writeJSModuleDir(root, "hotupdate", []byte(manifest), []byte(code)); err != nil {
			t.Fatalf("写入模块失败：%v", err)
		}
		if _, err := RegisterJSModules(engine.downloader, root); err != nil {
			t.Fatalf("注册失败：%v", err)
		}
	}
	categoryName := func() string {
		entry, found := provider.Get("hotupdate")
		if !found {
			return ""
		}
		cataloguer, ok := entry.(provider.Cataloguer)
		if !ok {
			return ""
		}
		categories, err := cataloguer.Categories(context.Background(), nil)
		if err != nil || len(categories) == 0 {
			return ""
		}
		return categories[0].Name
	}
	write("v1")
	if got := categoryName(); got != "v1" {
		t.Fatalf("首装后分类 = %q", got)
	}
	write("v2")
	if got := categoryName(); got != "v2" {
		t.Fatalf("更新后应立刻生效，实际 = %q", got)
	}
}

func TestJSModuleUninstallRemovesModule(t *testing.T) {
	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	if err := os.MkdirAll(filepath.Join(jsModuleRootPath, "jsmoduletest"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if _, err := engine.nativeJSModuleUninstall("jsmoduletest"); err != nil {
		t.Fatalf("卸载失败：%v", err)
	}
	if _, err := os.Stat(filepath.Join(jsModuleRootPath, "jsmoduletest")); !os.IsNotExist(err) {
		t.Fatal("卸载后目录应删除")
	}
	if _, err := engine.nativeJSModuleUninstall("../evil"); err == nil {
		t.Fatal("非法标识应被拒绝")
	}
}

// fakeSelfHostedModuleServer 模拟自建源：索引在 /modules/index.json，模块文件
// 按 /modules/{tag}/{文件名} 直取（无 gh/repo@tag 结构）。
func fakeSelfHostedModuleServer(t *testing.T, moduleID string) (*httptest.Server, map[string]string) {
	t.Helper()
	manifest := `{"id":"` + moduleID + `","name":"自建源模块","version":"1.0.0","api":1,"runtime":"js","base":"https://site.example"}`
	code := `module.exports = { categories: function () { return [{ id: "", name: "全部" }]; } };`
	sums := map[string]string{}
	for name, content := range map[string]string{jsModuleManifestFile: manifest, jsModuleEntryFile: code} {
		sum := sha256.Sum256([]byte(content))
		sums[name] = hex.EncodeToString(sum[:])
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/modules/index.json", func(w http.ResponseWriter, r *http.Request) {
		index := map[string]any{
			"format": jsModuleIndexFormat,
			"modules": []map[string]any{{
				"id": moduleID, "name": "自建源模块", "version": "1.0.0",
				"description": "自建源测试", "api": jsModuleAPIVersion,
				"repo": "owner/repo", "tag": "v1.0.0", "sha256": sums,
			}},
		}
		_ = json.NewEncoder(w).Encode(index)
	})
	mux.HandleFunc("/modules/v1.0.0/"+jsModuleManifestFile, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(manifest))
	})
	mux.HandleFunc("/modules/v1.0.0/"+jsModuleEntryFile, func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(code))
	})
	server := httptest.NewServer(mux)
	t.Cleanup(server.Close)
	return server, sums
}

// TestSelfHostedModuleChainAndFallback 验证自建源直取链路、sha256 校验不变，
// 以及自建源失败后自动落到下一源（索引与模块文件都取命中镜像）。
func TestSelfHostedModuleChainAndFallback(t *testing.T) {
	server, _ := fakeSelfHostedModuleServer(t, "selfhostedmod")
	// 关不掉的地址（连接立即拒绝）排在自建源前面，模拟 jsDelivr 被屏蔽/自建源优先。
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	dead.Close()
	originalIndex := jsModuleIndexAddresses
	originalFiles := jsModuleFileAddresses
	originalIndexOverride, originalFileOverride := jsModuleSourceOverrides()
	defer func() {
		jsModuleIndexAddresses = originalIndex
		jsModuleFileAddresses = originalFiles
		setJSModuleSourceURL("")
		jsModuleSourceMu.Lock()
		jsModuleIndexOverride, jsModuleFileOverride = originalIndexOverride, originalFileOverride
		jsModuleSourceMu.Unlock()
	}()
	jsModuleIndexAddresses = []string{
		dead.URL + "/modules/index.json",
		server.URL + "/modules/index.json",
	}
	jsModuleFileAddresses = []string{
		dead.URL + "/modules/%[2]s/%[3]s",
		server.URL + "/modules/%[2]s/%[3]s",
	}

	root := t.TempDir()
	engine := &nativeEngine{downloader: &Downloader{client: server.Client()}, directory: root}
	jsModuleRootPath = filepath.Join(root, "modules")
	entries, mirror, err := engine.jsModuleIndex(context.Background())
	if err != nil || len(entries) != 1 {
		t.Fatalf("索引读取失败（应落到第二源）：%v %v", entries, err)
	}
	if mirror != 1 {
		t.Fatalf("应命中第二源，实际 mirror=%d", mirror)
	}
	// 模块文件按命中源的模板取，sha256 校验逻辑不变。
	manifest, err := engine.fetchIndexedJSFile(context.Background(), entries[0], mirror, jsModuleManifestFile, jsModuleManifestBytes)
	if err != nil || !strings.Contains(string(manifest), "selfhostedmod") {
		t.Fatalf("自建源文件下载/校验失败：%s %v", manifest, err)
	}
	code, err := engine.fetchIndexedJSFile(context.Background(), entries[0], mirror, jsModuleEntryFile, jsModuleEntryBytes)
	if err != nil || !strings.Contains(string(code), "module.exports") {
		t.Fatalf("自建源脚本下载/校验失败：%s %v", code, err)
	}
	// 篡改校验和仍必须拒绝（校验逻辑没有被兜底链绕过）。
	entries[0].SHA256[jsModuleManifestFile] = strings.Repeat("0", 64)
	if _, err := engine.fetchIndexedJSFile(context.Background(), entries[0], mirror, jsModuleManifestFile, jsModuleManifestBytes); err == nil {
		t.Fatal("校验和不符时必须报错")
	}
}
