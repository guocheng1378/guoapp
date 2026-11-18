package core

import (
	"fmt"
	"strings"
	"testing"
)

// resetSourceConfigForTest 记录进入时的热更值，测试结束后恢复，
// 避免污染同包其它测试的内置兜底状态。
func resetSourceConfigForTest(t *testing.T) {
	t.Helper()
	prevMirrors := huangguoAIMirrorList()
	prevDongpiandi := dongpiandiBaseURL()
	huangjuConfigMu.RLock()
	prevHuangjuAPI := huangjuAPIBaseURLHot
	huangjuConfigMu.RUnlock()
	prevHosts := providerHostsSeed()
	prevIndexOverride, prevFileOverride := jsModuleSourceOverrides()
	prevAppConfigURL := appConfigSourceURL()
	t.Cleanup(func() {
		setHuangguoAIMirrors(prevMirrors)
		setDongpiandiBaseURL(prevDongpiandi)
		setHuangjuAPIBase(prevHuangjuAPI)
		setProviderHosts(prevHosts)
		setJSModuleSourceURL("")
		jsModuleSourceMu.Lock()
		jsModuleIndexOverride, jsModuleFileOverride = prevIndexOverride, prevFileOverride
		jsModuleSourceMu.Unlock()
		setAppConfigSourceURL(prevAppConfigURL)
	})
}

// TestApplySourceConfigHuangjuAPIBase 剧果 API 域独立热更：站点域走 providerHosts，
// API 域走 huangjuAPIBaseURL。client 由 sync.Once 缓存，base 必须动态读，
// 否则远程下发新域后要重建引擎才生效。
func TestApplySourceConfigHuangjuAPIBase(t *testing.T) {
	resetSourceConfigForTest(t)
	downloader := setLiveEngineForTest(t, nil)
	client := downloader.huangjuClient()
	if got := client.apiBase(); got != huangjuAPIBase() {
		t.Fatalf("初始 API 根地址不符: %q", got)
	}

	value, err := applySourceConfig(map[string]any{
		"huangjuAPIBaseURL": "https://api.hj.example.com/",
		"providerHosts":     map[string]any{"huangju": "https://hj.example.com/"},
	})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	if result, ok := value.(map[string]any); !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	if got := huangjuAPIBase(); got != "https://api.hj.example.com" {
		t.Fatalf("API 根地址未热更: %q", got)
	}
	if got := client.apiBase(); got != "https://api.hj.example.com" {
		t.Fatalf("已缓存 client 未跟随热更: %q", got)
	}
	if got := client.siteBase(); got != "https://hj.example.com" {
		t.Fatalf("站点域未跟随覆盖: %q", got)
	}

	// cfg 注入（测试桩/内置配置）优先级高于热更值。
	downloader.cfg.HuangjuAPIURL = "https://api.injected.example.com"
	if got := client.apiBase(); got != "https://api.injected.example.com" {
		t.Fatalf("cfg 注入优先级错误: %q", got)
	}
	downloader.cfg.HuangjuAPIURL = ""

	// 非法值整段丢弃，保留当前生效值。
	for _, bad := range []any{"ftp://api.bad.example.com", 42} {
		out, err := applySourceConfig(map[string]any{"huangjuAPIBaseURL": bad})
		if err != nil {
			t.Fatalf("非法下发不应报错: %v", err)
		}
		if result, ok := out.(map[string]any); !ok || result["applied"] != false {
			t.Fatalf("非法 API 根地址未被拒绝: %v", out)
		}
	}
	if got := huangjuAPIBase(); got != "https://api.hj.example.com" {
		t.Fatalf("非法下发污染了生效值: %q", got)
	}
}

// setLiveEngineForTest 把带 Downloader 的最小引擎挂上 nativeState，
// 用于验证 setProviderHosts 对现有引擎的写透路径；测试结束恢复原引擎。
func setLiveEngineForTest(t *testing.T, downloader *Downloader) *Downloader {
	t.Helper()
	if downloader == nil {
		downloader = &Downloader{providerHosts: map[string]string{}}
	}
	engine := &nativeEngine{downloader: downloader}
	nativeState.Lock()
	prev := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = prev
		nativeState.Unlock()
	})
	return downloader
}

