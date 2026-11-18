package core

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"path/filepath"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

// jsModuleHostScript 覆盖模块 host 的工具类原语。
const jsModuleHostScript = `
module.exports = {
  preserve: function () { return host.preserveIntegers('{"id":12345678901234567890,"n":12}'); },
  html: function () {
    var tree = host.parseHtml('<div class="a">hello</div>');
    var found = null;
    (function walk(node) {
      if (found || !node) return;
      if (node.tag === 'div') { found = node; return; }
      var kids = node.children || [];
      for (var i = 0; i < kids.length; i++) walk(kids[i]);
    })(tree);
    return found ? (found.tag + '|' + found.attrs['class'] + '|' + found.children[0].text) : 'none';
  },
  resolve: function () { return host.resolveUrl('https://a.example/x/y', '../z?q=1'); },
  gcm: function () {
    var key = host.utf8Encode('0123456789abcdef');
    var nonce = host.utf8Encode('123456789012');
    var sealed = host.aesGcmSeal(key, nonce, host.utf8Encode('hello'), host.utf8Encode(''));
    return host.utf8Decode(host.aesGcmOpen(key, nonce, sealed, host.utf8Encode('')));
  },
  ecdh: function () {
    var a = host.ecdhP256KeyPair();
    var b = host.ecdhP256KeyPair();
    return host.hexEncode(host.ecdhP256(a.privateKey, b.publicKey)) === host.hexEncode(host.ecdhP256(b.privateKey, a.publicKey));
  },
  hkdf: function () {
    return host.hexEncode(host.hkdfSha256(host.utf8Encode('secret'), host.utf8Encode('salt'), host.utf8Encode('info'), 16));
  },
  cache: function () {
    host.cacheSet('k', 'v', 60000);
    return host.cacheGet('k') === 'v';
  },
  reserve: function () { return host.reserve('https://a.example/x', 'lane') > 0; },
  context: function () { var c = host.catalogContext(); return c.more === false && c.background === false; },
  known: function () { return host.isKnown('abc'); }
};
`

func TestJSModuleHostPrimitives(t *testing.T) {
	runtime, err := newJSModuleRuntime(&Downloader{}, JSModuleManifest{ID: "hosttest", Name: "Host 测试"}, jsModuleHostScript)
	if err != nil {
		t.Fatalf("模块加载失败：%v", err)
	}
	ctx := context.Background()
	var preserved string
	if err := runtime.call(ctx, nil, "preserve", &preserved); err != nil {
		t.Fatalf("preserveIntegers 失败：%v", err)
	}
	var payload map[string]any
	if err := json.Unmarshal([]byte(preserved), &payload); err != nil {
		t.Fatalf("保真整数输出不是合法 JSON：%v (%s)", err, preserved)
	}
	if payload["id"] != "12345678901234567890" {
		t.Fatalf("大整数应保留为字符串：%v", payload["id"])
	}
	if payload["n"] != float64(12) {
		t.Fatalf("普通整数应保持数值：%v", payload["n"])
	}

	var htmlText string
	if err := runtime.call(ctx, nil, "html", &htmlText); err != nil {
		t.Fatalf("parseHtml 失败：%v", err)
	}
	if htmlText != "div|a|hello" {
		t.Fatalf("HTML 解析结果错误：%q", htmlText)
	}

	var resolved string
	if err := runtime.call(ctx, nil, "resolve", &resolved); err != nil {
		t.Fatalf("resolveUrl 失败：%v", err)
	}
	if resolved != "https://a.example/z?q=1" {
		t.Fatalf("相对地址解析错误：%q", resolved)
	}

	var plain string
	if err := runtime.call(ctx, nil, "gcm", &plain); err != nil {
		t.Fatalf("AES-GCM 失败：%v", err)
	}
	if plain != "hello" {
		t.Fatalf("AES-GCM 往返错误：%q", plain)
	}

	var agreed bool
	if err := runtime.call(ctx, nil, "ecdh", &agreed); err != nil {
		t.Fatalf("ECDH 失败：%v", err)
	}
	if !agreed {
		t.Fatal("ECDH 双方协商结果应一致")
	}

	var derived string
	if err := runtime.call(ctx, nil, "hkdf", &derived); err != nil {
		t.Fatalf("HKDF 失败：%v", err)
	}
	if len(derived) != 32 {
		t.Fatalf("HKDF 应派生 16 字节（32 位十六进制）：%q", derived)
	}

	var cached bool
	if err := runtime.call(ctx, nil, "cache", &cached); err != nil {
		t.Fatalf("共享缓存失败：%v", err)
	}
	if !cached {
		t.Fatal("共享缓存读写不一致")
	}

	var reserved bool
	if err := runtime.call(ctx, nil, "reserve", &reserved); err != nil {
		t.Fatalf("预约失败：%v", err)
	}
	if !reserved {
		t.Fatal("预约应返回票据号")
	}

	var contextOK bool
	if err := runtime.call(ctx, nil, "context", &contextOK); err != nil {
		t.Fatalf("catalogContext 失败：%v", err)
	}
	if !contextOK {
		t.Fatal("catalogContext 应返回默认上下文")
	}

	var known bool
	if err := runtime.call(ctx, nil, "known", &known); err != nil {
		t.Fatalf("isKnown 失败：%v", err)
	}
	if known {
		t.Fatal("未注入已知剧集时应返回 false")
	}
}

