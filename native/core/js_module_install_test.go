package core

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// moduleZip 组一个模块安装包；extra 是多余文件（用来验证收紧）。
func moduleZip(t *testing.T, manifest, code string, extra map[string]string) []byte {
	t.Helper()
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct{ name, data string }{
		{jsModuleManifestFile, manifest}, {jsModuleEntryFile, code},
	} {
		writer, err := archive.Create(file.name)
		if err != nil {
			t.Fatalf("组包失败：%v", err)
		}
		if _, err := writer.Write([]byte(file.data)); err != nil {
			t.Fatalf("组包失败：%v", err)
		}
	}
	for name, data := range extra {
		writer, err := archive.Create(name)
		if err != nil {
			t.Fatalf("组包失败：%v", err)
		}
		if _, err := writer.Write([]byte(data)); err != nil {
			t.Fatalf("组包失败：%v", err)
		}
	}
	if err := archive.Close(); err != nil {
		t.Fatalf("组包失败：%v", err)
	}
	return buffer.Bytes()
}

// testModuleEngine 造一个带模块目录的引擎。
func testModuleEngine(t *testing.T) *nativeEngine {
	t.Helper()
	root := t.TempDir()
	engine := &nativeEngine{
		downloader:     &Downloader{client: http.DefaultClient},
		directory:      root,
		cacheDirectory: root,
	}
	jsModuleRootPath = engine.moduleRoot()
	t.Cleanup(func() { jsModuleRootPath = "" })
	return engine
}