// TestApplySourceConfigRemoteUpdate 远程下发的镜像表与 dongpiandi 根地址生效，
// 且镜像候选与缓存 PageURL 解析真正消费热更后的值；旧缓存（内置域名）仍可解析。
func TestApplySourceConfigRemoteUpdate(t *testing.T) {
	resetSourceConfigForTest(t)
	value, err := applySourceConfig(map[string]any{
		"huangguoAIMirrors": []any{"https://mirror-a.example.com/", "https://mirror-b.example.com", "https://mirror-a.example.com"},
		"dongpiandiBaseURL": "https://dpi.example.com/",
	})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	result, ok := value.(map[string]any)
	if !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	mirrors := huangguoAIMirrorList()
	if len(mirrors) != 2 || mirrors[0] != "https://mirror-a.example.com" || mirrors[1] != "https://mirror-b.example.com" {
		t.Fatalf("镜像表未按预期热更（应去重+去尾斜杠）：%v", mirrors)
	}
	if got := dongpiandiBaseURL(); got != "https://dpi.example.com" {
		t.Fatalf("dongpiandi 根地址未热更：%s", got)
	}
	// 镜像候选消费热更后的镜像表。
	candidates := providerURLCandidates("https://huangguoai.com/d/abc123")
	if len(candidates) < 2 || candidates[0] != "https://mirror-a.example.com/d/abc123" {
		t.Fatalf("镜像候选未消费热更镜像表：%v", candidates)
	}
	// 新域名下发的 PageURL 可解析出剧集 ID。
	if id := dongpiandiDetailIDFromPageURL("https://dpi.example.com/player/ep42"); id != "ep42" {
		t.Fatalf("新域名 PageURL 解析失败：%q", id)
	}
	// 旧缓存（内置域名 PageURL）在热更后仍可解析。
	if id := dongpiandiDetailIDFromPageURL("https://dongpiandi.ai/player/legacy7"); id != "legacy7" {
		t.Fatalf("旧缓存（内置域名）解析失败：%q", id)
	}
}

// TestApplySourceConfigRejectsInvalid 非法配置整段丢弃（applied=false 且报原因），
// 不污染当前生效值。
func TestApplySourceConfigRejectsInvalid(t *testing.T) {
	resetSourceConfigForTest(t)
	setHuangguoAIMirrors([]string{"https://keep.example.com"})
	setDongpiandiBaseURL("https://keep-dpi.example.com")
	cases := []map[string]any{
		{"huangguoAIMirrors": []any{"ftp://bad.example.com"}},
		{"huangguoAIMirrors": []any{}},
		{"huangguoAIMirrors": []any{"https://ok.example.com", "not-a-url"}},
		{
			"huangguoAIMirrors": []any{
				"https://a1.example.com", "https://a2.example.com", "https://a3.example.com",
				"https://a4.example.com", "https://a5.example.com", "https://a6.example.com",
				"https://a7.example.com", "https://a8.example.com", "https://a9.example.com",
			},
		},
		{"huangguoAIMirrors": "https://text.example.com"},
		{"dongpiandiBaseURL": "ftp://bad.example.com"},
		{"dongpiandiBaseURL": 42},
		{"dongpiandiBaseURL": "   "},
		{"unknown": "value"},
		{},
	}
	for i, config := range cases {
		value, err := applySourceConfig(config)
		if err != nil {
			t.Fatalf("用例 %d: err = %v", i, err)
		}
		result, ok := value.(map[string]any)
		if !ok || result["applied"] != false {
			t.Fatalf("用例 %d: applied 期望 false，实际 %v", i, value)
		}
	}
	if mirrors := huangguoAIMirrorList(); len(mirrors) != 1 || mirrors[0] != "https://keep.example.com" {
		t.Fatalf("非法段不应污染镜像表：%v", mirrors)
	}
	if got := dongpiandiBaseURL(); got != "https://keep-dpi.example.com" {
		t.Fatalf("非法段不应污染 dongpiandi 根地址：%s", got)
	}
}

