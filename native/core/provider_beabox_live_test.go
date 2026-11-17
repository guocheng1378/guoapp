package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestBeaboxLiveEndToEnd(t *testing.T) {
	if testing.Short() {
		t.Skip("skip live network test in short mode")
	}
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		limiter:       newRequestLimiter(8, time.Nanosecond),
		providerHosts: map[string]string{},
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	items, hasNext, err := d.fetchBeaboxCatalogPage(ctx, 1, "", "")
	if err != nil {
		t.Fatalf("catalog: %v", err)
	}
	if len(items) == 0 {
		t.Fatal("catalog: 0 items")
	}
	t.Logf("catalog items=%d hasNext=%v firstID=%s coverHost=%q", len(items), hasNext, items[0].SourceID, firstHost(nativeText(items[0].Cover)))

	drama, chapters, err := d.fetchBeaboxDetail(ctx, items[0].SourceID)
	if err != nil {
		t.Fatalf("detail: %v", err)
	}
	if len(chapters) == 0 {
		t.Fatalf("detail: 0 chapters for %s", items[0].SourceID)
	}
	t.Logf("detail id=%s chapters=%d playHost=%q", drama.SourceID, len(chapters), firstHost(chapters[0].VideoURL))

	media, err := d.resolveBeaboxMedia(ctx, Task{DramaID: drama.ID, Chapter: chapters[0], Index: 1})
	if err != nil {
		t.Fatalf("media: %v", err)
	}
	if media.URL == "" {
		t.Fatal("media: empty URL")
	}
	t.Logf("media host=%q playlistBytes=%d", firstHost(media.URL), len(media.Playlist))

	if found, _, err := d.fetchBeaboxCatalogPage(ctx, 1, "", "a"); err != nil {
		t.Logf("search: %v", err)
	} else {
		t.Logf("search items=%d", len(found))
	}
}

func firstHost(raw string) string {
	if raw == "" {
		return ""
	}
	for _, scheme := range []string{"https://", "http://"} {
		if len(raw) > len(scheme) && raw[:len(scheme)] == scheme {
			rest := raw[len(scheme):]
			for i := 0; i < len(rest); i++ {
				if rest[i] == '/' {
					return rest[:i]
				}
			}
			return rest
		}
	}
	return "relative"
}
