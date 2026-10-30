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
				"main_url": "/video/public/7698630719496522776/360p.mp4",
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

// TestHongguoProtectedMediaParsesPlayInfo 验证站点 2026-10-26 新版 play_info
// 结构（legacy_play_info → play_info）的解析：地址/备线/清晰度/时长齐全。
func TestHongguoProtectedMediaParsesPlayInfo(t *testing.T) {
	const mainURL = "https://v3-hgweb.qznovelvod.com/abc/video/tos/cn/tos-cn-v-6fcc8e/x/media-video-avc1/?a=8662&cs=0"
	const backupURL = "https://v11-hgweb.qznovelvod.com/def/video/tos/cn/tos-cn-v-6fcc8e/x/media-video-avc1/?a=8662&cs=0"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]any{
			"play_info": map[string]any{
				"vid":               "v02ebeg10000dbau75vog65le66l8bc0",
				"kid":               "6ad5e397f8818b5718d542d80002ebeb",
				"main_url":          mainURL,
				"backup_url":        backupURL,
				"player_access_key": "zOYYxgOLTMVR2XCVabckqDu0J6sHtU75UOJIqFS3dP48syanpw==",
				"definition":        "720p",
				"format":            "dash",
				"codec_type":        "h264",
				"width":             "1280",
				"height":            "720",
				"duration":          143.686,
				"init_range":        "0-1276",
				"index_range":       "1277-1656",
				"first_moof_range":  "1657-6759",
			},
			"base_resp": map[string]any{"StatusCode": 0, "StatusMessage": ""},
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

	media, err := d.resolveHongguoProtectedMedia(context.Background(), "7698628892759706686", "7698630719496522776")
	if err != nil {
		t.Fatalf("play_info resolve failed: %v", err)
	}
	if media.URL != mainURL {
		t.Fatalf("unexpected address: %s", media.URL)
	}
	if media.Quality != 720 {
		t.Fatalf("quality=%d want 720 (from definition)", media.Quality)
	}
	if media.Duration < 143*time.Second || media.Duration > 144*time.Second {
		t.Fatalf("duration=%v want ~143.686s", media.Duration)
	}
	if len(media.Variants) != 2 || media.Variants[0].URL != mainURL || media.Variants[1].URL != backupURL {
		t.Fatalf("variants malformed: %+v", media.Variants)
	}
}

// TestHongguoProtectedPlayInfoPrefersNewStructure 验证新旧结构并存时取 play_info。
func TestHongguoProtectedPlayInfoPrefersNewStructure(t *testing.T) {
	const newURL = "https://v3-hgweb.qznovelvod.com/new/media-video-avc1/"
	const oldURL = "https://qznovelvod.com/old/full.mp4"
	media, err := parseHongguoProtectedPlayInfo([]byte(`{"legacy_play_info":{"main_url":"` + oldURL +
		`","height":"540","duration":50},"play_info":{"main_url":"` + newURL +
		`","definition":"720p","duration":100}}`))
	if err != nil {
		t.Fatalf("parse failed: %v", err)
	}
	if media.URL != newURL {
		t.Fatalf("want play_info address, got %s", media.URL)
	}
	if media.Quality != 720 {
		t.Fatalf("quality=%d want 720", media.Quality)
	}
	if media.Duration < 100*time.Second {
		t.Fatalf("duration=%v want 100s", media.Duration)
	}
	if len(media.Variants) != 1 {
		t.Fatalf("legacy backup must not leak into new structure: %+v", media.Variants)
	}
}

// TestHongguoProtectedPlayInfoRejectsEmpty 验证两种结构都没有地址时报错。
func TestHongguoProtectedPlayInfoRejectsEmpty(t *testing.T) {
	if _, err := parseHongguoProtectedPlayInfo([]byte(`{"play_info":{"kid":"abc"},"base_resp":{"StatusCode":0}}`)); err == nil {
		t.Fatal("empty play_info must be rejected")
	}
	if _, err := parseHongguoProtectedPlayInfo([]byte(`{"play_info":{"main_url":"/relative/path.mp4"}}`)); err == nil {
		t.Fatal("relative address must be rejected")
	}
	if _, err := parseHongguoProtectedPlayInfo([]byte(`not-json`)); err == nil {
		t.Fatal("invalid json must be rejected")
	}
}
