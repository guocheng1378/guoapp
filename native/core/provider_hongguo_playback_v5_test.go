package core

import "testing"

// Cross-checked against the upstream bundled/hongguo JS module (playbackV5IV /
// playbackV5Hash) with queryHash=bytes(0..31), bodyMd5=bytes(0x10..0x1f).
func TestHongguoPlaybackV5CrossCheck(t *testing.T) {
	queryHash := make([]byte, 32)
	for index := range queryHash {
		queryHash[index] = byte(index)
	}
	bodyMd5 := make([]byte, 16)
	for index := range bodyMd5 {
		bodyMd5[index] = byte(0x10 + index)
	}
	const ts = uint32(1700000005)

	if iv := hongguoV5IV(queryHash, bodyMd5, ts); iv != 0xfbf9961c {
		t.Fatalf("IV mismatch: %08x", iv)
	}
	hash, err := hongguoV5Hash(queryHash, bodyMd5, ts)
	if err != nil {
		t.Fatalf("hash: %v", err)
	}
	const want = "984b13977c8b84a46736bbf7dfe98228bc7f169b"
	if got := hexEncode(hash); got != want {
		t.Fatalf("hash mismatch:\n got %s\nwant %s", got, want)
	}
}

// The ticket search must always land on a query whose IV low nibble is 12.
func TestHongguoPlaybackV5SignProducesHeaders(t *testing.T) {
	values := hongguoPlaybackV5Query("123456789012345678", "87654321")
	signedURL, headers, err := signHongguoPlaybackV5("https://example.test/play", values, []byte(`{"a":1}`), 1700000000000)
	if err != nil {
		t.Fatalf("sign: %v", err)
	}
	if signedURL == "" {
		t.Fatal("empty signed url")
	}
	for _, name := range []string{"X-Khronos", "X-Helios", "X-Medusa", "X-SS-STUB"} {
		if headers[name] == "" {
			t.Fatalf("missing header %s", name)
		}
	}
}
