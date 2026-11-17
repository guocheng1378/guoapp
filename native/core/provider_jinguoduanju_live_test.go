package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestJinguoduanjuLiveEndToEnd(t *testing.T) {
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

	// 1) 目录（上游实现，服务端 sort=latest / 本地分页 24）
	items, hasNext, err := d.fetchJinguoDuanjuCatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatalf("catalog: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("catalog: 0 items")
	}
	t.Logf("catalog items=%d hasNext=%v first=%q cover=%q episodes=%v", len(items), hasNext, items[0].Title, items[0].Cover, items[0].EpisodeCount)

	// 2) 分类（推荐/热度/nav/tag）
	if categories, err := d.fetchJinguoDuanjuCategories(ctx); err != nil {
		t.Logf("categories: %v", err)
	} else {
		t.Logf("categories=%d first=%q", len(categories), categories[0].Name)
	}

	// 3) 详情 + 分集
	_, dramaID, _ := splitProviderDramaID(items[0].ID)
	drama, chapters, err := d.fetchJinguoDuanjuDetail(ctx, dramaID)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	if len(chapters) == 0 {
		t.Fatalf("detail: 0 chapters for %s", dramaID)
	}
	t.Logf("detail name=%q chapters=%d firstChapter=%q", drama.Name, len(chapters), chapters[0].Title)

	// 4) 播放地址（设备匿名令牌；付费集可能返回「需会员/解锁」）
	media, err := d.resolveJinguoDuanjuMedia(ctx, Task{DramaID: items[0].ID, Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Logf("media（首集可能为付费/未解锁）: %v", err)
	} else if media.URL == "" {
		t.Fatal("media: empty URL")
	} else {
		t.Logf("media url=%q", media.URL)
	}
}

func TestJinguoduanjuSearchLive(t *testing.T) {
	if testing.Short() {
		t.Skip("skip live network test in short mode")
	}
	d := &Downloader{cfg: defaultConfig(), client: &http.Client{Timeout: 30 * time.Second}, limiter: newRequestLimiter(8, time.Nanosecond), providerHosts: map[string]string{}}
	ctx, cancel := context.WithTimeout(context.Background(), 60*time.Second)
	defer cancel()
	items, _, err := d.fetchJinguoDuanjuCatalogPage(ctx, 1, "", "爱")
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("search: 0 items")
	}
	t.Logf("search items=%d first=%q", len(items), items[0].Title)
}
