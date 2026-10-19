package main

import (
	"bufio"
	"crypto/ed25519"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"
)

// errQuit 用户在交互模式里主动退出。
var errQuit = errors.New("quit")

// runInteractive 双击 exe / 无参数启动时的交互模式：
// 菜单选卡类型 → 粘贴设备码 → 输出授权码 → 可连续签发，最后等回车再关窗（防闪退）。
func runInteractive(in io.Reader, out, errw io.Writer) error {
	fmt.Fprintln(out, "==============================")
	fmt.Fprintln(out, "  真果·鉴 授权码生成工具")
	fmt.Fprintln(out, "==============================")
	priv, err := loadPrivateKey()
	if err != nil {
		fmt.Fprintln(errw, "✗ "+err.Error())
		fmt.Fprintln(out)
		fmt.Fprint(out, "按回车键退出...")
		waitEnter(bufio.NewReader(in))
		return nil
	}
	reader := bufio.NewReader(in)
	interactLoop(reader, out, errw, priv)
	return nil
}

// interactForTest 测试注入私钥的入口。
func interactForTest(in io.Reader, out, errw io.Writer, priv ed25519.PrivateKey) error {
	interactLoop(bufio.NewReader(in), out, errw, priv)
	return nil
}

func interactLoop(reader *bufio.Reader, out, errw io.Writer, priv ed25519.PrivateKey) {
	fmt.Fprintln(out, "密钥已就绪。")
	for {
		code, issueErr := issueOnce(reader, out, priv)
		if issueErr != nil {
			if errors.Is(issueErr, errQuit) {
				break
			}
			fmt.Fprintln(errw)
			fmt.Fprintln(errw, "✗ 签发失败:", issueErr)
			fmt.Fprintln(out)
			fmt.Fprint(out, "回车重新开始；输入 q 退出: ")
			if !askContinue(reader, out) {
				break
			}
			fmt.Fprintln(out)
			continue
		}
		fmt.Fprintln(out)
		fmt.Fprintln(out, ">>> 授权码（整行复制发给买家）:")
		fmt.Fprintln(out)
		fmt.Fprintln(out, FormatCode(code))
		fmt.Fprintln(out)
		fmt.Fprint(out, "继续签发下一张请回车；输入 q 退出: ")
		if !askContinue(reader, out) {
			break
		}
		fmt.Fprintln(out)
	}
	fmt.Fprintln(out)
	fmt.Fprint(out, "已退出。按回车键关闭窗口...")
	waitEnter(reader)
}

// askContinue 读一行：空行/回车 = true 继续；q/quit/exit/n = false 退出；EOF 也退出。
func askContinue(r *bufio.Reader, out io.Writer) bool {
	for {
		line, ok := readLine(r)
		if !ok {
			return false
		}
		switch strings.ToLower(line) {
		case "":
			return true
		case "q", "quit", "exit", "n":
			return false
		default:
			fmt.Fprintln(out, "（回车继续，或输入 q 退出）")
			fmt.Fprint(out, "> ")
		}
	}
}

// issueOnce 一轮签发：选卡类型 → 读设备码 → 签名。
func issueOnce(r *bufio.Reader, out io.Writer, priv ed25519.PrivateKey) (string, error) {
	fmt.Fprintln(out, "请选择卡类型:")
	fmt.Fprintln(out, "  1) 永久卡")
	fmt.Fprintln(out, "  2) 30 天卡")
	fmt.Fprintln(out, "  3) 90 天卡")
	fmt.Fprintln(out, "  4) 365 天卡")
	fmt.Fprintln(out, "  5) 自定义天数")
	fmt.Fprintln(out, "  q) 退出")
	fmt.Fprint(out, "输入数字后回车: ")
	line, ok := readLine(r)
	if !ok {
		return "", errQuit
	}
	duration := 0
	switch strings.TrimSpace(line) {
	case "1":
	case "2":
		duration = 30
	case "3":
		duration = 90
	case "4":
		duration = 365
	case "5":
		fmt.Fprint(out, "输入天数（正整数）: ")
		days, ok := readLine(r)
		if !ok {
			return "", errQuit
		}
		n, err := strconv.Atoi(strings.TrimSpace(days))
		if err != nil || n <= 0 {
			return "", fmt.Errorf("天数无效: %q", days)
		}
		if n > 36500 {
			return "", fmt.Errorf("天数过大: %d", n)
		}
		duration = n
	case "q", "quit", "exit", "0":
		return "", errQuit
	default:
		return "", fmt.Errorf("无效选择 %q（请输入 1-5）", line)
	}

	fmt.Fprint(out, "粘贴买家发来的设备码（ZGJ-XXXXX-XXXXX 或 10 位连续均可）: ")
	devInput, ok := readLine(r)
	if !ok {
		return "", errQuit
	}
	dev, err := ParseDevice(devInput)
	if err != nil {
		return "", err
	}
	code, err := SignLicense(priv, dev, duration)
	if err != nil {
		return "", err
	}
	label := "永久卡"
	if duration > 0 {
		label = fmt.Sprintf("%d 天卡", duration)
	}
	fmt.Fprintf(out, "✓ 设备 %s · %s", FormatDevice(dev), label)
	return code, nil
}

// readLine 读一行并去首尾空白与 BOM；流结束返回 ok=false（防无限循环）。
func readLine(r *bufio.Reader) (string, bool) {
	line, err := r.ReadString('\n')
	trimmed := strings.TrimSpace(line)
	trimmed = strings.ReplaceAll(trimmed, "\uFEFF", "") // 粘贴/管道可能夹带 BOM
	if err != nil && trimmed == "" {
		return "", false // EOF 且无内容
	}
	return trimmed, true
}

func waitEnter(r *bufio.Reader) {
	_, _ = r.ReadString('\n')
}
