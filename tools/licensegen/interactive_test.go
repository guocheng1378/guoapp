package main

import (
	"bytes"
	"crypto/ed25519"
	"regexp"
	"strings"
	"testing"
)

// 最后一组可能不足 5 字符（148 字符码按 5 分组余 3）。
var codeTokenRe = regexp.MustCompile(`^[A-Z2-7]{5}(-[A-Z2-7]{1,5})+$`)

// extractCode 从交互输出里取最长的授权码 token（设备码/选项均为短 token，不会误取）。
func extractCode(out string) string {
	longest := ""
	for _, field := range strings.Fields(out) {
		if codeTokenRe.MatchString(field) && len(field) > len(longest) {
			longest = field
		}
	}
	return strings.ReplaceAll(longest, "-", "")
}

func runInteract(t *testing.T, priv ed25519.PrivateKey, input string) string {
	t.Helper()
	var out, errw bytes.Buffer
	reader := strings.NewReader(input)
	if err := interactForTest(reader, &out, &errw, priv); err != nil {
		t.Fatalf("interact 返回错误: %v", err)
	}
	return out.String() + errw.String()
}

func TestInteractiveIssuePermanent(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	out := runInteract(t, priv, "1\nZGJ-ABCDE-FGHIJ\nq\n")
	if !strings.Contains(out, "永久卡") || !strings.Contains(out, "授权码") {
		t.Fatalf("输出缺少签发信息:\n%s", out)
	}
	if !strings.Contains(out, "ZGJ-ABCDE-FGHIJ") {
		t.Fatalf("输出未回显设备码:\n%s", out)
	}
	code := extractCode(out)
	if code == "" {
		t.Fatalf("未从输出提取到授权码:\n%s", out)
	}
	dev, days, err := VerifyLicense(pub, code)
	if err != nil || dev != "ABCDEFGHIJ" || days != 0 {
		t.Fatalf("交互签发的码验签失败: err=%v dev=%s days=%d", err, dev, days)
	}
}

func TestInteractiveCustomDays(t *testing.T) {
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	out := runInteract(t, priv, "5\n45\nzzzzz23456\nq\n")
	code := extractCode(out)
	dev, days, err := VerifyLicense(pub, code)
	if err != nil || dev != "ZZZZZ23456" || days != 45 {
		t.Fatalf("自定义天数签发异常: err=%v dev=%s days=%d\n%s", err, dev, days, out)
	}
}

func TestInteractiveInvalidDevice(t *testing.T) {
	priv := testKey(t)
	out := runInteract(t, priv, "1\nABC0EFGH2J\nq\n")
	if !strings.Contains(out, "签发失败") || !strings.Contains(out, "非法字符") {
		t.Fatalf("无效设备码未报错:\n%s", out)
	}
	if code := extractCode(out); code != "" {
		t.Fatalf("失败时不应产生授权码:\n%s", out)
	}
}

func TestInteractiveInvalidChoice(t *testing.T) {
	priv := testKey(t)
	out := runInteract(t, priv, "x\nq\n")
	if !strings.Contains(out, "无效选择") {
		t.Fatalf("无效选项未报错:\n%s", out)
	}
}

func TestInteractiveEOFExits(t *testing.T) {
	// 空输入（EOF）：应直接退出，不能死循环或 panic。
	priv := testKey(t)
	out := runInteract(t, priv, "")
	if out == "" {
		t.Fatal("EOF 时也应打印界面文字")
	}
}

func TestInteractiveConsecutiveIssues(t *testing.T) {
	// 连续签发两张（回车继续）再退出。
	priv := testKey(t)
	pub := priv.Public().(ed25519.PublicKey)
	out := runInteract(t, priv, "1\nAAAAAAAAAA\n\n2\nBBBBBBBBBB\nq\n")
	codes := make([]string, 0, 2)
	for _, field := range strings.Fields(out) {
		if codeTokenRe.MatchString(field) {
			codes = append(codes, strings.ReplaceAll(field, "-", ""))
		}
	}
	if len(codes) < 2 {
		t.Fatalf("连续签发应产生两张码，实际 %d:\n%s", len(codes), out)
	}
	dev1, days1, err := VerifyLicense(pub, codes[len(codes)-2])
	if err != nil || dev1 != "AAAAAAAAAA" || days1 != 0 {
		t.Fatalf("第一张码异常: err=%v dev=%s days=%d", err, dev1, days1)
	}
	dev2, days2, err := VerifyLicense(pub, codes[len(codes)-1])
	if err != nil || dev2 != "BBBBBBBBBB" || days2 != 30 {
		t.Fatalf("第二张码异常: err=%v dev=%s days=%d", err, dev2, days2)
	}
}
