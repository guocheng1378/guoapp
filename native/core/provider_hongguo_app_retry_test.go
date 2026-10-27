package core

import (
	"context"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
)

// hongguoTestRegisteredDevice 是测试 transport 对设备注册请求（snssdk host）
// 的固定响应：让 ensureHongguoDevice 注册成功，播放调用计数不受注册请求污染。
const hongguoTestRegisteredDevice = `{"device_id_str":"7300000000000000001","install_id_str":"7300000000000000002"}`

// 红果网关会随机抽样返回 HTTP 200 空包。空包不是语义错误，必须重试：
// 受保护接口对新剧只返 play_info（我们不认），App 取流是唯一可用路径，
// 空包直接失败会把「红果不能看」放大成必现问题。
func TestHongguoAppRequestRetriesEmptyBody(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			return rankingHTTPResponse(request, 200, hongguoTestRegisteredDevice), nil
		}
		if calls.Add(1) <= 2 {
			return rankingHTTPResponse(request, 200, ""), nil
		}
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{"ok":1}}`), nil
	})
	result, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "7697251015992544280"})
	if err != nil {
		t.Fatalf("empty packet should be retried: %v", err)
	}
	if calls.Load() != 3 {
		t.Fatalf("calls=%d want 3", calls.Load())
	}
	if nestedMap(result, "data")["ok"] == nil {
		t.Fatalf("unexpected payload: %v", result)
	}
}

func TestHongguoAppRequestEmptyBodyGivesUpAfterAttempts(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			return rankingHTTPResponse(request, 200, hongguoTestRegisteredDevice), nil
		}
		calls.Add(1)
		return rankingHTTPResponse(request, 200, ""), nil
	})
	_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"})
	if err == nil || !strings.Contains(err.Error(), "未返回有效数据") {
		t.Fatalf("want empty-packet error, got %v", err)
	}
	if calls.Load() < 3 {
		t.Fatalf("calls=%d want >=3", calls.Load())
	}
}

func TestHongguoAppRequestRetriesMalformedJSON(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			return rankingHTTPResponse(request, 200, hongguoTestRegisteredDevice), nil
		}
		if calls.Add(1) == 1 {
			return rankingHTTPResponse(request, 200, "<html>gateway</html>"), nil
		}
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"}); err != nil {
		t.Fatalf("malformed body should be retried: %v", err)
	}
	if calls.Load() != 2 {
		t.Fatalf("calls=%d want 2", calls.Load())
	}
}

func TestHongguoAppRequestDoesNotRetryClientError(t *testing.T) {
	var calls atomic.Int32
	d := rankingTestDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			return rankingHTTPResponse(request, 200, hongguoTestRegisteredDevice), nil
		}
		calls.Add(1)
		return rankingHTTPResponse(request, 404, ""), nil
	})
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"}); err == nil {
		t.Fatal("404 should surface an error")
	}
	if calls.Load() != 1 {
		t.Fatalf("calls=%d want 1", calls.Load())
	}
}
