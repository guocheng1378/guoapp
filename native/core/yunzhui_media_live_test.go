package core

import (
	"context"
	"io"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
	"duanjuapp/native/sources/yunzhui"
)

func yunzhuiLiveMedia(t *testing.T) (provider.Media, provider.Host) {
	t.Helper()
	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        &http.Client{Timeout: 30 * time.Second},
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	host := d.host()
	spec, found := provider.SpecOf(provider.SourceYunzhui)
	if !found {
		t.Fatal("yunzhui spec missing")
	}
	src := yunzhui.New(spec)
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()
	items, err := src.Search(ctx, host, "guyu")
	if err != nil || len(items) == 0 {
		t.Fatalf("search failed: %v", err)
	}
	media, err := src.ResolveMedia(ctx, host, provider.Task{DramaID: items[0].ID, Chapter: provider.Chapter{}, Index: 0})
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	return media, host
}

func probeGet(t *testing.T, ctx context.Context, url, referer, agent string) (int, int, string) {
	t.Helper()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	if referer == "__EMPTY__" {
		request.Header.Set("Referer", "")
	}
	if agent != "" {
		request.Header.Set("User-Agent", agent)
	}
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		return 0, 0, err.Error()
	}
	body, _ := io.ReadAll(io.LimitReader(response.Body, 256))
	response.Body.Close()
	head := string(body)
	if len(head) > 60 {
		head = head[:60]
	}
	return response.StatusCode, len(body), strings.ReplaceAll(head, "\n", "|")
}

func TestYunzhuiMediaProbeLive(t *testing.T) {
	if testing.Short() {
		t.Skip("live")
	}
	media, liveHost := yunzhuiLiveMedia(t)
	t.Logf("media url=%s referer=%q", media.URL, media.Referer)
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()

	referers := []string{"", "__EMPTY__", "http://u.gslock.com/"}
	for _, referer := range referers {
		status, length, head := probeGet(t, ctx, media.URL, referer, "")
		t.Logf("playlist referer=%-28q status=%d len=%d head=%q", referer, status, length, head)
	}

	// segment probe: fetch playlist without referer, then hit first segment
	status, _, _ := probeGet(t, ctx, media.URL, "", "")
	if status != 200 {
		t.Skip("playlist not reachable")
	}
	playlist, _, err := liveHost.MediaPlaylist(ctx, media.URL, "")
	if err != nil {
		t.Logf("playlist fetch error: %v", err)
		return
	}
	re := regexp.MustCompile(`(?m)^[^\#].+\.(ts|m4s|mp4)`)
	match := re.FindString(playlist)
	if match == "" {
		t.Logf("no segment found, playlist head=%q", playlist[:min2(len(playlist), 200)])
		return
	}
	segment := strings.TrimSpace(match)
	if !strings.HasPrefix(segment, "http") {
		base := media.URL[:strings.LastIndex(media.URL, "/")+1]
		segment = base + segment
	}
	t.Logf("segment=%s", segment)
	for _, referer := range referers {
		status, length, head := probeGet(t, ctx, segment, referer, "")
		t.Logf("segment referer=%-28q status=%d len=%d head=%q", referer, status, length, head)
	}
}

func min2(a, b int) int {
	if a < b {
		return a
	}
	return b
}