// TestSourceConfigFallbackDefaults 未配置时走内置兜底；未知域名的缓存页不解析。
func TestSourceConfigFallbackDefaults(t *testing.T) {
	resetSourceConfigForTest(t)
	setDongpiandiBaseURL("")
	if got := dongpiandiBaseURL(); got != dongpiandiBaseURLDefault {
		t.Fatalf("空热更值应回退内置：%s", got)
	}
	if id := dongpiandiDetailIDFromPageURL(dongpiandiBaseURLDefault + "/player/abc9"); id != "abc9" {
		t.Fatalf("内置域名 PageURL 解析失败：%q", id)
	}
	if id := dongpiandiDetailIDFromPageURL("https://other.example.com/player/abc9"); id != "" {
		t.Fatalf("未知域名 PageURL 不应解析出 ID：%q", id)
	}
}

// TestApplySourceConfigProviderHostsApply 合法覆盖表写透现有引擎并进播种快照，
// cloudfront 兜底域（providerBaseURL default 分支）与封面 Referer 真正消费覆盖值。
func TestApplySourceConfigProviderHostsApply(t *testing.T) {
	resetSourceConfigForTest(t)
	downloader := setLiveEngineForTest(t, nil)
	// 未覆盖时 cloudfront 走内置兜底。
	if got := downloader.providerBaseURL("cloudfront"); got != "https://d2pypzndaqisk.cloudfront.net" {
		t.Fatalf("cloudfront 默认兜底域不符：%s", got)
	}
	value, err := applySourceConfig(map[string]any{
		"providerHosts": map[string]any{
			"cloudfront": "https://mirror-cf.example.com/",
			"huangdou":   "https://mirror-hd.example.com/",
			"huangju":    "https://mirror-hj.example.com/",
		},
	})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	if result, ok := value.(map[string]any); !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	if got := downloader.providerHostOverride("cloudfront"); got != "https://mirror-cf.example.com" {
		t.Fatalf("覆盖未写透现有引擎（cloudfront）：%s", got)
	}
	if got := downloader.providerHostOverride("huangdou"); got != "https://mirror-hd.example.com" {
		t.Fatalf("覆盖未写透现有引擎（huangdou）：%s", got)
	}
	seed := providerHostsSeed()
	if seed["cloudfront"] != "https://mirror-cf.example.com" || seed["huangdou"] != "https://mirror-hd.example.com" {
		t.Fatalf("播种快照未收录覆盖值：%v", seed)
	}
	// providerBaseURL default 分支消费覆盖（cloudfront 兜底域可远程替换）。
	if got := downloader.providerBaseURL("cloudfront"); got != "https://mirror-cf.example.com" {
		t.Fatalf("providerBaseURL 未消费覆盖：%s", got)
	}
	// 剧果站点域同样消费覆盖（此前被 sanitize 整表拒收，覆盖是死配置）。
	if got := downloader.providerBaseURL(sourceHuangju); got != "https://mirror-hj.example.com" {
		t.Fatalf("剧果站点域未消费覆盖：%s", got)
	}
	// 封面 Referer（huangdou 回退路径）消费覆盖。
	if got := nativeCoverReferer(downloader, sourceHuangdou, "https://cdn.other.example.com/x.jpg"); got != "https://mirror-hd.example.com/home" {
		t.Fatalf("封面 Referer 未消费覆盖：%s", got)
	}
}

