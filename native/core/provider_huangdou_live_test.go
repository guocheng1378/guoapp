//go:build live

package core

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"
)

const huangdouLiveDramaID = "6a8c618e817f7dacc5972d84"

func TestHuangdouLiveVipChain(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 240*time.Second)
	defer cancel()

	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}

	client := newHuangdouAPIClient(d)
	_, chapters, err := d.fetchHuangdouChapters(ctx, huangdouLiveDramaID)
	if err != nil {
		t.Fatalf("chapters FAIL: %v", err)
	}
	vipCount, firstVIP, firstFree := 0, 0, 0
	for _, ch := range chapters {
		seq := chapterEpisodeNumber(ch, 0)
		if ch.VIP {
			vipCount++
			if firstVIP == 0 {
				firstVIP = seq
			}
		} else if firstFree == 0 {
			firstFree = seq
		}
	}
	t.Logf("chapters=%d vip=%d firstFree=%d firstVIP=%d", len(chapters), vipCount, firstFree, firstVIP)

	t.Run("free_episode_api_first", func(t *testing.T) {
		if firstFree == 0 {
			t.Skip("no free chapter")
		}
		start := time.Now()
		media, err := d.resolveHuangdouPlayback(ctx, client, huangdouLiveDramaID, firstFree)
		if err != nil {
			t.Fatalf("free ep playback FAIL: %v", err)
		}
		t.Logf("free ep%d ok in %s: %s", firstFree, time.Since(start).Round(time.Millisecond), media.URL)
		if media.HLSKey != nil {
			t.Logf("  hls_key present len=%d", len(media.HLSKey))
		}
		body, err := d.fetchProviderText(ctx, media.URL, media.Referer)
		if err != nil {
			t.Errorf("signed m3u8 fetch FAIL: %v", err)
			return
		}
		t.Logf("  m3u8 bytes=%d head=%q", len(body), body[:minInt2(120, len(body))])
	})

	t.Run("vip_episode_preview_error", func(t *testing.T) {
		if firstVIP == 0 {
			t.Skip("no vip chapter")
		}
		start := time.Now()
		_, err := d.resolveHuangdouPlayback(ctx, client, huangdouLiveDramaID, firstVIP)
		if err == nil {
			t.Logf("vip ep%d unexpectedly playable in %s", firstVIP, time.Since(start).Round(time.Millisecond))
			return
		}
		t.Logf("vip ep%d denied in %s: %v", firstVIP, time.Since(start).Round(time.Millisecond), err)
		var apiErr *huangdouAPIError
		if !strings.Contains(err.Error(), "VIP") && !strings.Contains(err.Error(), "试看") {
			t.Errorf("unexpected deny message: %v", err)
		}
		_ = apiErr
	})

	t.Run("no_backoff_poisoning", func(t *testing.T) {
		_, _, err := d.fetchHuangdouChapters(ctx, huangdouLiveDramaID)
		if err != nil {
			t.Fatalf("detail after vip denial FAIL (backoff poisoning?): %v", err)
		}
		t.Log("detail still works after vip denial")
	})
}

func minInt2(a, b int) int {
	if a < b {
		return a
	}
	return b
}

var _ = fmt.Sprint
