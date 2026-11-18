package core

import (
	"bytes"
	"encoding/base64"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

// jsBinaryProbeScript 在 JS 侧构造二进制载荷，分别经 host.fetch / host.fetchText 发出，
// 把响应的 bodyBase64 回传给 Go 断言（body 字符串对含 0xff 的响应是有损的）。
const jsBinaryProbeScript = `
module.exports = {
	fetchBytes: function (url) {
		var payload = new Uint8Array([0x7f, 0x80, 0x81, 0xff, 0x00, 0x01]);
		var r = host.fetch({ method: "POST", url: url, headers: {}, body: payload });
		return { body: r.body, bodyBase64: r.bodyBase64, status: r.status };
	},
	fetchBuffer: function (url) {
		var buffer = new ArrayBuffer(4);
		var view = new Uint8Array(buffer);
		view[0] = 0xde; view[1] = 0xad; view[2] = 0xbe; view[3] = 0xef;
		var r = host.fetch({ method: "POST", url: url, headers: {}, body: buffer });
		return { bodyBase64: r.bodyBase64, status: r.status };
	},
	fetchTextBytes: function (url) {
		var payload = new Uint8Array([0x7f, 0x80, 0x81, 0xff, 0x00, 0x01]);
		var r = host.fetchText({ url: url, body: payload, headers: {} });
		return { body: r.body, bodyBase64: r.bodyBase64, status: r.status };
	},
	fetchString: function (url) {
		var r = host.fetch({ method: "POST", url: url, headers: {}, body: "abc" });
		return { bodyBase64: r.bodyBase64, status: r.status };
	},
};
`

func newBinaryProbeRuntime(t *testing.T) *jsModuleRuntime {
	t.Helper()
	manifest := JSModuleManifest{ID: "binprobe", Name: "二进制探针", Version: "1.0.0", API: 1}
	runtime, err := newJSModuleRuntime(&Downloader{client: &http.Client{}}, manifest, jsBinaryProbeScript)
	if err != nil {
		t.Fatalf("runtime load: %v", err)
	}
	return runtime
}

func callBinaryProbe(t *testing.T, runtime *jsModuleRuntime, function, url string) map[string]any {
	t.Helper()
	var result map[string]any
	if err := runtime.call(nil, nil, function, &result, url); err != nil {
		t.Fatalf("%s call: %v", function, err)
	}
	return result
}

// newBinaryEchoServer 记录请求原始字节，回包是 "pong " + 请求字节（含 0xff）。
func newBinaryEchoServer(t *testing.T, got *[]byte) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		*got, _ = io.ReadAll(r.Body)
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(append([]byte("pong "), *got...))
	}))
}

func TestModuleFetchBinaryBody(t *testing.T) {
	want := []byte{0x7f, 0x80, 0x81, 0xff, 0x00, 0x01}
	var got []byte
	server := newBinaryEchoServer(t, &got)
	defer server.Close()

	result := callBinaryProbe(t, newBinaryProbeRuntime(t), "fetchBytes", server.URL+"/x")
	if !bytes.Equal(got, want) {
		t.Fatalf("请求体 = %x, want %x", got, want)
	}
	wantBase64 := base64.StdEncoding.EncodeToString(append([]byte("pong "), want...))
	if value, _ := result["bodyBase64"].(string); value != wantBase64 {
		t.Fatalf("bodyBase64 = %q, want %q", value, wantBase64)
	}
	if status, _ := result["status"].(float64); int(status) != http.StatusOK {
		t.Fatalf("status = %v", result["status"])
	}
}

func TestModuleFetchArrayBufferBody(t *testing.T) {
	want := []byte{0xde, 0xad, 0xbe, 0xef}
	var got []byte
	server := newBinaryEchoServer(t, &got)
	defer server.Close()

	result := callBinaryProbe(t, newBinaryProbeRuntime(t), "fetchBuffer", server.URL+"/x")
	if !bytes.Equal(got, want) {
		t.Fatalf("请求体 = %x, want %x", got, want)
	}
	wantBase64 := base64.StdEncoding.EncodeToString(append([]byte("pong "), want...))
	if value, _ := result["bodyBase64"].(string); value != wantBase64 {
		t.Fatalf("bodyBase64 = %q, want %q", value, wantBase64)
	}
}

func TestModuleFetchTextBinaryBody(t *testing.T) {
	want := []byte{0x7f, 0x80, 0x81, 0xff, 0x00, 0x01}
	var got []byte
	server := newBinaryEchoServer(t, &got)
	defer server.Close()

	result := callBinaryProbe(t, newBinaryProbeRuntime(t), "fetchTextBytes", server.URL+"/x")
	if !bytes.Equal(got, want) {
		t.Fatalf("请求体 = %x, want %x", got, want)
	}
	wantBase64 := base64.StdEncoding.EncodeToString(append([]byte("pong "), want...))
	if value, _ := result["bodyBase64"].(string); value != wantBase64 {
		t.Fatalf("bodyBase64 = %q, want %q", value, wantBase64)
	}
}

func TestModuleFetchStringBodyBackwardCompat(t *testing.T) {
	var got []byte
	server := newBinaryEchoServer(t, &got)
	defer server.Close()

	result := callBinaryProbe(t, newBinaryProbeRuntime(t), "fetchString", server.URL+"/x")
	if string(got) != "abc" {
		t.Fatalf("字符串 body 被改动: %q", got)
	}
	wantBase64 := base64.StdEncoding.EncodeToString([]byte("pong abc"))
	if value, _ := result["bodyBase64"].(string); value != wantBase64 {
		t.Fatalf("bodyBase64 = %q, want %q", value, wantBase64)
	}
}
