package yunzhui

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

// fakeStore 是 provider.Store 的测试实现。
type fakeStore struct{ data map[string][]byte }

func (f *fakeStore) Read(key string) ([]byte, error) { return f.data[key], nil }

func (f *fakeStore) Write(key string, value []byte) error {
	if f.data == nil {
		f.data = map[string][]byte{}
	}
	f.data[key] = value
	return nil
}

// 游客身份必须在首次请求时懒加载：provider 的 Store 由 core 引擎在
// newNativeEngine 里注入，晚于本包 init() 的注册，New() 阶段读盘必然拿不到。
func TestSourceRestoresPersistedIdentityLazily(t *testing.T) {
	provider.SetStore(&fakeStore{data: map[string][]byte{
		storeKey: []byte(`{"device":"0011223344556677","token":"guest-token","tokenAt":1752000000000}`),
	}})
	defer provider.SetStore(nil)

	s := New(provider.Spec{ID: provider.SourceYunzhui})
	if s.device != "" {
		t.Fatalf("identity must not be loaded before the first request, got %q", s.device)
	}
	s.ensureLoaded()
	if s.device != "0011223344556677" {
		t.Fatalf("restored device = %q", s.device)
	}
	if s.token != "guest-token" {
		t.Fatalf("restored token = %q", s.token)
	}
	if s.tokenAt.IsZero() {
		t.Fatal("restored token timestamp lost")
	}

	// 重启语义：新实例必须恢复同一份身份，而不是换新游客。
	restarted := New(provider.Spec{ID: provider.SourceYunzhui})
	restarted.ensureLoaded()
	if restarted.device != s.device {
		t.Fatalf("identity not stable across instances: %q vs %q", restarted.device, s.device)
	}
}

func TestSourceGeneratesDeviceWithoutStore(t *testing.T) {
	provider.SetStore(nil)
	s := New(provider.Spec{ID: provider.SourceYunzhui})
	s.ensureLoaded()
	if len(s.device) != 16 {
		t.Fatalf("generated device %q is not 16 chars", s.device)
	}
	if strings.Trim(s.device, "0123456789abcdef") != "" {
		t.Fatalf("generated device %q is not hex", s.device)
	}
	// 幂等：重复加载不能换设备。
	first := s.device
	s.ensureLoaded()
	if s.device != first {
		t.Fatal("ensureLoaded is not idempotent")
	}
}

func TestPersistAndRestoreRoundTrip(t *testing.T) {
	store := &fakeStore{}
	provider.SetStore(store)
	defer provider.SetStore(nil)

	s := New(provider.Spec{ID: provider.SourceYunzhui})
	s.ensureLoaded()
	s.mu.Lock()
	s.token = "tok-1"
	s.tokenAt = time.UnixMilli(1752000000000)
	s.persistLocked()
	s.mu.Unlock()

	raw, ok := store.data[storeKey]
	if !ok {
		t.Fatal("identity was not persisted")
	}
	var saved map[string]any
	if err := json.Unmarshal(raw, &saved); err != nil {
		t.Fatalf("persisted payload is not json: %v", err)
	}
	if saved["device"] != s.device {
		t.Fatalf("persisted device mismatch: %v", saved["device"])
	}
	if saved["token"] != "tok-1" {
		t.Fatalf("persisted token mismatch: %v", saved["token"])
	}
	if _, ok := saved["tokenAt"]; !ok {
		t.Fatal("token timestamp not persisted")
	}
}

func TestSignIsDeterministicUppercaseHex(t *testing.T) {
	first := sign("0011223344556677", "1752000000000")
	if first != sign("0011223344556677", "1752000000000") {
		t.Fatal("sign is not deterministic")
	}
	if len(first) != 32 {
		t.Fatalf("sign length = %d", len(first))
	}
	if first != strings.ToUpper(first) {
		t.Fatalf("sign %q is not uppercase", first)
	}
	if strings.Trim(first, "0123456789ABCDEF") != "" {
		t.Fatalf("sign %q is not hex", first)
	}
	if sign("0011223344556677", "1752000000001") == first {
		t.Fatal("sign ignores the timestamp")
	}
}

func TestDecryptRoundTrip(t *testing.T) {
	plain := []byte(`{"code":10000,"message":"ok"}`)
	block, err := aes.NewCipher([]byte(aesKey))
	if err != nil {
		t.Fatal(err)
	}
	padded := append(plain, make([]byte, aes.BlockSize-len(plain)%aes.BlockSize)...)
	for i := len(plain); i < len(padded); i++ {
		padded[i] = byte(len(padded) - len(plain))
	}
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, []byte(aesIV)).CryptBlocks(ciphertext, padded)

	got, err := decrypt([]byte(base64.StdEncoding.EncodeToString(ciphertext)))
	if err != nil {
		t.Fatalf("decrypt: %v", err)
	}
	if string(got) != string(plain) {
		t.Fatalf("decrypted = %q", got)
	}

	if _, err := decrypt([]byte("not-base64!!")); err == nil {
		t.Fatal("expected an error for a non-base64 body")
	}
}

func TestMapSort(t *testing.T) {
	cases := map[string]string{
		"heat":  "最热",
		"views": "最热",
		"date":  "日榜",
		"name":  "",
		"":      "",
	}
	for input, want := range cases {
		if got := mapSort(input); got != want {
			t.Fatalf("mapSort(%q) = %q, want %q", input, got, want)
		}
	}
}

func TestSplitTagsAndReleaseStatus(t *testing.T) {
	tags := splitTags("国产, 喜剧/爱情")
	if len(tags) != 3 || tags[0] != "国产" || tags[1] != "喜剧" || tags[2] != "爱情" {
		t.Fatalf("splitTags = %#v", tags)
	}
	if splitTags("  ") != nil {
		t.Fatal("splitTags should return nil for blank input")
	}
	if releaseStatus("1") != "finished" || releaseStatus("0") != "ongoing" {
		t.Fatal("releaseStatus mapping is wrong")
	}
	if releaseStatus("9") != "unknown" {
		t.Fatal("releaseStatus should fall back to unknown")
	}
}

func TestCoverURL(t *testing.T) {
	s := &Source{}
	if got := s.coverURL("http://img.test/a.jpg"); got != "http://img.test/a.jpg" {
		t.Fatalf("absolute url rewritten: %q", got)
	}
	if got := s.coverURL("/upload/a.jpg"); got != imgBase+"upload/a.jpg" {
		t.Fatalf("relative url = %q", got)
	}
	if s.coverURL("   ") != "" {
		t.Fatal("blank cover should stay empty")
	}
}

// TestYunzhuiMediaHasNoReferer guards the CDN behaviour verified on the live
// site: chw.ycblhs.com answers 403 to every non-empty Referer (including its
// own host), and 200 only when the request carries no Referer at all.
func TestYunzhuiMediaHasNoReferer(t *testing.T) {
	medias := buildMedias(map[string]any{
		"m3u8_json": `[{"url":"http://chw.ycblhs.com/vod/m3u8/a/index.m3u8"}]`,
		"vod_url":   "http://chw.ycblhs.com/vod/m3u8/b/index.m3u8",
	})
	if len(medias) != 2 {
		t.Fatalf("expected 2 medias, got %d", len(medias))
	}
	for _, media := range medias {
		if media.Referer != "" {
			t.Fatalf("media %q must not carry a Referer, got %q", media.URL, media.Referer)
		}
	}
}