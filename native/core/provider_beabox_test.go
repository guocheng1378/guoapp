package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

// beaboxEncryptForTest 按站点真实格式加密响应体：hex(IV||CBC(PKCS7(明文)))。
func beaboxEncryptForTest(plain string) (string, error) {
	block, err := aes.NewCipher(beaboxResponseKey)
	if err != nil {
		return "", err
	}
	iv := make([]byte, aes.BlockSize)
	for i := range iv {
		iv[i] = byte(i + 1)
	}
	data := []byte(plain)
	padding := aes.BlockSize - len(data)%aes.BlockSize
	data = append(data, bytes.Repeat([]byte{byte(padding)}, padding)...)
	out := make([]byte, len(data))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, data)
	return hex.EncodeToString(append(iv, out...)), nil
}

// 笔盒是单视频源，不在 duanju provider 注册表里：搜索必须显式分派到
// /vod/search，否则会掉进末尾的本地剧库匹配，站内搜索形同虚设。
func TestBeaboxSearchDispatchesToOnlineVodSearch(t *testing.T) {
	var gotPath, gotKeyword string
	encrypted, err := beaboxEncryptForTest(`{"list":[{"vodId":"9001","vodName":"笔盒搜索命中","vodClass":["短剧"]}],"total":1}`)
	if err != nil {
		t.Fatalf("构造笔盒响应密文失败: %v", err)
	}
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		gotPath = request.URL.Path
		gotKeyword = request.URL.Query().Get("keyword")
		writer.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(writer).Encode(map[string]any{"code": 200, "msg": "ok", "data": encrypted})
	}))
	defer server.Close()

	engine := &nativeEngine{
		directory: t.TempDir(),
		downloader: &Downloader{
			cfg:    Config{BeaboxURL: server.URL},
			client: server.Client(),
		},
		catalogs: map[string][]nativeDrama{
			sourceBeabox: {{ID: "beabox:local", Source: sourceBeabox, Title: "本地旧库命中"}},
		},
	}
	result, err := engine.nativeCatalog(context.Background(), nativeInput{
		Source: sourceBeabox,
		Query:  "样本",
		Page:   1,
	})
	if err != nil {
		t.Fatalf("笔盒在线搜索失败: %v", err)
	}
	if gotPath != "/api/vod/search" {
		t.Fatalf("搜索应请求站内搜索接口 /api/vod/search，实际 %q", gotPath)
	}
	if gotKeyword != "样本" {
		t.Fatalf("搜索关键词未透传到源站: %q", gotKeyword)
	}
	if result.LocalSearch {
		t.Fatal("笔盒已实现在线搜索，不应回落本地剧库匹配")
	}
	if len(result.Items) != 1 || result.Items[0].Title != "笔盒搜索命中" {
		t.Fatalf("在线搜索应返回站内结果: %+v", result.Items)
	}
}

// 笔盒封面是「data:image/...;base64,...」文本，前 4096 字节逐字节 XOR 0x12
// （站点前端 ab() 的默认 key=18）。不还原这段 XOR 就永远判成「无效海报」，
// 列表全是占位图。
func TestBeaboxCoverDataURLDecode(t *testing.T) {
	png, err := hex.DecodeString("89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4890000000a49444154789c6300010000050001" +
		"0d0a2db40000000049454e44ae426082")
	if err != nil {
		t.Fatalf("构造 PNG 失败: %v", err)
	}
	plain := []byte("data:image/png;base64," + base64.StdEncoding.EncodeToString(png))
	blob := append([]byte(nil), plain...)
	for index := 0; index < len(blob) && index < 4096; index++ {
		blob[index] ^= 0x12
	}
	if nativeIsCoverImage(blob) {
		t.Fatal("前置条件不成立：加密后的内容不应直接是图片")
	}
	decoded := nativeDecodeCover(blob)
	if !nativeIsCoverImage(decoded) {
		t.Fatalf("笔盒封面应还原成有效图片，实际 %x", decoded[:min(len(decoded), 8)])
	}
	if !bytes.Equal(decoded, png) {
		t.Fatal("还原结果与原始图片字节不一致")
	}
}

// 非笔盒格式的乱码不能被这条规则误伤。
func TestBeaboxCoverDataURLDecodeIgnoresOtherPayloads(t *testing.T) {
	junk := bytes.Repeat([]byte{0x00, 0x7f, 0x33, 0x80}, 64)
	if decoded := decodeBeaboxDataURLCover(junk); decoded != nil {
		t.Fatal("非 data URL 内容不应被当作笔盒封面解码")
	}
	notBase64 := append([]byte("data:image/png;"), bytes.Repeat([]byte{'v'}, 64)...)
	for index := 0; index < len(notBase64) && index < 4096; index++ {
		notBase64[index] ^= 0x12
	}
	if decoded := decodeBeaboxDataURLCover(notBase64); decoded != nil {
		t.Fatal("缺少 base64 标记的内容不应被解码")
	}
}