func TestJSModuleCacheExpires(t *testing.T) {
	runtime, err := newJSModuleRuntime(&Downloader{}, JSModuleManifest{ID: "cachetest", Name: "缓存测试"}, "module.exports={};")
	if err != nil {
		t.Fatalf("模块加载失败：%v", err)
	}
	if err := runtime.cacheSet("k", "v", 20*time.Millisecond); err != nil {
		t.Fatalf("写缓存失败：%v", err)
	}
	if _, found := runtime.cacheGet("k"); !found {
		t.Fatal("缓存应命中")
	}
	time.Sleep(40 * time.Millisecond)
	if _, found := runtime.cacheGet("k"); found {
		t.Fatal("过期缓存应失效")
	}
}

// 榜单双轨：未导出榜单能力时不得误判为支持榜单。
func TestModuleRankingFallsBackWhenAbsent(t *testing.T) {
	d := &Downloader{}
	_, err := d.fetchRankingPage(context.Background(), rankingBoard{ID: "x", Source: "nosuchsource", Name: "不存在的源"}, 1)
	if err == nil {
		t.Fatal("不存在的站源应报错")
	}
}

// 搜索带警告：模块导出 searchWithWarning 时把警告带回。
func TestModuleSearchWithWarning(t *testing.T) {
	id := "modwarnsearch"
	manifest := JSModuleManifest{ID: id, Name: "警告搜索", Version: "1.0.0", API: jsModuleAPIVersion, Runtime: jsModuleRuntimeJS}
	raw, _ := json.Marshal(manifest)
	root := t.TempDir()
	script := `module.exports = {
  searchWithWarning: function (page, query) {
    return { items: [{ id: "` + id + `:1", source: "` + id + `", title: "部分命中" }], hasMore: false, warning: "第 2 页取回失败" };
  }
};`
	if err := writeJSModuleDir(root, id, raw, []byte(script)); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	d := &Downloader{client: http.DefaultClient}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister(id)
	entry, found := provider.Get(id)
	if !found {
		t.Fatal("模块未注册")
	}
	warn, ok := entry.(provider.WarningSearcher)
	if !ok {
		t.Fatal("导出 searchWithWarning 的模块应实现 WarningSearcher")
	}
	items, more, warning, err := warn.SearchPageWithWarning(context.Background(), nil, "关键词", 1)
	if err != nil || more || len(items) != 1 || warning != "第 2 页取回失败" {
		t.Fatalf("带警告搜索 = %v %v %q %v", items, more, warning, err)
	}
}

// jsModuleCapabilityScript 覆盖模块的可选能力导出。
const jsModuleCapabilityScript = `
module.exports = {
  categories: function () { return [{ id: '', name: '全部' }]; },
  suggestions: function (query) { return ['联想-' + query]; },
  danmakuIds: function (task) { return { series: 'S1', video: 'V1' }; },
  danmaku: function (series, video, startMS, durationMS) {
    return { episodeId: video, items: [{ id: 'd1', text: '模块弹幕', timeMs: 1200 }], startMs: startMS, nextMs: 0, total: 1 };
  },
  coverAddress: function (drama) { return 'https://cover.example/' + drama.sourceId + '.jpg'; },
  needsExtraMetadata: function () { return true; },
  extraMetadata: function (drama) { return { id: drama.id, onlineDate: '2026-11-17' }; }
};
`

// installCapabilityTestModule 装一个带能力导出的测试模块并注册。
func installCapabilityTestModule(t *testing.T, id string) *Downloader {
	t.Helper()
	manifest := JSModuleManifest{ID: id, Name: "能力测试模块", Version: "1.0.0", API: jsModuleAPIVersion, Runtime: jsModuleRuntimeJS}
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, []byte(jsModuleCapabilityScript)); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	d := &Downloader{client: &http.Client{}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	t.Cleanup(func() { provider.Unregister(id) })
	return d
}

