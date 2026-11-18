package core

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// jsFetchTextProbeScript 把 host.fetchText 的结果回传给 Go，便于断言 method/body/mirrors。
const jsFetchTextProbeScript = `
module.exports = {
	probe: function (options) {
		var r = host.fetchText(options);
		return { body: r.body, url: r.url, status: r.status };
	}
};
`

func newFetchTextProbeRuntime(t *testing.T, d *Downloader) *jsModuleRuntime {
	t.Helper()
	manifest := JSModuleManifest{ID: "fetchprobe", Name: "探针", Version: "1.0.0", API: 1}
	runtime, err := newJSModuleRuntime(d, manifest, jsFetchTextProbeScript)
	if err != nil {
		t.Fatalf("runtime load: %v", err)
	}
	return runtime
}

func callFetchText(t *testing.T, runtime *jsModuleRuntime, options map[string]any) map[string]any {
	t.Helper()
	var result map[string]any
	if err := runtime.call(nil, nil, "probe", &result, options); err != nil {
		t.Fatalf("probe call: %v", err)
	}
	return result
}

// TestFetchTextPOSTEnvelope 验证增强后的 fetchText 能发 POST 信封（黄果 AI edge 协议所需）。
func TestFetchTextPOSTEnvelope(t *testing.T) {
	var gotMethod, gotUA string
	bodyBytes := []byte{}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotMethod = r.Method
		bodyBytes, _ = io.ReadAll(r.Body)
		gotUA = r.Header.Get("User-Agent")
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"status":1,"data":{"ok":true}}`)
	}))
	defer server.Close()

	d := &Downloader{client: &http.Client{}}
	runtime := newFetchTextProbeRuntime(t, d)
	result := callFetchText(t, runtime, map[string]any{
		"url":       server.URL + "/api/edge/request",
		"body":      `{"method":"GET","path":"/api/search"}`,
		"userAgent": "ProbeUA/1.0",
	})

	if gotMethod != http.MethodPost {
		t.Fatalf("body 非空应默认 POST, got %s", gotMethod)
	}
	if !strings.Contains(string(bodyBytes), `/api/search`) {
		t.Fatalf("POST body 未透传: %s", string(bodyBytes))
	}
	if gotUA != "ProbeUA/1.0" {
		t.Fatalf("userAgent 未透传: %s", gotUA)
	}
	bodyText, _ := result["body"].(string)
	if !strings.Contains(bodyText, `"ok":true`) {
		t.Fatalf("响应 body 未回传: %v", result)
	}
	if int(result["status"].(float64)) != 200 {
		t.Fatalf("status 错误: %v", result["status"])
	}
}

// TestFetchTextMirrorsFallback 验证镜像轮转：死域（连接失败/404）自动换下一活域。
func TestFetchTextMirrorsFallback(t *testing.T) {
	var liveHits int32
	live := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&liveHits, 1)
		_, _ = io.WriteString(w, "LIVE-OK")
	}))
	defer live.Close()
	dead := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
		_, _ = io.WriteString(w, "DEAD")
	}))
	defer dead.Close()

	d := &Downloader{client: &http.Client{}}
	runtime := newFetchTextProbeRuntime(t, d)
	options := map[string]any{
		"url":     dead.URL + "/api/edge/request",
		"mirrors": []any{dead.URL, live.URL},
	}
	result := callFetchText(t, runtime, options)

	bodyText, _ := result["body"].(string)
	if bodyText != "LIVE-OK" {
		t.Fatalf("应回落到活域, got body=%q url=%v", bodyText, result["url"])
	}
	if got := result["url"].(string); !strings.HasPrefix(got, live.URL) {
		t.Fatalf("返回 url 应是活域 %s, got %s", live.URL, got)
	}
	if atomic.LoadInt32(&liveHits) == 0 {
		t.Fatal("活域未被请求")
	}
}

// TestFetchTextBackwardCompat 验证只传 url/referer 时行为不变（GET、任何状态码都返回 body）。
func TestFetchTextBackwardCompat(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet {
			t.Errorf("无 body 应保持 GET, got %s", r.Method)
		}
		w.WriteHeader(http.StatusTeapot)
		_, _ = io.WriteString(w, "BODY-DESPITE-418")
	}))
	defer server.Close()

	d := &Downloader{client: &http.Client{}}
	runtime := newFetchTextProbeRuntime(t, d)
	result := callFetchText(t, runtime, map[string]any{"url": server.URL + "/x", "referer": server.URL + "/"})

	bodyText, _ := result["body"].(string)
	if bodyText != "BODY-DESPITE-418" {
		t.Fatalf("旧行为应返回非 2xx 的 body, got %q", bodyText)
	}
	if int(result["status"].(float64)) != http.StatusTeapot {
		t.Fatalf("status 错误: %v", result["status"])
	}
}

// TestRewriteFetchTextURL 验证镜像换 host 保 path/query。
func TestRewriteFetchTextURL(t *testing.T) {
	got, ok := rewriteFetchTextURL("https://huangguoai.com/api/search?q=a&page=2", "https://thu.agdkczeyx.cc")
	if !ok || got != "https://thu.agdkczeyx.cc/api/search?q=a&page=2" {
		t.Fatalf("rewrite 错误: ok=%v got=%s", ok, got)
	}
	// 非法 mirror 应判 false
	if _, ok := rewriteFetchTextURL("://bad", "https://x.com"); ok {
		t.Fatal("非法 address 应判 false")
	}
}
