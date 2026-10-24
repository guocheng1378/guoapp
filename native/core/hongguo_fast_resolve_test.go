package core

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

// TestHongguoProtectedMediaResolvesFullURL 验证红果取流改走受保护的 play-info 接口：
// 公开 SEO 直链已降级为 10 秒试看，必须返回接口给出的完整签名地址，而不是 360p 试看片段。
func TestHongguoProtectedMediaResolvesFullURL(t *testing.T) {
	const seriesID = "7698628892759706686"
	const videoID = "7698630719496522776"
	const fullURL = "https://qznovelvod.com/video/720p-full.mp4?x-expires=9999999999&x-signature=abc"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost || r.URL.Path != "/api/video/protected/play-info" {
			t.Errorf("unexpected request %s %s", r.Method, r.URL.Path)
		}
		if r.URL.Query().Get("aid") != "8662" {
			t.Errorf("missing aid param")
		}
		body, _ := io.ReadAll(r.Body)
		var payload map[string]string
		if err := json.Unmarshal(body, &payload); err != nil {
			t.Errorf("bad payload: %v", err)
		}
		if payload["series_id"] != seriesID || payload["item_id"] != videoID || payload["definition"] != "720p" {
			t.Errorf("unexpected payload: %v", payload)
		}
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"legacy_play_info": map[string]any{
				"main_url": fullURL,
				"width":    "1694",
				"height":   "720",
				"duration": 103.19,
			},
			"base_resp": map[string]any{"status": 0},
		})
	}))
	defer server.Close()

	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 5 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	d.cfg.HongguoURL = server.URL

	media, err := d.resolveHongguoProtectedMedia(context.Background(), seriesID, videoID)
	if err != nil {
		t.Fatalf("protected resolve failed: %v", err)
	}
	if media.URL != fullURL {
		t.Fatalf("unexpected address: %s", media.URL)
	}
	if media.Quality != 720 {
		t.Fatalf("quality=%d want 720", media.Quality)
	}
	if media.Duration < 100*time.Second {
		t.Fatalf("duration too short: %v", media.Duration)
	}
	if len(media.Variants) != 1 || media.Variants[0].URL != fullURL {
		t.Fatalf("variants malformed: %v", media.Variants)
	}
}

// TestHongguoProtectedMediaRejectsPreviewPath 验证解析不会把 360p 试看直链当作整集。
func TestHongguoProtectedMediaRejectsPreviewPath(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"legacy_play_info": map[string]any{
				"main_url":  "/video/public/7698630719496522776/360p.mp4",
				"height":   "360",
				"duration": 10.0,
			},
		})
	}))
	defer server.Close()

	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 5 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	d.cfg.HongguoURL = server.URL

	// isProviderHTTPMediaURL 会拒绝站点相对路径，接口返回的相对试看地址应被判定无效。
	if _, err := d.resolveHongguoProtectedMedia(context.Background(), "7698628892759706686", "7698630719496522776"); err == nil {
		t.Fatal("relative preview path must be rejected")
	}
}