// TestApplySourceConfigProviderHostsRejects 覆盖表任一条目非法即整段丢弃，
// 当前生效值不受污染；huangju/yeguo/未注册源（douban、未知 id）一律拒收。
func TestApplySourceConfigProviderHostsRejects(t *testing.T) {
	resetSourceConfigForTest(t)
	downloader := setLiveEngineForTest(t, nil)
	setProviderHosts(map[string]string{"cloudfront": "https://keep.example.com"})
	cases := []map[string]any{
		{"providerHosts": "https://text.example.com"},
		{"providerHosts": map[string]any{"notasource": "https://a.example.com"}},
		{"providerHosts": map[string]any{"douban": "https://a.example.com"}},
		{"providerHosts": map[string]any{"yeguo": "https://a.example.com"}},
		{"providerHosts": map[string]any{"cloudfront": "ftp://a.example.com"}},
		{"providerHosts": map[string]any{"cloudfront": "https://"}},
		{"providerHosts": map[string]any{"cloudfront": 42}},
		{"providerHosts": map[string]any{"cloudfront": "https://ok.example.com", "yeguo": "https://bad.example.com"}},
	}
	for i, config := range cases {
		value, err := applySourceConfig(config)
		if err != nil {
			t.Fatalf("用例 %d: err = %v", i, err)
		}
		if result, ok := value.(map[string]any); !ok || result["applied"] != false {
			t.Fatalf("用例 %d: applied 期望 false，实际 %v", i, value)
		}
	}
	if got := downloader.providerHostOverride("cloudfront"); got != "https://keep.example.com" {
		t.Fatalf("非法段不应污染现有覆盖：%s", got)
	}
	if seed := providerHostsSeed(); seed["cloudfront"] != "https://keep.example.com" {
		t.Fatalf("非法段不应污染播种快照：%v", seed)
	}
}

// TestApplySourceConfigProviderHostsClears 空覆盖表合法，语义为清空覆盖、回落内置域名。
func TestApplySourceConfigProviderHostsClears(t *testing.T) {
	resetSourceConfigForTest(t)
	downloader := setLiveEngineForTest(t, nil)
	setProviderHosts(map[string]string{"cloudfront": "https://mirror-cf.example.com"})
	value, err := applySourceConfig(map[string]any{"providerHosts": map[string]any{}})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	if result, ok := value.(map[string]any); !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	if got := downloader.providerHostOverride("cloudfront"); got != "" {
		t.Fatalf("空表未清空现有覆盖：%s", got)
	}
	if got := downloader.providerBaseURL("cloudfront"); got != "https://d2pypzndaqisk.cloudfront.net" {
		t.Fatalf("清空后未回落内置兜底域：%s", got)
	}
}

// TestProviderURLCandidatesPreferredOverride 覆盖值作为媒体候选链的首选域名，
// 保留原路径重写到覆盖域；主域与镜像仍殿后兜底。
func TestProviderURLCandidatesPreferredOverride(t *testing.T) {
	resetSourceConfigForTest(t)
	downloader := setLiveEngineForTest(t, nil)
	setProviderHosts(map[string]string{"huangguoai": "https://mirror-hg.example.com"})
	candidates := downloader.providerURLCandidates("https://huangguoai.com/d/abc123")
	if len(candidates) < 2 {
		t.Fatalf("候选链过短：%v", candidates)
	}
	if candidates[0] != "https://mirror-hg.example.com/d/abc123" {
		t.Fatalf("覆盖域未作为首选候选：%v", candidates)
	}
}

// TestDuanjuBaseURLProviderHosts duanju 族媒体根域消费覆盖表（媒体解析链路）。
func TestDuanjuBaseURLProviderHosts(t *testing.T) {
	downloader := &Downloader{providerHosts: map[string]string{"yaguo": "https://yaguo-mirror.example.com"}}
	if got := downloader.duanjuBaseURL("yaguo"); got != "https://yaguo-mirror.example.com" {
		t.Fatalf("duanjuBaseURL 未消费覆盖：%s", got)
	}
}

