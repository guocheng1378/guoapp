//go:build live

package core

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"
)

// TestSourceRepairDiag 对待修复源做逐层诊断，全部复用应用自身代码路径。
func TestSourceRepairDiag(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	d := engine.downloader

	t.Run("huangguoai_candidates", func(t *testing.T) {
		for _, u := range []string{
			"https://www.agdkczeyx.cc/",
			"https://www.agdkczeyx.cc/genre/rebuo-duanju/",
			"https://07eb30.pu84h97k.cc/genre/rebuo-duanju/",
			"https://huangguoai.com/",
			"https://af36.ediayikma.cc/genre/rebuo-duanju/",
		} {
			ctx, cancel := context.WithTimeout(context.Background(), 12*time.Second)
			body, err := d.fetchProviderText(ctx, u, "https://www.agdkczeyx.cc/")
			cancel()
			if err != nil {
				t.Logf("FAIL %s => %v", u, err)
				continue
			}
			t.Logf("OK   %s => %d bytes, head=%q", u, len(body), safeHead(body, 120))
		}
	})

	t.Run("yeguo_discovery", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 40*time.Second)
		defer cancel()
		client := &yeguoAPIClient{downloader: d}
		for _, site := range []string{"https://www.yeguodj.com", "https://analyze.buxefaex.cc", "https://ygdj7.com"} {
			access, err := client.discoverConfigurationAt(ctx, site)
			if err != nil {
				t.Logf("discoverAt %s FAIL: %v", site, err)
				continue
			}
			t.Logf("discoverAt %s OK: base=%s site=%s", site, access.base, access.site)
			return
		}
		body, err := d.fetchProviderText(ctx, "https://analyze.buxefaex.cc/", "https://analyze.buxefaex.cc/")
		if err != nil {
			t.Errorf("raw page fetch FAIL: %v", err)
			return
		}
		t.Logf("raw page OK %d bytes head=%q", len(body), safeHead(body, 200))
	})

	t.Run("yeguo_e2e_catalog", func(t *testing.T) {
		ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
		defer cancel()
		items, hasMore, err := d.fetchYeguoCatalogPage(ctx, 1, "", "")
		if err != nil {
			t.Fatalf("yeguo catalog FAIL: %v", err)
		}
		first := ""
		if len(items) > 0 {
			first = items[0].ID + " " + items[0].Name
		}
		t.Logf("yeguo catalog OK: items=%d hasMore=%t first=%q", len(items), hasMore, first)
		if first == "" {
			return
		}
		detail, chapters, err := d.fetchYeguoDetail(ctx, strings.TrimPrefix(items[0].ID, "yeguo:"))
		if err != nil {
			t.Logf("yeguo detail FAIL: %v", err)
			return
		}
		t.Logf("yeguo detail OK: %s episodes=%d", detail.Name, len(chapters))
	})

	t.Run("dump_pages", func(t *testing.T) {
		work := `C:\Users\Administrator\AppData\Local\Temp\guoapp_recon`
		for _, item := range []struct{ name, url, referer string }{
			{"huangguoai_home.html", "https://huangguoai.com/", "https://huangguoai.com/"},
			{"huangguoai_aiduanju.html", "https://huangguoai.com/ai-duanju/", "https://huangguoai.com/"},
			{"huangguoai_video2181.html", "https://huangguoai.com/video/2181/", "https://huangguoai.com/ai-duanju/"},
			{"huangguoai_chigua2.html", "https://huangguoai.com/chigua/2/", "https://huangguoai.com/"},
			{"yeguo_analyze.html", "https://analyze.buxefaex.cc/", "https://analyze.buxefaex.cc/"},
		} {
			ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
			body, err := d.fetchProviderText(ctx, item.url, item.referer)
			cancel()
			if err != nil {
				t.Logf("dump %s FAIL: %v", item.name, err)
				continue
			}
			if writeErr := osWriteFile(work+`\`+item.name, []byte(body)); writeErr != nil {
				t.Logf("dump %s write FAIL: %v", item.name, writeErr)
				continue
			}
			t.Logf("dump %s OK %d bytes", item.name, len(body))
		}
	})
}

func safeHead(text string, n int) string {
	text = strings.TrimSpace(text)
	if len(text) > n {
		return text[:n]
	}
	return text
}

func osWriteFile(path string, data []byte) error {
	return os.WriteFile(path, data, 0o644)
}
