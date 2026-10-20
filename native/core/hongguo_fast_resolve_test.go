package core

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

// TestHongguoFastResolveBuildsPublicAddress 验证红果解析的零网络快速通道：
// 只凭章节里的剧集 ID 就能拼出公开直链，不再走 App 取流与网页播放页。
func TestHongguoFastResolveBuildsPublicAddress(t *testing.T) {
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 5 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	const seriesID = "7698628892759706686"
	const videoID = "7698630719496522776"
	media, err := d.resolveHongguoMedia(context.Background(), Task{
		DramaID: "hongguo:" + seriesID,
		Chapter: Chapter{VideoURL: "hongguo-cenc://" + videoID, Title: "第1集", ID: videoID},
	})
	if err != nil {
		t.Fatalf("fast resolve failed: %v", err)
	}
	if !strings.HasSuffix(media.URL, "/video/public/"+videoID+"/360p.mp4") {
		t.Fatalf("unexpected address: %s", media.URL)
	}
	if media.Referer == "" {
		t.Fatalf("missing referer")
	}
	if media.Quality != 360 {
		t.Fatalf("quality=%d want 360", media.Quality)
	}
	if len(media.Variants) != 1 {
		t.Fatalf("variants=%d want 1", len(media.Variants))
	}
}

// TestHongguoFullResolveSkipsFastLane 验证带强制标记时不走快速通道：
// 必须回到完整取流链（直链不可用时靠它换一条真实地址）。
func TestHongguoFullResolveSkipsFastLane(t *testing.T) {
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 5 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	ctx := context.WithValue(context.Background(), hongguoFullResolveKey{}, true)
	media, ok := d.hongguoFastMedia(ctx, "7698628892759706686", "7698630719496522776")
	if ok {
		t.Fatalf("fast lane must be disabled by the full-resolve marker: %s", media.URL)
	}
	if media.URL != "" {
		t.Fatalf("fast lane returned an address: %s", media.URL)
	}
} 
