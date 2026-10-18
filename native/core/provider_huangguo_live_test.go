//go:build live

package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestHuangguoAIRealSiteCatalogAndDetail(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	transport := &http.Transport{
		Proxy:               http.ProxyFromEnvironment,
		MaxIdleConns:        20,
		IdleConnTimeout:     90 * time.Second,
		TLSHandshakeTimeout: 10 * time.Second,
	}
	client := &http.Client{
		Timeout:   20 * time.Second,
		Transport: transport,
	}
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        client,
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(2, 0),
	}

	t.Run("catalog", func(t *testing.T) {
		cats := []string{"ai-duanju", "ai-manju", "ai-huanlian", "ai-mogai", "chigua"}
		var firstID string
		for _, cat := range cats {
			items, more, err := d.fetchHuangguoAICatalogPage(ctx, 1, cat)
			if err != nil {
				t.Logf("  %-20s FAIL: %v", cat, err)
				continue
			}
			if len(items) == 0 {
				t.Errorf("  %s 目录为空!", cat)
				continue
			}
			if firstID == "" {
				firstID = items[0].SourceID
			}
			t.Logf("  %-20s %3d 条  more=%v", cat, len(items), more)
			for i, it := range items {
				if i >= 2 {
					break
				}
				t.Logf("    [%d] srcID=%s  title=%s", i, it.SourceID, it.Title)
			}
		}
		paged, _, err := d.fetchHuangguoAICatalogPage(ctx, 2, "ai-duanju")
		if err != nil {
			t.Logf("  page2 FAIL: %v", err)
		} else {
			t.Logf("  page2 ai-duanju %d 条", len(paged))
		}
		t.Run("detail_and_m3u8", func(t *testing.T) {
			if firstID == "" {
				t.Skip("catalog empty, no source id to verify")
			}
			_, chapters, err := d.GetHuangguoChapters(ctx, sourceHuangguoAI, firstID)
			if err != nil {
				t.Fatalf("  %s FAIL: %v", firstID, err)
			}
			if len(chapters) == 0 {
				t.Fatalf("  %s 无章节", firstID)
			}
			ch := chapters[0]
			vl := ch.VideoURL
			t.Logf("  %s title=%s chapters=%d videoURL=%s...", firstID, ch.Title, len(chapters), vl[:minInt(80, len(vl))])
			body, err := d.fetchProviderText(ctx, vl, "")
			if err != nil {
				t.Errorf("    m3u8 HTTP FAIL: %v", err)
			} else {
				ok := len(body) > 10 && body[:7] == "#EXTM3U"
				t.Logf("    m3u8 bytes=%d  valid=%v", len(body), ok)
			}
		})
	})
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