// TestApplySourceConfigRemoteSourceURLs 新的两个远程配置源字段经 config.source
// 热更生效：moduleIndexUrl 同时置顶索引与模块文件基址（文件 URL 由索引目录推导、
// repo 只留给 GitHub 兜底）；appConfigUrl 记录供 Dart 拉取链置顶消费。
func TestApplySourceConfigRemoteSourceURLs(t *testing.T) {
	resetSourceConfigForTest(t)
	value, err := applySourceConfig(map[string]any{
		"moduleIndexUrl": "https://cdn.example.org/modules/index.json",
		"appConfigUrl":   "https://cdn.example.org/zhenguojian/app_config.json",
	})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	if result, ok := value.(map[string]any); !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	indexOverride, fileOverride := jsModuleSourceOverrides()
	if indexOverride != "https://cdn.example.org/modules/index.json" {
		t.Fatalf("索引覆盖未生效：%q", indexOverride)
	}
	if fileOverride != "https://cdn.example.org/modules/%[2]s/%[3]s" {
		t.Fatalf("模块文件基址未随索引覆盖推导：%q", fileOverride)
	}
	if got := appConfigSourceURL(); got != "https://cdn.example.org/zhenguojian/app_config.json" {
		t.Fatalf("appConfigUrl 未记录：%q", got)
	}
	// 覆盖作为首选、内置自建源殿后，且同域不重复。
	indexes := effectiveJSModuleIndexAddresses()
	if len(indexes) == 0 || indexes[0] != indexOverride {
		t.Fatalf("索引覆盖未置顶：%v", indexes)
	}
	files := effectiveJSModuleFileAddresses()
	if len(files) == 0 || files[0] != fileOverride {
		t.Fatalf("模块文件覆盖未置顶：%v", files)
	}
	for _, list := range [][]string{indexes, files} {
		seen := map[string]bool{}
		for _, addr := range list {
			if seen[addr] {
				t.Fatalf("地址链含重复项：%v", list)
			}
			seen[addr] = true
		}
	}
}

// TestSourceConfigURLsDefaultChain 未配置时走内置自建源优先链（自建 → jsDelivr → raw）。
func TestSourceConfigURLsDefaultChain(t *testing.T) {
	resetSourceConfigForTest(t)
	setJSModuleSourceURL("")
	indexes := effectiveJSModuleIndexAddresses()
	if indexes[0] != jsModuleSelfHostedIndexURL ||
		!strings.Contains(indexes[1], "jsdelivr") ||
		!strings.Contains(indexes[2], "raw.githubusercontent") {
		t.Fatalf("默认索引链顺序不符：%v", indexes)
	}
	files := effectiveJSModuleFileAddresses()
	if !strings.Contains(files[0], "guoapp.dpdns.org/modules") ||
		!strings.Contains(files[1], "jsdelivr") ||
		!strings.Contains(files[2], "raw.githubusercontent") {
		t.Fatalf("默认模块文件链顺序不符：%v", files)
	}
	// 自建模板用 tag/文件名直取，repo 仅用于 GitHub 兜底。
	got := fmt.Sprintf(files[0], "owner/repo", "v1.2.3", jsModuleManifestFile)
	if got != "https://guoapp.dpdns.org/modules/v1.2.3/"+jsModuleManifestFile {
		t.Fatalf("自建模块文件 URL 形态错误：%q", got)
	}
}

// TestApplySourceConfigRejectsBadRemoteSourceURLs 新字段非法时整段拒绝，
// 当前生效覆盖不被污染（与既有 sourceConfig 字段同语义）。
func TestApplySourceConfigRejectsBadRemoteSourceURLs(t *testing.T) {
	resetSourceConfigForTest(t)
	setJSModuleSourceURL("https://keep.example.org/modules/index.json")
	setAppConfigSourceURL("https://keep.example.org/zhenguojian/app_config.json")
	for _, cfg := range []map[string]any{
		{"moduleIndexUrl": 42},
		{"moduleIndexUrl": "ftp://bad.example.org/index.json"},
		{"moduleIndexUrl": "   "},
		{"appConfigUrl": 42},
		{"appConfigUrl": "not-a-url"},
	} {
		value, err := applySourceConfig(cfg)
		if err != nil {
			t.Fatalf("非法下发不应报错：%v", err)
		}
		if result, ok := value.(map[string]any); !ok || result["applied"] != false {
			t.Fatalf("非法字段应整段拒绝：%v -> %v", cfg, value)
		}
	}
	indexOverride, _ := jsModuleSourceOverrides()
	if indexOverride != "https://keep.example.org/modules/index.json" {
		t.Fatalf("非法下发污染了模块源覆盖：%q", indexOverride)
	}
	if got := appConfigSourceURL(); got != "https://keep.example.org/zhenguojian/app_config.json" {
		t.Fatalf("非法下发污染了配置源覆盖：%q", got)
	}
}
