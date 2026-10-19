// licensegen —— 真果·鉴离线授权码生成工具。
//
// 用法:
//
//	licensegen          无参数进入交互模式（双击 exe 即此模式：菜单选卡 → 粘设备码 → 出码）
//	licensegen init     初始化 Ed25519 密钥对（首次运行，私钥落盘本目录）
//	licensegen pub      打印公钥（base64，用于回填 App 端常量）
//	licensegen gen -device ZGJ-XXXXX-XXXXX -type permanent|d30|d90|d365 [-days N]
//
// 授权码格式: base32( payload || ed25519签名64B )，payload = "ZGJV1|{设备码10位}|{天数0=永久}"
package main

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const payloadVersion = "ZGJV1"

const keyFileName = "licensegen.private.key"

// RFC4648 base32（A-Z2-7），无 padding。
var b32 = base32.StdEncoding.WithPadding(base32.NoPadding)

var deviceRe = regexp.MustCompile(`^[A-Z2-7]{10}$`)

var typeDurations = map[string]int{
	"permanent": 0,
	"d30":       30,
	"d90":       90,
	"d365":      365,
}

func main() {
	if len(os.Args) < 2 {
		// 双击 exe / 无参数：交互模式（窗口保持打开，防“闪退”观感）
		if err := runInteractive(os.Stdin, os.Stdout, os.Stderr); err != nil {
			fail(err)
		}
		return
	}
	switch os.Args[1] {
	case "init":
		if err := cmdInit(); err != nil {
			fail(err)
		}
	case "pub":
		if err := cmdPub(); err != nil {
			fail(err)
		}
	case "gen":
		if err := cmdGen(os.Args[2:]); err != nil {
			fail(err)
		}
	default:
		usage()
		os.Exit(2)
	}
}

func usage() {
	fmt.Fprintln(os.Stderr, "用法:")
	fmt.Fprintln(os.Stderr, "  licensegen        交互模式（双击 exe 即此模式）")
	fmt.Fprintln(os.Stderr, "  licensegen init   初始化密钥对（首次运行）")
	fmt.Fprintln(os.Stderr, "  licensegen pub    打印公钥 base64（回填 App 端 license_pubkey.dart）")
	fmt.Fprintln(os.Stderr, "  licensegen gen -device ZGJ-XXXXX-XXXXX -type permanent|d30|d90|d365 [-days N]")
}

func fail(err error) {
	fmt.Fprintln(os.Stderr, "错误:", err)
	os.Exit(1)
}

// keyPath 私钥文件路径（工具所在目录，与 exe 同级或工作目录均可，取可执行文件目录优先）。
func keyPath() string {
	exe, err := os.Executable()
	if err == nil {
		p := filepath.Join(filepath.Dir(exe), keyFileName)
		if _, statErr := os.Stat(p); statErr == nil {
			return p
		}
	}
	wd, _ := os.Getwd()
	return filepath.Join(wd, keyFileName)
}

// loadPrivateKey 读取私钥；不存在则报错（提示先 init）。
func loadPrivateKey() (ed25519.PrivateKey, error) {
	data, err := os.ReadFile(keyPath())
	if err != nil {
		return nil, fmt.Errorf("私钥文件不存在（%s），请先运行 licensegen init", keyPath())
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(data)))
	if err != nil {
		return nil, fmt.Errorf("私钥文件损坏: %w", err)
	}
	if len(raw) != ed25519.PrivateKeySize {
		return nil, errors.New("私钥长度异常（应为 64 字节）")
	}
	return ed25519.PrivateKey(raw), nil
}

func cmdInit() error {
	p := keyPath()
	if _, err := os.ReadFile(p); err == nil {
		// 已存在：不覆盖（防手滑作废所有已发授权），直接打印公钥。
		priv, loadErr := loadPrivateKey()
		if loadErr != nil {
			return loadErr
		}
		fmt.Println("私钥已存在，未改动:", p)
		printPubInfo(priv.Public().(ed25519.PublicKey))
		return nil
	}
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return err
	}
	if err := os.WriteFile(p, []byte(base64.StdEncoding.EncodeToString(priv)+"\n"), 0o600); err != nil {
		return err
	}
	fmt.Println("密钥对已生成，私钥:", p)
	fmt.Println("⚠ 私钥丢失或泄露都无法补救：请立即备份到安全位置，且不要提交到 git。")
	printPubInfo(pub)
	return nil
}

func printPubInfo(pub ed25519.PublicKey) {
	b64 := base64.StdEncoding.EncodeToString(pub)
	fmt.Println("公钥(base64):", b64)
	fmt.Println("App 端常量（lib/activation/license_pubkey.dart）:")
	fmt.Printf("const String licensePublicKeyB64 = '%s';\n", b64)
}

func cmdPub() error {
	priv, err := loadPrivateKey()
	if err != nil {
		return err
	}
	pub := priv.Public().(ed25519.PublicKey)
	fmt.Println(base64.StdEncoding.EncodeToString(pub))
	return nil
}

