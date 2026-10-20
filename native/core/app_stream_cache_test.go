package core

import (
	"bytes"
	"context"
	"io"
	"math/rand"
	"net/http"
	"net/http/httptest"
	"path"
	"testing"
	"time"
)

func TestParseNativeRange(t *testing.T) {
	cases := []struct {
		header   string
		start    int64
		end      int64
		hasRange bool
		ok       bool
	}{
		{"", 0, -1, false, true},
		{"bytes=0-", 0, -1, true, true},
		{"bytes=100-199", 100, 199, true, true},
		{"bytes=100-", 100, -1, true, true},
		{"bytes=-500", 0, 0, false, false},
		{"bytes=abc-def", 0, 0, false, false},
		{"bytes=200-100", 0, 0, false, false},
		{"items=0-10", 0, 0, false, false},
		{"bytes=0-99,200-299", 0, 0, false, false},
	}
	for _, item := range cases {
		start, end, hasRange, ok := parseNativeRange(item.header)
		if ok != item.ok || hasRange != item.hasRange {
			t.Fatalf("parse %q ok=%v/%v hasRange=%v/%v", item.header, ok, item.ok, hasRange, item.hasRange)
		}
		if ok && hasRange && (start != item.start || end != item.end) {
			t.Fatalf("parse %q = %d-%d want %d-%d", item.header, start, end, item.start, item.end)
		}
	}
}

// TestNativeStreamCacheServesRange 验证直链媒体预读后，播放器的 Range 请求
// 由本地缓存响应：上游关闭后请求依然成功且字节一致。
func TestNativeStreamCacheServesRange(t *testing.T) {
	payload := make([]byte, 2*1024*1024)
	if _, err := rand.New(rand.NewSource(7)).Read(payload); err != nil {
		t.Fatalf("rand failed: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.ServeContent(writer, request, "media.mp4", time.Time{}, bytes.NewReader(payload))
	}))
	downloader := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	stream, err := newNativeStreamServer(downloader)
	if err != nil {
		t.Fatalf("stream server failed: %v", err)
	}
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/media.mp4", Referer: upstream.URL})
	if err != nil {
		t.Fatalf("nativeOpen failed: %v", err)
	}
	defer stream.nativeRelease(token)

	request, _ := http.NewRequest(http.MethodGet, address, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("first request failed: %v", err)
	}
	_, _ = io.Copy(io.Discard, response.Body)
	response.Body.Close()

	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	if session == nil {
		t.Fatalf("session missing")
	}
	deadline := time.Now().Add(20 * time.Second)
	assetID := path.Base(address)
	for {
		session.mu.Lock()
		cache := session.caches[assetID]
		session.mu.Unlock()
		if cache != nil {
			size, total, complete, failed, _ := cache.snapshot()
			if complete || failed {
				if failed {
					t.Fatalf("prefetch failed")
				}
				if total != int64(len(payload)) || size != int64(len(payload)) {
					t.Fatalf("prefetch size=%d total=%d want %d", size, total, len(payload))
				}
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("prefetch did not finish in time")
		}
		time.Sleep(100 * time.Millisecond)
	}

	upstream.Close()

	rangeRequest, _ := http.NewRequest(http.MethodGet, address, nil)
	rangeRequest.Header.Set("Range", "bytes=1000-1999")
	rangeResponse, err := http.DefaultClient.Do(rangeRequest)
	if err != nil {
		t.Fatalf("range request failed: %v", err)
	}
	defer rangeResponse.Body.Close()
	if rangeResponse.StatusCode != http.StatusPartialContent {
		t.Fatalf("status=%d want 206", rangeResponse.StatusCode)
	}
	body, _ := io.ReadAll(rangeResponse.Body)
	if len(body) != 1000 {
		t.Fatalf("read %d bytes want 1000", len(body))
	}
	if !bytes.Equal(body, payload[1000:2000]) {
		t.Fatalf("payload mismatch")
	}
}

// TestNativeStreamPrefetchFillsLocalCache 验证预加载入口会立刻启动本地预读：
// 播放器还没发请求，整集就已经在往本地文件里落，源站的排队提前付掉，
// 切集时命中本地即可零等待。
func TestNativeStreamPrefetchFillsLocalCache(t *testing.T) {
	payload := make([]byte, 2*1024*1024)
	if _, err := rand.New(rand.NewSource(11)).Read(payload); err != nil {
		t.Fatalf("rand failed: %v", err)
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		http.ServeContent(writer, request, "media.mp4", time.Time{}, bytes.NewReader(payload))
	}))
	downloader := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	stream, err := newNativeStreamServer(downloader)
	if err != nil {
		t.Fatalf("stream server failed: %v", err)
	}
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/media.mp4", Referer: upstream.URL})
	if err != nil {
		t.Fatalf("nativeOpen failed: %v", err)
	}
	defer stream.nativeRelease(token)

	// 预加载：不等源站，直接把整集预读挂到后台。
	stream.nativePrefetch(context.Background(), token, address, 0)

	stream.mu.Lock()
	session := stream.sessions[token]
	stream.mu.Unlock()
	assetID := path.Base(address)
	deadline := time.Now().Add(20 * time.Second)
	for {
		session.mu.Lock()
		cache := session.caches[assetID]
		session.mu.Unlock()
		if cache != nil {
			size, total, complete, failed, _ := cache.snapshot()
			if complete || failed {
				if failed {
					t.Fatalf("prefetch failed")
				}
				if total != int64(len(payload)) || size != int64(len(payload)) {
					t.Fatalf("prefetch size=%d total=%d want %d", size, total, len(payload))
				}
				break
			}
		}
		if time.Now().After(deadline) {
			t.Fatalf("prefetch did not fill the local cache in time")
		}
		time.Sleep(50 * time.Millisecond)
	}

	// 上游关掉后，播放器的请求依然命中本地缓存。
	upstream.Close()
	request, _ := http.NewRequest(http.MethodGet, address, nil)
	response, err := http.DefaultClient.Do(request)
	if err != nil {
		t.Fatalf("request after upstream close failed: %v", err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(response.Body)
	if len(body) != len(payload) {
		t.Fatalf("read %d bytes want %d", len(body), len(payload))
	}
	if !bytes.Equal(body, payload) {
		t.Fatalf("payload mismatch")
	}
}
