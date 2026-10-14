//go:build live

package core

import (
	"context"
	"net/http"
	"net/url"
	"testing"
	"time"
)

func TestHuangguoAIRealSiteCatalogAndDetail(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	proxyURL, _ := url.Parse("http://127.0.0.1:18080")
	transport := &http.Transport{
		Proxy:               http.ProxyURL(proxyURL),
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
		cats := []string{"rebuo-duanju", "jingxuan-duanju", "bikan-duanju", "quanbu-duanju", "renqi-duanju"}
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
			t.Logf("  %-20s %3d 条  more=%v", cat, len(items), more)
			for i, it := range items {
				if i >= 2 {
					break
				}
				t.Logf("    [%d] srcID=%s  title=%s", i, it.SourceID, it.Title)
			}
		}
	})

	t.Run("detail_and_m3u8", func(t *testing.T) {
		testCases := []string{"fang-mi-shu-ting-bu-dong-ren-hua", "dong-kuai-kai-men", "zuo-shou-ren-xin-you-shou-yan-luo"}
		for _, srcID := range testCases {
			_, chapters, err := d.GetHuangguoChapters(ctx, sourceHuangguoAI, srcID)
			if err != nil {
				t.Errorf("  %-50s FAIL: %v", srcID, err)
				continue
			}
			if len(chapters) == 0 {
				t.Errorf("  %-50s 无章节", srcID)
				continue
			}
			ch := chapters[0]
			vl := ch.VideoURL
			t.Logf("  %-50s title=%s", srcID, ch.Title)
			t.Logf("    chapters=%d  videoURL=%s...", len(chapters), vl[:minInt(80, len(vl))])
			body, err := d.fetchProviderText(ctx, vl, "")
			if err != nil {
				t.Errorf("    m3u8 HTTP FAIL: %v", err)
			} else {
				ok := len(body) > 10 && (body[:7] == "#EXTM3U")
				t.Logf("    m3u8 bytes=%d  valid=%v", len(body), ok)
			}
		}
	})
}

func minInt(a, b int) int {
	if a < b {
		return a
	}
	return b
}
