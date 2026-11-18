package core

import (
	"context"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestNativeStreamHelpers(t *testing.T) {
	if got := nativeStreamID("abc"); got != nativeStreamID("abc") || got == nativeStreamID("abd") {
		t.Fatalf("nativeStreamID not stable/distinct: %q", got)
	}
	if len(nativeStreamID("abc")) != 12 {
		t.Fatalf("nativeStreamID length = %d", len(nativeStreamID("abc")))
	}
	long := strings.Repeat("s", 60)
	host, target := nativeStreamTarget("https://cdn.example.test/seg/" + long + "/1.ts")
	if host != "cdn.example.test" || strings.Contains(target, long) || !strings.Contains(target, "[redacted-") {
		t.Fatalf("target not redacted: host=%q target=%q", host, target)
	}
	if _, target := nativeStreamTarget("://bad"); target != "invalid" {
		t.Fatalf("invalid address target = %q", target)
	}
	cases := map[error]string{
		context.Canceled:                  "canceled",
		context.DeadlineExceeded:          "deadline",
		io.ErrUnexpectedEOF:               "unexpected_eof",
		&net.DNSError{}:                    "dns",
		&net.OpError{Op: "dial", Err: io.EOF}: "connect",
		errors.New("other"):               "io_error",
	}
	for err, want := range cases {
		if got := nativeStreamError(err); got != want {
			t.Fatalf("nativeStreamError(%v) = %q, want %q", err, got, want)
		}
	}
	if nativeStreamError(nil) != "none" {
		t.Fatal("nil error should be none")
	}
	if nativePlaylistKind("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n") != "master_playlist" {
		t.Fatal("master playlist not detected")
	}
	if nativePlaylistKind("#EXTM3U\n#EXTINF:5,\nseg.ts") != "media_playlist" {
		t.Fatal("media playlist not detected")
	}
}

func TestNativeServeLogsUpstreamStatus(t *testing.T) {
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusGone)
	}))
	defer upstream.Close()
	directory := t.TempDir()
	d := &Downloader{client: http.DefaultClient, cfg: Config{}, diagnostics: newDiagnosticLog(directory)}
	stream, err := newNativeStreamServer(d)
	if err != nil {
		t.Fatalf("stream: %v", err)
	}
	defer stream.server.Close()
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/media.ts", Referer: "https://example.test/"})
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	defer stream.nativeRelease(token)
	response, err := http.Get(address)
	if err != nil {
		t.Fatalf("get proxy: %v", err)
	}
	response.Body.Close()
	data, err := os.ReadFile(filepath.Join(directory, "logs", "app.log"))
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	joined := string(data)
	if !strings.Contains(joined, "stream.upstream_status") {
		t.Fatalf("no upstream_status diagnostic: %s", joined)
	}
	if !strings.Contains(joined, "session=") || strings.Contains(joined, token) {
		t.Fatalf("session should be short-hashed, not raw token: %s", joined)
	}
}

func TestNativeDiagnosticBodyLogsReadError(t *testing.T) {
	directory := t.TempDir()
	d := &Downloader{client: http.DefaultClient, cfg: Config{}, diagnostics: newDiagnosticLog(directory)}
	stream := &nativeStreamServer{downloader: d}
	body := &nativeDiagnosticBody{
		ReadCloser: errReader{},
		stream:     stream,
		info:       nativeStreamDiagnostic{session: "abc", asset: "def"},
		address:    "https://cdn.example.test/seg.ts",
	}
	buffer := make([]byte, 8)
	if _, err := body.Read(buffer); !errors.Is(err, io.ErrUnexpectedEOF) {
		t.Fatalf("read err = %v", err)
	}
	data, err := os.ReadFile(filepath.Join(directory, "logs", "app.log"))
	if err != nil {
		t.Fatalf("read log: %v", err)
	}
	if !strings.Contains(string(data), "stream.upstream_read_error") {
		t.Fatalf("no read error diagnostic: %s", data)
	}
}

type errReader struct{}

func (errReader) Read([]byte) (int, error) { return 0, io.ErrUnexpectedEOF }
func (errReader) Close() error             { return nil }
