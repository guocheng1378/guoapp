package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"strings"
	"testing"
)

func testKey(t *testing.T) ed25519.PrivateKey {
	t.Helper()
	_, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return priv
}

func TestSignVerifyRoundTrip(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)

	cases := []struct {
		dev  string
		days int
	}{
		{"ABCDE23456", 0},
		{"ABCDEFGH23", 30},
		{"ABCDEFGHJK", 365},
		{"ZGJABC2345", 7},
	}
	for _, c := range cases {
		code, err := SignLicense(priv, c.dev, c.days)
		if err != nil {
			t.Fatalf("Sign(%s,%d): %v", c.dev, c.days, err)
		}
		gotDev, gotDays, err := VerifyLicense(pub, code)
		if err != nil {
			t.Fatalf("Verify(%s,%d): %v", c.dev, c.days, err)
		}
		if gotDev != c.dev || gotDays != c.days {
			t.Fatalf("往返不一致: got dev=%s days=%d, want %s/%d", gotDev, gotDays, c.dev, c.days)
		}
		// 带展示连字符的码也应能验
		gotDev, gotDays, err = VerifyLicense(pub, FormatCode(code))
		if err != nil || gotDev != c.dev || gotDays != c.days {
			t.Fatalf("带连字符验签失败: %v dev=%s days=%d", err, gotDev, gotDays)
		}
	}
}

func TestVerifyTampered(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	code, err := SignLicense(priv, "ABCDE23456", 365)
	if err != nil {
		t.Fatal(err)
	}
	// 改一个字符（替换首个字符为表中另一字符）
	b := []byte(code)
	old := b[0]
	for _, repl := range []byte("BCDEFGH") {
		if repl != old {
			b[0] = repl
			break
		}
	}
	if _, _, err := VerifyLicense(pub, string(b)); err == nil {
		t.Fatal("篡改后的授权码不应通过验签")
	}
	// 错误公钥
	otherPub, _, _ := ed25519.GenerateKey(rand.Reader)
	if _, _, err := VerifyLicense(otherPub, code); err == nil {
		t.Fatal("公钥不匹配时不应通过验签")
	}
	// 截断
	if _, _, err := VerifyLicense(pub, code[:len(code)-8]); err == nil {
		t.Fatal("截断的授权码不应通过验签")
	}
}

func TestParseDevice(t *testing.T) {
	cases := []struct {
		in   string
		want string
		err  bool
	}{
		{"ZGJ-ABCDE-FGHIJ", "ABCDEFGHIJ", false}, // 展示格式 13 位剪前缀
		{"abcdefghij", "ABCDEFGHIJ", false},      // 小写归一（I 是合法 base32 字符）
		{"ABCDEFGH2J", "ABCDEFGH2J", false},      // 本体 10 位直接通过
		{"zgjabcdefgh2j", "ABCDEFGH2J", false},   // 展示格式小写粘贴
		{"ZGJABC2345", "ZGJABC2345", false},      // 本体恰以 ZGJ 开头：10 位不剪
		{"abc", "", true},                        // 太短
		{"ABCDEFGHI", "", true},                  // 9 位
		{"ABC0EFGH2J", "", true},                 // 0 非法
		{"ABC1EFGH2J", "", true},                 // 1 非法
		{"ABC8EFGH2J", "", true},                 // 8 非法
		{"ABC9EFGH2J", "", true},                 // 9 非法
		{"ZGJ-ABCD0-FGHIJ", "", true},            // 展示格式内含 0
	}
	for _, c := range cases {
		got, err := ParseDevice(c.in)
		if c.err {
			if err == nil {
				t.Fatalf("ParseDevice(%q) 应报错，实际返回 %s", c.in, got)
			}
			continue
		}
		if err != nil {
			t.Fatalf("ParseDevice(%q): %v", c.in, err)
		}
		if got != c.want {
			t.Fatalf("ParseDevice(%q) = %s, want %s", c.in, got, c.want)
		}
	}
}

func TestPayloadFormat(t *testing.T) {
	if got := BuildPayload("ABCDE23456", 0); got != "ZGJV1|ABCDE23456|0" {
		t.Fatalf("永久卡载荷异常: %s", got)
	}
	if got := BuildPayload("ABCDE23456", 365); got != "ZGJV1|ABCDE23456|365" {
		t.Fatalf("时间卡载荷异常: %s", got)
	}
}

func TestFormatDevice(t *testing.T) {
	if got := FormatDevice("ABCDEFGH2J"); got != "ZGJ-ABCDE-FGH2J" {
		t.Fatalf("设备码展示格式异常: %s", got)
	}
	if !strings.Contains(FormatCode(strings.Repeat("A", 11)), "AAAAA-") {
		t.Fatal("分组格式异常")
	}
}
