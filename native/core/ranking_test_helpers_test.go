package core

// 榜单测试共享助手（原 provider_rankings_test.go 迁移；榜单重建后仍被
// 弹幕/发现等测试使用）。

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// rankingTransport：函数型 RoundTripper，供测试注入本地伪源站。
type rankingTransport func(*http.Request) (*http.Response, error)

func (fn rankingTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return fn(request)
}

// rankingTestDownloader：带注入传输层与空白数据目录的 Downloader。
func rankingTestDownloader(t *testing.T, fn func(*http.Request) (*http.Response, error)) *Downloader {
	t.Helper()
	d := &Downloader{cfg: defaultConfig()}
	d.cfg.dataDir = t.TempDir()
	d.client = &http.Client{Transport: rankingTransport(fn)}
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	d.loadRankingCache()
	return d
}

func rankingHTTPResponse(request *http.Request, status int, body string) *http.Response {
	return &http.Response{
		StatusCode: status,
		Status:     fmt.Sprintf("%d %s", status, http.StatusText(status)),
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    request,
	}
}
