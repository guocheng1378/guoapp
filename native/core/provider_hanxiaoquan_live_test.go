package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestHanxiaoquanLiveEndToEnd(t *testing.T) {
	if testing.Short() {
		t.Skip("skip live network test in short mode")
	}
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		limiter:       newRequestLimiter(8, time.Nanosecond),
		providerHosts: map[string]string{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()

	// 1) 目录（首页最新）
	items, hasNext, err := d.fetchHanxiaoquanCatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatalf("catalog: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("catalog: 0 items")
	}
	t.Logf("catalog items=%d hasNext=%v first=%q cover=%q", len(items), hasNext, items[0].Title, items[0].Cover)

	// 2) 详情 + 分集
	_, dramaID, _ := splitProviderDramaID(items[0].ID)
	t.Logf("dramaID=%v", dramaID)
	drama, chapters, err := d.fetchHanxiaoquanDetail(ctx, dramaID)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	if len(chapters) == 0 {
		t.Fatalf("detail: 0 chapters for %s", dramaID)
	}
	t.Logf("detail name=%q chapters=%d first=%q url=%q", drama.Name, len(chapters), chapters[0].Title, chapters[0].VideoURL)

	// 3) 解析播放地址
	media, err := d.resolveHanxiaoquanMedia(ctx, Task{DramaID: items[0].ID, Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Fatalf("media: %v", err)
	}
	if media.URL == "" {
		t.Fatal("media: empty URL")
	}
	t.Logf("media url=%q playlistStart=%q", media.URL, truncate(media.Playlist, 40))
}

func TestHanxiaoquanCategoryLive(t *testing.T) {
	if testing.Short() {
		t.Skip("skip live network test in short mode")
	}
	d := &Downloader{cfg: defaultConfig(), client: &http.Client{Timeout: 30 * time.Second}, limiter: newRequestLimiter(8, time.Nanosecond), providerHosts: map[string]string{}}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	items, _, err := d.fetchHanxiaoquanCatalogPage(ctx, 1, "1", "")
	if err != nil {
		t.Fatalf("category catalog: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("category catalog: 0 items")
	}
	t.Logf("category items=%d first=%q", len(items), items[0].Title)
}
