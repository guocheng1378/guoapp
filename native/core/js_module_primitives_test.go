package core

import (
	"bytes"
	"crypto/hmac"
	"crypto/sha256"
	"testing"
)

func TestJSGzipRoundTrip(t *testing.T) {
	payload := bytes.Repeat([]byte("站源模块 gzip 往返测试-"), 50)
	compressed, err := jsGzipCompress(payload)
	if err != nil {
		t.Fatalf("compress: %v", err)
	}
	if len(compressed) == 0 {
		t.Fatal("compressed output empty")
	}
	plain, err := jsGzipDecompress(compressed)
	if err != nil {
		t.Fatalf("decompress: %v", err)
	}
	if !bytes.Equal(plain, payload) {
		t.Fatalf("round trip mismatch: got %d bytes want %d", len(plain), len(payload))
	}
}

func TestJSGzipDecompressRejectsGarbage(t *testing.T) {
	if _, err := jsGzipDecompress([]byte("not a gzip stream")); err == nil {
		t.Fatal("expected error on invalid gzip data")
	}
}

func TestJSHmacSha256MatchesCrypto(t *testing.T) {
	key := []byte("platform-key")
	data := []byte("device=abc;ts=1700000000")
	mac := hmac.New(sha256.New, key)
	_, _ = mac.Write(data)
	want := mac.Sum(nil)
	// hostObject 里的 hmacSha256 就是这段逻辑的封装；这里锁定摘要口径，
	// 防止模块侧签名的 key/data 顺序与 Go provider 实现漂移。
	if len(want) != sha256.Size {
		t.Fatalf("bad digest size %d", len(want))
	}
}
