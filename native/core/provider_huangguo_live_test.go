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

	d := newHuangguoLiveDownloader()

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

func newHuangguoLiveDownloader() *Downloader {
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
	return &Downloader{
		cfg:           defaultConfig(),
		client:        client,
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(2, 0),
	}
}

// TestHuangguoAIMultiEpisodeResolve 多集剧真网回归：详情页 epPlaySrcs
// 只携带前几集地址，其余集必须经 /video/{id}/ep-{N}/ 分集页按需解析成功
// （2026-10-20 实测：5667《东京牛头人》12 集中 1-2 集走 map 直链，
// 3+ 走分集页；分集键 ep-N 归一为纯数字集号）。
func TestHuangguoAIMultiEpisodeResolve(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 180*time.Second)
	defer cancel()
	d := newHuangguoLiveDownloader()

	items, _, err := d.fetchHuangguoAICatalogPage(ctx, 1, "")
	if err != nil {
		t.Fatalf("catalog: %v", err)
	}
	if len(items) == 0 {
		t.Fatalf("catalog empty")
	}
	checked := 0
	for _, item := range items {
		if checked >= 6 {
			break
		}
		_, chapters, err := d.GetHuangguoChapters(ctx, sourceHuangguoAI, item.SourceID)
		if err != nil {
			t.Logf("detail %s (%s): %v", item.SourceID, item.DisplayTitle(), err)
			continue
		}
		checked++
		if len(chapters) <= 1 {
			continue
		}
		seen := map[int]bool{}
		for _, ch := range chapters {
			idx := chapterEpisodeNumber(ch, 0)
			if seen[idx] {
				t.Errorf("%s: duplicate chapter index %d", item.SourceID, idx)
			}
			seen[idx] = true
		}
		var target *Chapter
		for i := range chapters {
			if !isProviderHTTPMediaURL(chapters[i].VideoURL) {
				target = &chapters[i]
				break
			}
		}
		if target == nil {
			t.Logf("%s: %d chapters all with direct media", item.SourceID, len(chapters))
			break
		}
		dramaID := providerDramaID(sourceHuangguoAI, item.SourceID)
		media, err := d.resolveProviderMedia(ctx, Task{DramaID: dramaID, Chapter: *target})
		if err != nil {
			t.Errorf("%s: resolve ep %d via %s failed: %v", item.SourceID, chapterEpisodeNumber(*target, 0), target.PageURL, err)
		} else {
			t.Logf("%s: %d chapters, ep %d resolved via page => %.80s", item.SourceID, len(chapters), chapterEpisodeNumber(*target, 0), media.URL)
		}
		break
	}
	if checked == 0 {
		t.Fatalf("no detail checked")
	}
}