func cmdGen(args []string) error {
	fs := flag.NewFlagSet("gen", flag.ExitOnError)
	device := fs.String("device", "", "买家设备码，如 ZGJ-ABCDE-FGHIJ 或 ABCDEFGHIJ")
	kind := fs.String("type", "", "卡类型: permanent / d30 / d90 / d365")
	days := fs.Int("days", 0, "自定义天数（覆盖 -type，>0 生效）")
	raw := fs.Bool("raw", false, "输出不带连字符的整行授权码（便于复制）")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *device == "" {
		return errors.New("缺少 -device 参数")
	}
	dev, err := ParseDevice(*device)
	if err != nil {
		return err
	}
	duration := 0
	if *days > 0 {
		duration = *days
	} else {
		var ok bool
		if duration, ok = typeDurations[strings.ToLower(strings.TrimSpace(*kind))]; !ok {
			return fmt.Errorf("无效 -type %q（可选 permanent/d30/d90/d365，或用 -days 指定天数）", *kind)
		}
	}
	priv, err := loadPrivateKey()
	if err != nil {
		return err
	}
	code, err := SignLicense(priv, dev, duration)
	if err != nil {
		return err
	}
	if *raw {
		fmt.Println(code)
		return nil
	}
	label := "永久卡"
	if duration > 0 {
		label = fmt.Sprintf("%d 天卡", duration)
	}
	fmt.Printf("设备 %s · %s\n", FormatDevice(dev), label)
	fmt.Println("授权码（整行复制发给买家）:")
	fmt.Println(FormatCode(code))
	return nil
}

// ParseDevice 清洗买家提供的设备码：去连字符/空格/前缀，校验 10 位 base32。
func ParseDevice(s string) (string, error) {
	var b strings.Builder
	for _, r := range strings.ToUpper(s) {
		if (r >= 'A' && r <= 'Z') || (r >= '2' && r <= '7') {
			b.WriteRune(r)
		} else if r >= '0' && r <= '9' {
			// base32 表内数字只有 2-7；出现 0/1/8/9 说明复制进了其他内容
			return "", fmt.Errorf("设备码包含非法字符 %q", string(r))
		}
	}
	dev := b.String()
	if len(dev) == 13 && strings.HasPrefix(dev, "ZGJ") {
		// 展示格式 ZGJ-XXXXX-XXXXX 清洗后 13 位，剪掉品牌前缀
		dev = dev[3:]
	}
	if !deviceRe.MatchString(dev) {
		return "", fmt.Errorf("设备码格式错误（应为 10 位字母数字，实际 %d 位: %s）", len(dev), dev)
	}
	return dev, nil
}

// BuildPayload 构造待签载荷: "ZGJV1|{设备码}|{天数}"
func BuildPayload(dev string, durationDays int) string {
	return payloadVersion + "|" + dev + "|" + strconv.Itoa(durationDays)
}

// SignLicense 签发授权码 = base32(payload || sig64)。
func SignLicense(priv ed25519.PrivateKey, dev string, durationDays int) (string, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return "", errors.New("私钥长度异常")
	}
	if !deviceRe.MatchString(dev) {
		return "", errors.New("设备码格式错误")
	}
	if durationDays < 0 {
		return "", errors.New("天数不能为负")
	}
	payload := BuildPayload(dev, durationDays)
	sig := ed25519.Sign(priv, []byte(payload))
	return b32.EncodeToString(append([]byte(payload), sig...)), nil
}

// VerifyLicense 工具侧自验（与 App 端算法一致，用于自检/测试）。
func VerifyLicense(pub ed25519.PublicKey, code string) (dev string, durationDays int, err error) {
	raw, err := b32.DecodeString(normalizeCode(code))
	if err != nil {
		return "", 0, fmt.Errorf("授权码编码非法: %w", err)
	}
	if len(raw) <= ed25519.SignatureSize {
		return "", 0, errors.New("授权码过短")
	}
	split := len(raw) - ed25519.SignatureSize
	payload, sig := raw[:split], raw[split:]
	if !ed25519.Verify(pub, payload, sig) {
		return "", 0, errors.New("签名校验失败")
	}
	parts := strings.Split(string(payload), "|")
	if len(parts) != 3 || parts[0] != payloadVersion {
		return "", 0, errors.New("载荷版本不识别")
	}
	if !deviceRe.MatchString(parts[1]) {
		return "", 0, errors.New("载荷中设备码非法")
	}
	days, convErr := strconv.Atoi(parts[2])
	if convErr != nil || days < 0 {
		return "", 0, errors.New("载荷中天数非法")
	}
	return parts[1], days, nil
}

// normalizeCode 去掉展示用连字符与空白、转大写。
func normalizeCode(s string) string {
	var b strings.Builder
	for _, r := range strings.ToUpper(s) {
		if (r >= 'A' && r <= 'Z') || (r >= '2' && r <= '7') {
			b.WriteRune(r)
		}
	}
	return b.String()
}

// FormatCode 每 5 字符一组连字符分隔，便于阅读与核对。
func FormatCode(code string) string {
	clean := normalizeCode(code)
	var groups []string
	for i := 0; i < len(clean); i += 5 {
		end := i + 5
		if end > len(clean) {
			end = len(clean)
		}
		groups = append(groups, clean[i:end])
	}
	return strings.Join(groups, "-")
}

// FormatDevice 展示设备码: ZGJ-XXXXX-XXXXX
func FormatDevice(dev string) string {
	if len(dev) != 10 {
		return dev
	}
	return "ZGJ-" + dev[:5] + "-" + dev[5:]
}
