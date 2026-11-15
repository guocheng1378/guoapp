package core

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"

	"duanjuapp/native/provider"
)

// TestMediaRequestFallsBackToNoRefererOnHotlink403 covers the generic hotlink
// fallback: a CDN that answers 403 for any Referer is served by a second
// attempt without the header, and the host is remembered so later requests go
// out bare instead of paying a rejected request first.
func TestMediaRequestFallsBackToNoRefererOnHotlink403(t *testing.T) {
	var mu sync.Mutex
	requests, withReferer := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests++
		if r.Header.Get("Referer") != "" {
			withReferer++
		}
		mu.Unlock()
		if r.Header.Get("Referer") != "" {
			// A hotlink guard answers with an HTML page, not a bare error.
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.WriteHeader(http.StatusForbidden)
			_, _ = w.Write([]byte("<html><body>hotlink denied</body></html>"))
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("media-bytes"))
	}))
	defer server.Close()

	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}

	fetch := func(path string) *http.Response {
		request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL+path, nil)
		if err != nil {
			t.Fatal(err)
		}
		request.Header.Set("Referer", "http://site.example/")
		response, err := d.doMediaRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		return response
	}

	response := fetch("/first.ts")
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected the refererless retry to succeed, got %d", response.StatusCode)
	}
	mu.Lock()
	first, firstReferer := requests, withReferer
	mu.Unlock()
	if first != 2 || firstReferer != 1 {
		t.Fatalf("expected 2 requests (1 with referer, 1 without), got %d / %d", first, firstReferer)
	}
	host := strings.ToLower(strings.TrimPrefix(server.URL, "http://"))
	if index := strings.Index(host, ":"); index >= 0 {
		host = host[:index]
	}
	if !d.mediaHostRefererless(host) {
		t.Fatalf("host %q should be remembered as refusing the Referer header", host)
	}

	// The host is known now, so the next request must go out bare right away.
	response2 := fetch("/second.ts")
	defer response2.Body.Close()
	if response2.StatusCode != http.StatusOK {
		t.Fatalf("expected the known host to be served without a Referer, got %d", response2.StatusCode)
	}
	mu.Lock()
	second, secondReferer := requests-first, withReferer-firstReferer
	mu.Unlock()
	if second != 1 || secondReferer != 0 {
		t.Fatalf("expected a single bare request for a known host, got %d / %d", second, secondReferer)
	}
}

// TestMediaRequestKeepsWorkingWithoutHotlink makes sure the fallback does not
// touch requests that succeed with the Referer header.
func TestMediaRequestKeepsWorkingWithoutHotlink(t *testing.T) {
	var mu sync.Mutex
	requests, withReferer := 0, 0
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		requests++
		if r.Header.Get("Referer") != "" {
			withReferer++
		}
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("media-bytes"))
	}))
	defer server.Close()

	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	request, err := http.NewRequestWithContext(context.Background(), http.MethodGet, server.URL+"/ok.ts", nil)
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Referer", "http://site.example/")
	response, err := d.doMediaRequest(request)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		t.Fatalf("expected 200, got %d", response.StatusCode)
	}
	mu.Lock()
	defer mu.Unlock()
	if requests != 1 || withReferer != 1 {
		t.Fatalf("expected a single request keeping the Referer, got %d / %d", requests, withReferer)
	}
}

// TestResolveCacheKeyCoversYunzhui makes sure the resolve cache can hold the
// yunzhui result: its chapters carry no video address, so the chapter id is
// the only stable key.
func TestResolveCacheKeyCoversYunzhui(t *testing.T) {
	chapter := provider.Chapter{
		ID:     provider.ChapterID(provider.SourceYunzhui, "175520", "1"),
		Source: provider.SourceYunzhui,
	}
	key := nativeResolveCacheKey(Task{DramaID: "yunzhui:175520", Chapter: chapter, Index: 0}, nativeInput{})
	if key == "" {
		t.Fatal("yunzhui resolve results must be cacheable")
	}
	if !strings.Contains(key, chapter.ID) {
		t.Fatalf("cache key %q should carry the chapter id", key)
	}
}