func TestJSModuleCapabilities(t *testing.T) {
	id := "modcapstest"
	installCapabilityTestModule(t, id)
	entry, found := provider.Get(id)
	if !found {
		t.Fatal("测试模块未注册")
	}
	ctx := context.Background()

	suggester, ok := entry.(moduleSuggester)
	if !ok {
		t.Fatal("模块应实现 moduleSuggester")
	}
	names, err := suggester.ModuleSuggestions(ctx, nil, "测试")
	if err != nil || len(names) != 1 || names[0] != "联想-测试" {
		t.Fatalf("搜索联想 = %v %v", names, err)
	}

	danmaku, ok := entry.(moduleDanmakuProvider)
	if !ok {
		t.Fatal("模块应实现 moduleDanmakuProvider")
	}
	series, video, ok := danmaku.ModuleDanmakuIDs(ctx, nil, Task{DramaID: id + ":1"})
	if !ok || series != "S1" || video != "V1" {
		t.Fatalf("弹幕标识 = %q %q %v", series, video, ok)
	}
	page, err := danmaku.ModuleDanmaku(ctx, nil, series, video, 0, 30000)
	if err != nil || len(page.Items) != 1 || page.Items[0].Text != "模块弹幕" {
		t.Fatalf("弹幕 = %+v %v", page, err)
	}

	cover, ok := entry.(moduleCoverProvider)
	if !ok {
		t.Fatal("模块应实现 moduleCoverProvider")
	}
	address, err := cover.ModuleCoverAddress(ctx, nil, provider.Drama{ID: id + ":1", SourceID: "1"}, "1")
	if err != nil || address != "https://cover.example/1.jpg" {
		t.Fatalf("封面地址 = %q %v", address, err)
	}

	metadata, ok := entry.(moduleMetadataProvider)
	if !ok {
		t.Fatal("模块应实现 moduleMetadataProvider")
	}
	needed, err := metadata.ModuleNeedsExtraMetadata(ctx, nil, provider.Drama{ID: id + ":1"})
	if err != nil || !needed {
		t.Fatalf("是否需要补充元数据 = %v %v", needed, err)
	}
	patch, err := metadata.ModuleExtraMetadata(ctx, nil, provider.Drama{ID: id + ":1"}, "1")
	if err != nil || patch.OnlineDate != "2026-11-17" {
		t.Fatalf("补充元数据 = %+v %v", patch, err)
	}
}

func TestJSModuleCapabilitiesFallbackWhenAbsent(t *testing.T) {
	id := "modcapsbare"
	manifest := JSModuleManifest{ID: id, Name: "无能力模块", Version: "1.0.0", API: jsModuleAPIVersion, Runtime: jsModuleRuntimeJS}
	raw, _ := json.Marshal(manifest)
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, []byte("module.exports={categories:function(){return [];}};")); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	d := &Downloader{client: &http.Client{}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister(id)
	entry, _ := provider.Get(id)
	ctx := context.Background()
	if _, err := entry.(moduleSuggester).ModuleSuggestions(ctx, nil, "x"); err == nil {
		t.Fatal("未导出建议能力时应返回不支持错误")
	}
	if _, err := entry.(moduleDanmakuProvider).ModuleDanmaku(ctx, nil, "s", "v", 0, 1); err == nil {
		t.Fatal("未导出弹幕能力时应返回不支持错误")
	}
	if _, err := entry.(moduleCoverProvider).ModuleCoverAddress(ctx, nil, provider.Drama{}, "1"); err == nil {
		t.Fatal("未导出封面能力时应返回不支持错误")
	}
	if _, err := entry.(moduleMetadataProvider).ModuleExtraMetadata(ctx, nil, provider.Drama{}, "1"); err == nil {
		t.Fatal("未导出元数据能力时应返回不支持错误")
	}
}

// core 的双轨：模块提供能力时走模块，没提供时回退内置实现。
func TestCorePrefersModuleCapabilities(t *testing.T) {
	id := "modcapsdual"
	installCapabilityTestModule(t, id)
	engine := &nativeEngine{downloader: &Downloader{client: &http.Client{}}}
	names, err := engine.suggestions(context.Background(), id, "关键词")
	if err != nil || len(names) != 1 || names[0] != "联想-关键词" {
		t.Fatalf("搜索联想应走模块 = %v %v", names, err)
	}
	drama := nativeDrama{ID: id + ":1", Source: id, SourceID: "1", Title: "测试剧"}
	address, err := engine.downloader.nativeCoverAddress(context.Background(), drama)
	if err != nil || address != "https://cover.example/1.jpg" {
		t.Fatalf("封面应走模块 = %q %v", address, err)
	}
	patched, err := engine.nativeExtraMetadata(context.Background(), drama)
	if err != nil || patched.OnlineDate != "2026-11-17" {
		t.Fatalf("补充元数据应走模块 = %+v %v", patched, err)
	}
}

func TestBundledCapabilityManifestSurvivesInstall(t *testing.T) {
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	for id, module := range modules {
		if module.manifest.ID != id {
			t.Fatalf("内置模块 id 不一致：%s vs %s", id, module.manifest.ID)
		}
		if module.manifest.API != jsModuleAPIVersion {
			t.Fatalf("内置模块 %s 的 api 版本不符：%d", id, module.manifest.API)
		}
		if _, err := os.Stat(filepath.Join("bundled")); err != nil {
			t.Fatalf("内置模块目录缺失：%v", err)
		}
	}
}
