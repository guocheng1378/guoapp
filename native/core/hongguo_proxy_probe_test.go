package core

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"testing"
	"time"
)

// TestHongguoProxyCacheBenefit 量化「本机代理 + 本地预读缓存」对红果网页直链
// 分块读取的收益：模拟播放器按块发 Range 请求，对比直连与走代理的每块耗时。
func TestHongguoProxyCacheBenefit(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: requires network")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Second)
	defer cancel()
	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 40 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(8, 0),
	}
	const seriesID = "7698628892759706686"
	const videoID = "7698630719496522776"
	media, err := d.resolveHongguoMedia(ctx, Task{
		DramaID: "hongguo:" + seriesID,
		Chapter: Chapter{VideoURL: "hongguo-cenc://" + videoID, Title: "probe", ID: videoID},
	})
	if err != nil {
		t.Fatalf("resolve failed: %v", err)
	}
	t.Logf("RESOLVE url=%s", media.URL)

	pullBlocks := func(label, address string, blocks int) {
		for index := 0; index < blocks; index++ {
			from := int64(index) * (1 << 20)
			request, _ := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
			request.Header.Set("User-Agent", hongguoWebMediaUserAgent(address))
			request.Header.Set("Referer", "https://hongguoduanju.com/")
			request.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", from, from+(1<<20)-1))
			start := time.Now()
			response, err := d.client.Do(request)
			if err != nil {
				t.Logf("%s block%d error after %v: %v", label, index, time.Since(start).Round(time.Millisecond), err)
				continue
			}
			ttfb := time.Since(start)
			read, _ := io.Copy(io.Discard, io.LimitReader(response.Body, 1<<20))
			response.Body.Close()
			t.Logf("%s block%d status=%d ttfb=%-10v read=%d", label, index, response.StatusCode,
				ttfb.Round(time.Millisecond), read)
		}
	}

	pullBlocks("DIRECT", media.URL, 6)

	stream, err := newNativeStreamServer(d)
	if err != nil {
		t.Fatalf("stream server failed: %v", err)
	}
	address, token, err := stream.nativeOpen(media)
	if err != nil {
		t.Fatalf("nativeOpen failed: %v", err)
	}
	defer stream.nativeRelease(token)
	pullBlocks("PROXY", address, 8)
}
