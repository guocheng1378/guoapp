package core

import (
	"context"
	"crypto/tls"
	"encoding/json"
	"net/http"
	"os"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

// TestHuangguoAIModuleLiveSmoke 真网验证 huangguoai 在线模块经增强 fetchText
// （POST 信封 + mirrors 轮转到活域）+ catalog/detail 门控后能拿到真实数据。
// 只在 GUOAPP_HUANGGUOAI_LIVE=1 时跑。
func TestHuangguoAIModuleLiveSmoke(t *testing.T) {
	if os.Getenv("GUOAPP_HUANGGUOAI_LIVE") == "" {
		t.Skip("未设置 GUOAPP_HUANGGUOAI_LIVE，跳过真网冒烟")
	}
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
	// 用生产同款浏览器 TLS 指纹 transport：黄果站点按 TLS 指纹拦截裸 Go client，
	// Python/生产能通而裸 client 超时，正是这个原因。
	d := &Downloader{cfg: Config{}, providerHosts: providerHostsSeed()}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	transport.ResponseHeaderTimeout = 20 * time.Second
	cdn := newCDNTransport(transport, newDNSResolver(transport))
	d.client = &http.Client{Transport: newHuangguoBrowserTransport(cdn, d), Timeout: 45 * time.Second}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()

	if !moduleDeclaresCapability("huangguoai", "catalog") {
		t.Fatal("huangguoai 未声明 catalog，门控不会生效")
	}

	entry, _ := provider.Get("huangguoai")
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	cataloguer := entry.(provider.Cataloguer)
	items, _, err := cataloguer.CatalogPage(ctx, d.host(), 1, "ai-duanju", "")
	if err != nil {
		t.Fatalf("模块目录失败：%v", err)
	}
	if len(items) == 0 {
		t.Fatal("模块目录返回空")
	}
	t.Logf("catalog=%d first=%q", len(items), items[0].Title)

	detailer := entry.(provider.Detailer)
	drama, chapters, err := detailer.Detail(ctx, d.host(), items[0].SourceID)
	if err != nil {
		t.Fatalf("模块详情失败：%v", err)
	}
	if len(chapters) == 0 {
		t.Fatal("模块详情无分集")
	}
	t.Logf("detail=%q chapters=%d", drama.Title, len(chapters))
}
