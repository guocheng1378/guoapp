package core

import (
	"context"
	"io"
	"net/http"
	"testing"
	"time"
)

// TestHongguoSwitchLatencyProbe 量化切集的端到端耗时。
//
// 场景：上一集还在播时对下一集做预加载（nativePrefetch），随后播放器发起
// 第一个 Range 请求。分三段量：
//
//	A 直连源站的首字节（对照：源站排队的代价）
//	B 预读在飞行中时，播放器请求的首字节
//	C 预读完成后，播放器请求的首字节（命中本地，应当是毫秒级）
func TestHongguoSwitchLatencyProbe(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: requires network")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 60 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	const seriesID = "7698628892759706686"
	const videoID = "7698630719496522776"
	media, merr := d.resolveHongguoProtectedMedia(ctx, seriesID, videoID)
	if merr != nil {
		t.Skipf("protected media unavailable: %v", merr)
	}
	address := media.URL
	referer := ""

	start := time.Now()
	request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	request.Header.Set("User-Agent", hongguoWebUserAgent)
	request.Header.Set("Referer", referer)
	request.Header.Set("Range", "bytes=0-1048575")
	response, err := d.client.Do(request)
	if err != nil {
		t.Skipf("network unavailable: %v", err)
	}
	directTTFB := time.Since(start)
	_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
	response.Body.Close()
	t.Logf("A DIRECT       ttfb=%v", directTTFB.Round(time.Millisecond))

	stream, err := newNativeStreamServer(d)
	if err != nil {
		t.Fatalf("stream server failed: %v", err)
	}
	proxyAddress, token, err := stream.nativeOpen(providerMedia{URL: address, Referer: referer})
	if err != nil {
		t.Fatalf("nativeOpen failed: %v", err)
	}
	defer stream.nativeRelease(token)

	preloadStart := time.Now()
	stream.nativePrefetch(ctx, token, proxyAddress, 0)
	t.Logf("B PRELOAD      returned in %v", time.Since(preloadStart).Round(time.Millisecond))

	playerStart := time.Now()
	playerRequest, _ := http.NewRequestWithContext(ctx, http.MethodGet, proxyAddress, nil)
	playerRequest.Header.Set("Range", "bytes=0-1048575")
	playerResponse, err := http.DefaultClient.Do(playerRequest)
	if err != nil {
		t.Fatalf("player request failed: %v", err)
	}
	playerTTFB := time.Since(playerStart)
	read, _ := io.Copy(io.Discard, io.LimitReader(playerResponse.Body, 1<<20))
	playerResponse.Body.Close()
	t.Logf("B PLAYER(ttfb) ttfb=%v read=%d", playerTTFB.Round(time.Millisecond), read)

	deadline := time.Now().Add(60 * time.Second)
	for {
		if time.Now().After(deadline) {
			t.Logf("C cache not observed before deadline")
			break
		}
		cachedStart := time.Now()
		cachedRequest, _ := http.NewRequestWithContext(ctx, http.MethodGet, proxyAddress, nil)
		cachedRequest.Header.Set("Range", "bytes=1048576-2097151")
		cachedResponse, err := http.DefaultClient.Do(cachedRequest)
		if err != nil {
			t.Fatalf("cached request failed: %v", err)
		}
		cachedTTFB := time.Since(cachedStart)
		_, _ = io.Copy(io.Discard, io.LimitReader(cachedResponse.Body, 1<<20))
		cachedResponse.Body.Close()
		if cachedTTFB < 200*time.Millisecond {
			t.Logf("C CACHED       ttfb=%v", cachedTTFB.Round(time.Millisecond))
			break
		}
		t.Logf("C CACHED       ttfb=%v (still filling)", cachedTTFB.Round(time.Millisecond))
		time.Sleep(500 * time.Millisecond)
	}
}