func TestPrepareAndInstallModuleByToken(t *testing.T) {
	engine := testModuleEngine(t)
	pack := moduleZip(t, `{"id":"tokeninstall","name":"令牌安装","version":"1.0.0","api":1,"runtime":"js","hosts":["token.example"],"capabilities":["catalog"]}`,
		`module.exports={categories:function(){return [{id:"",name:"全部"}];}};`, nil)
	path := filepath.Join(t.TempDir(), "module.zip")
	if err := os.WriteFile(path, pack, 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	info, err := engine.nativeJSModulePrepare(context.Background(), path, "", "")
	if err != nil {
		t.Fatalf("预检失败：%v", err)
	}
	if info.ID != "tokeninstall" || info.Installed || info.Token == "" {
		t.Fatalf("预检信息异常：%+v", info)
	}
	if len(info.Hosts) != 1 || info.Hosts[0] != "token.example" {
		t.Fatalf("预检应给出域名：%+v", info.Hosts)
	}
	// 令牌未使用前模块不可用。
	if _, found := provider.Get("tokeninstall"); found {
		t.Fatal("预检不应直接注册")
	}
	defer provider.Unregister("tokeninstall")
	if _, err := engine.nativeJSModuleInstallToken(context.Background(), info.Token); err != nil {
		t.Fatalf("凭令牌安装失败：%v", err)
	}
	entry, found := provider.Get("tokeninstall")
	if !found {
		t.Fatal("安装后应注册")
	}
	if _, ok := entry.(provider.Cataloguer); !ok {
		t.Fatal("安装后应实现 Cataloguer")
	}
	// 同一令牌只能装一次。
	if _, err := engine.nativeJSModuleInstallToken(context.Background(), info.Token); err == nil {
		t.Fatal("令牌应一次性使用")
	}
}

// 模块分类必须透出到 Dart：模块管理页与首页分组都靠 moduleInfos 的
// category 决定归属，缺了它非官方表模块会被一律当成短剧类。
func TestModuleInfosCarryCategory(t *testing.T) {
	engine := testModuleEngine(t)
	defer provider.Unregister("categorymod")
	pack := moduleZip(t, `{"id":"categorymod","name":"分类模块","version":"1.0.0","api":1,"runtime":"js","category":"video","hosts":["cat.example"],"capabilities":["catalog"]}`,
		`module.exports={categories:function(){return [{id:"",name:"全部"}];}};`, nil)
	path := filepath.Join(t.TempDir(), "module.zip")
	if err := os.WriteFile(path, pack, 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	info, err := engine.nativeJSModulePrepare(context.Background(), path, "", "")
	if err != nil {
		t.Fatalf("预检失败：%v", err)
	}
	if info.Category != "video" {
		t.Fatalf("预检应带分类：%+v", info.Category)
	}
	if _, err := engine.nativeJSModuleInstallToken(context.Background(), info.Token); err != nil {
		t.Fatalf("安装失败：%v", err)
	}
	items, err := engine.nativeJSModuleInfos()
	if err != nil {
		t.Fatalf("读取模块列表失败：%v", err)
	}
	var found *nativeModuleInfo
	for i := range items {
		if items[i].ID == "categorymod" {
			found = &items[i]
		}
	}
	if found == nil {
		t.Fatal("模块列表里没有刚装的模块")
	}
	if found.Category != "video" {
		t.Fatalf("模块列表应带分类：%+v", found)
	}
	// JSON tag 必须与 Dart 端读的键一致（module['category']）。
	raw, err := json.Marshal(found)
	if err != nil {
		t.Fatalf("序列化失败：%v", err)
	}
	if !strings.Contains(string(raw), `"category":"video"`) {
		t.Fatalf("序列化后缺少 category 键：%s", raw)
	}
}

// 内置模块的商店条目同样要带分类（在线仓库按类分组展示）。
func TestBundledIndexEntriesCarryCategory(t *testing.T) {
	entries := bundledJSIndexEntries()
	if len(entries) == 0 {
		t.Fatal("内置模块清单为空")
	}
	categories := map[string]string{}
	for _, entry := range entries {
		categories[entry.ID] = entry.Category
	}
	if categories["yingshigongchang"] != "video" {
		t.Fatalf("影视工厂应为 video：%q", categories["yingshigongchang"])
	}
	if categories["zy155"] != "adult" {
		t.Fatalf("155 应为 adult：%q", categories["zy155"])
	}
	raw, err := json.Marshal(entries)
	if err != nil {
		t.Fatalf("序列化失败：%v", err)
	}
	if !strings.Contains(string(raw), `"category":"video"`) {
		t.Fatal("商店条目序列化后缺少 category 键")
	}
}

func TestPrepareModuleReportsUpgrade(t *testing.T) {
	engine := testModuleEngine(t)
	defer provider.Unregister("upgrademe")
	write := func(version string) []byte {
		return moduleZip(t, `{"id":"upgrademe","name":"升级测试","version":"`+version+`","api":1,"runtime":"js"}`,
			`module.exports={categories:function(){return [];}};`, nil)
	}
	path := filepath.Join(t.TempDir(), "module.zip")
	if err := os.WriteFile(path, write("1.0.0"), 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	first, err := engine.nativeJSModulePrepare(context.Background(), path, "", "")
	if err != nil {
		t.Fatalf("预检失败：%v", err)
	}
	if _, err := engine.nativeJSModuleInstallToken(context.Background(), first.Token); err != nil {
		t.Fatalf("安装失败：%v", err)
	}
	if err := os.WriteFile(path, write("1.1.0"), 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	second, err := engine.nativeJSModulePrepare(context.Background(), path, "", "")
	if err != nil {
		t.Fatalf("预检失败：%v", err)
	}
	if !second.Installed || second.Previous != "1.0.0" || second.Version != "1.1.0" {
		t.Fatalf("预检应报告覆盖关系：%+v", second)
	}
}

func TestInstallModuleRejectsBadToken(t *testing.T) {
	engine := testModuleEngine(t)
	for _, token := range []string{"", "short", strings.Repeat("z", 32)} {
		if _, err := engine.nativeJSModuleInstallToken(context.Background(), token); err == nil {
			t.Fatalf("令牌 %q 应被拒绝", token)
		}
	}
}

func TestPrepareModuleRejectsHostConflict(t *testing.T) {
	engine := testModuleEngine(t)
	defer provider.Unregister("conflict-a")
	defer provider.Unregister("conflict-b")
	root := engine.moduleRoot()
	if err := writeJSModuleDir(root, "conflict-a",
		[]byte(`{"id":"conflict-a","name":"甲","version":"1.0.0","api":1,"runtime":"js","hosts":["shared.example"]}`),
		[]byte(`module.exports={categories:function(){return [];}};`)); err != nil {
		t.Fatalf("写入失败：%v", err)
	}
	if _, err := RegisterJSModules(engine.downloader, root); err != nil {
		t.Fatalf("注册失败：%v", err)
	}
	pack := moduleZip(t, `{"id":"conflict-b","name":"乙","version":"1.0.0","api":1,"runtime":"js","hosts":["shared.example"]}`,
		`module.exports={categories:function(){return [];}};`, nil)
	path := filepath.Join(t.TempDir(), "module.zip")
	if err := os.WriteFile(path, pack, 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	if _, err := engine.nativeJSModulePrepare(context.Background(), path, "", ""); err == nil {
		t.Fatal("域名冲突应被拒绝")
	}
}

func TestModulePackageRejectsExtraFiles(t *testing.T) {
	engine := testModuleEngine(t)
	pack := moduleZip(t, `{"id":"extrafiles","name":"多余文件","version":"1.0.0","api":1,"runtime":"js"}`,
		`module.exports={categories:function(){return [];}};`, map[string]string{"readme.txt": "hi"})
	path := filepath.Join(t.TempDir(), "module.zip")
	if err := os.WriteFile(path, pack, 0o600); err != nil {
		t.Fatalf("写包失败：%v", err)
	}
	if _, err := engine.nativeJSModulePrepare(context.Background(), path, "", ""); err == nil {
		t.Fatal("包含多余文件的安装包应被拒绝")
	}
	// 少文件同样拒绝（只有清单、没有脚本）。
	manifestOnly := func() []byte {
		var buffer bytes.Buffer
		archive := zip.NewWriter(&buffer)
		writer, err := archive.Create(jsModuleManifestFile)
		if err != nil {
			t.Fatalf("组包失败：%v", err)
		}
		if _, err := writer.Write([]byte(`{"id":"x","name":"x","version":"1.0.0","api":1}`)); err != nil {
			t.Fatalf("组包失败：%v", err)
		}
		if err := archive.Close(); err != nil {
			t.Fatalf("组包失败：%v", err)
		}
		return buffer.Bytes()
	}
	if _, _, err := modulePackageFiles(manifestOnly()); err == nil {
		t.Fatal("缺少 main.js 的安装包应被拒绝")
	}
}

func TestModuleInfoExposesRankings(t *testing.T) {
	manifest := JSModuleManifest{
		ID: "rankmod", Name: "Rank Mod", Version: "1.0.0", API: 1,
		Capabilities: []string{"rankings"},
		Rankings:     []JSModuleRanking{{ID: "hot", Name: "热门榜"}},
	}
	info := moduleInfoOf(manifest)
	if len(info.Capabilities) != 1 || info.Capabilities[0] != "rankings" {
		t.Fatalf("capabilities not exposed: %+v", info)
	}
	if len(info.Rankings) != 1 || info.Rankings[0].ID != "hot" || info.Rankings[0].Name != "热门榜" {
		t.Fatalf("rankings not exposed: %+v", info)
	}
	// JSON 字段名须是 rankings（Dart 侧据此解析确认卡）。
	encoded, _ := json.Marshal(info)
	if !strings.Contains(string(encoded), `"rankings"`) {
		t.Fatalf("rankings json key missing: %s", encoded)
	}
}

func TestModuleInfosReportBrokenModule(t *testing.T) {
	engine := testModuleEngine(t)
	root := engine.moduleRoot()
	if err := os.MkdirAll(filepath.Join(root, "brokenmodule"), 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "brokenmodule", jsModuleManifestFile), []byte("{ not json"), 0o600); err != nil {
		t.Fatalf("写清单失败：%v", err)
	}
	items, err := engine.nativeJSModuleInfos()
	if err != nil {
		t.Fatalf("列表失败：%v", err)
	}
	if len(items) != 1 || items[0].ID != "brokenmodule" || items[0].Error == "" {
		t.Fatalf("坏模块应带错误信息：%+v", items)
	}
}

// 在线安装仍走预检 → 令牌安装（索引校验 + 冲突检查都不少）。
func TestOnlineInstallUsesPrepareThenToken(t *testing.T) {
	server, _ := fakeModuleStoreServer(t, "onlinetoken")
	originalIndex := jsModuleIndexAddresses
	originalFiles := jsModuleFileAddresses
	defer func() {
		jsModuleIndexAddresses = originalIndex
		jsModuleFileAddresses = originalFiles
	}()
	jsModuleIndexAddresses = []string{server.URL + "/index.json"}
	jsModuleFileAddresses = []string{server.URL + "/%s/%s/%s"}
	engine := testModuleEngine(t)
	defer provider.Unregister("onlinetoken")

	info, err := engine.nativeJSModulePrepare(context.Background(), "", "", "onlinetoken")
	if err != nil {
		t.Fatalf("在线预检失败：%v", err)
	}
	if info.ID != "onlinetoken" || info.Token == "" {
		t.Fatalf("在线预检信息异常：%+v", info)
	}
	if _, err := engine.nativeJSModuleInstallToken(context.Background(), info.Token); err != nil {
		t.Fatalf("在线安装失败：%v", err)
	}
	if _, found := provider.Get("onlinetoken"); !found {
		t.Fatal("在线安装后应注册")
	}
}
