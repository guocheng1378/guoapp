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
// 红果签名请求前会先向设备注册接口（log.snssdk.com）登记设备号，这是产品
// 固有行为；统一在测试传输层应答，各测试只处理自己的业务请求，调用计数也
// 不会被注册请求污染。
func rankingTestDownloader(t *testing.T, fn func(*http.Request) (*http.Response, error)) *Downloader {
	t.Helper()
	d := &Downloader{cfg: defaultConfig()}
	d.cfg.dataDir = t.TempDir()
	d.client = &http.Client{Transport: rankingTransport(func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			return rankingHTTPResponse(request, 200, hongguoTestRegisteredDevice), nil
		}
		return fn(request)
	})}
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	d.loadRankingCache()
	return d
}

// rankingTestDownloaderRaw：与 rankingTestDownloader 相同，但不拦截设备
// 注册请求——传输层完全交给调用方，供需要精细控制注册响应的测试使用。
func rankingTestDownloaderRaw(t *testing.T, fn func(*http.Request) (*http.Response, error)) *Downloader {
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
