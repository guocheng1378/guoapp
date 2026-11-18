package core

import (
	"bytes"
	"encoding/base64"
	"testing"
)

// TestDecodeModuleBase64NoPadding 是黄果 AI 播放握手失败的回归护栏：
// Go 的 StdEncoding.DecodeString 对无 padding 输入不报错、只解出截断字节，
// 曾导致 65 字节 P-256 公钥被解成 63 字节、ECDH 协商失败→握手失败→
// 「有目录、点播放没画面」。host.base64Decode 必须补齐 padding。
func TestDecodeModuleBase64NoPadding(t *testing.T) {
	raw := bytes.Repeat([]byte{0x04, 0xB1, 0x2C}, 21) // 63 字节样本
	standard := base64.StdEncoding.EncodeToString(raw)
	noPad := bytes.TrimRight([]byte(standard), "=")
	urlSafe := bytes.NewBuffer(nil)
	for _, b := range noPad {
		switch b {
		case '+':
			urlSafe.WriteByte('-')
		case '/':
			urlSafe.WriteByte('_')
		default:
			urlSafe.WriteByte(b)
		}
	}

	for name, input := range map[string]string{
		"standard":       standard,
		"no-padding":     string(noPad),
		"urlsafe-no-pad": urlSafe.String(),
	} {
		got, err := decodeModuleBase64(input)
		if err != nil {
			t.Fatalf("%s: 解码失败: %v", name, err)
		}
		if !bytes.Equal(got, raw) {
			t.Fatalf("%s: 解出 %d 字节，期望 %d 字节且内容一致", name, len(got), len(raw))
		}
	}

	// 真实场景：43 字符无 padding 的 base64url 应解出 32 字节盐。
	salt := "NH49QSf1C3SNiJjjux9miFtbofgO1JA2_czJq4gWX1Q"
	got, err := decodeModuleBase64(salt)
	if err != nil || len(got) != 32 {
		t.Fatalf("盐解码错误：len=%d err=%v（期望 32 字节）", len(got), err)
	}
	if _, err := decodeModuleBase64("A"); err == nil {
		t.Fatal("长度余 1 的非法输入必须报错")
	}
}
