package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/pbkdf2"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
)

// 云备份（WebDAV）：Dart 把全量快照 JSON 交上来，这里负责加密信封与
// WebDAV 传输；备份内容语义（schema、恢复、合并）由 Dart 侧负责。
//
// 信封布局： "DJBK" | version(1) | salt(16) | nonce(12) | AES-256-GCM 密文
// AAD 为信封头（magic+version）；
// 密钥 = PBKDF2-HMAC-SHA256(备份密码, 盐, 200000, 32)。

const (
	webdavBackupMagic   = "DJBK"
	webdavBackupVersion = 1
	webdavBackupLimit   = 64 << 20 // 与 LocalStore.exportBackup 的 64 MiB 上限对齐
	webdavSaltLen       = 16
	webdavNonceLen      = 12
	webdavIterations    = 200000
)

type nativeWebDAVInput struct {
	URL            string `json:"url"`
	Username       string `json:"username"`
	Password       string `json:"password"`       // WebDAV 账号密码
	BackupPassword string `json:"backupPassword"` // 备份加密密码
	Data           string `json:"data"`           // upload：明文备份 JSON
}

type webdavTestResult struct {
	Reachable bool   `json:"reachable"`
	Exists    bool   `json:"exists"`
	Size      int64  `json:"size,omitempty"`
	Modified  string `json:"modified,omitempty"`
}

type webdavUploadResult struct {
	OK   bool `json:"ok"`
	Size int  `json:"size"`
}

type webdavDownloadResult struct {
	Exists bool   `json:"exists"`
	Size   int    `json:"size,omitempty"`
	Data   string `json:"data,omitempty"`
}

func nativeWebDAV(ctx context.Context, command string, raw json.RawMessage) (any, error) {
	var input nativeWebDAVInput
	if len(raw) == 0 || json.Unmarshal(raw, &input) != nil {
		return nil, errors.New("云备份请求无效")
	}
	input.URL = strings.TrimSpace(input.URL)
	input.Username = strings.TrimSpace(input.Username)
	if input.URL == "" {
		return nil, errors.New("请先填写 WebDAV 服务器地址")
	}
	if !strings.HasPrefix(input.URL, "http://") && !strings.HasPrefix(input.URL, "https://") {
		return nil, errors.New("服务器地址必须以 http:// 或 https:// 开头")
	}
	client := &http.Client{}
	switch command {
	case "test":
		return webdavTest(ctx, client, input)
	case "upload":
		return webdavUpload(ctx, client, input)
	case "download":
		return webdavDownload(ctx, client, input)
	}
	return nil, fmt.Errorf("未知的云备份命令 %q", command)
}

var (
	webdavLengthRe   = regexp.MustCompile(`(?i)<[^>]*getcontentlength[^>]*>\s*(\d+)\s*<`)
	webdavModifiedRe = regexp.MustCompile(`(?i)<[^>]*getlastmodified[^>]*>\s*([^<]+?)\s*<`)
)

func webdavTest(ctx context.Context, client *http.Client, input nativeWebDAVInput) (any, error) {
	resp, err := webdavRequest(ctx, client, "PROPFIND", input.URL, input, nil)
	if err != nil {
		return nil, err
	}
	body, _ := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusMultiStatus:
		result := webdavTestResult{Reachable: true, Exists: true}
		if m := webdavLengthRe.FindSubmatch(body); m != nil {
			result.Size, _ = strconv.ParseInt(string(m[1]), 10, 64)
		}
		if m := webdavModifiedRe.FindSubmatch(body); m != nil {
			result.Modified = strings.TrimSpace(string(m[1]))
		}
		return result, nil
	case resp.StatusCode == http.StatusNotFound:
		// 还没备份过：探一下父目录，确认目录级访问与鉴权没问题
		if dirs := webdavParentDirs(input.URL); len(dirs) > 0 {
			r2, err := webdavRequest(ctx, client, "PROPFIND", dirs[len(dirs)-1], input, nil)
			if err != nil {
				return nil, err
			}
			io.Copy(io.Discard, io.LimitReader(r2.Body, 4096))
			r2.Body.Close()
			if r2.StatusCode == http.StatusUnauthorized {
				return nil, errors.New("WebDAV 账号或密码不正确（HTTP 401）")
			}
		}
		return webdavTestResult{Reachable: true}, nil
	case resp.StatusCode == http.StatusUnauthorized:
		return nil, errors.New("WebDAV 账号或密码不正确（HTTP 401）")
	case resp.StatusCode == http.StatusForbidden:
		return nil, errors.New("服务器拒绝了访问（HTTP 403），请检查账号权限")
	}
	return nil, fmt.Errorf("服务器返回 HTTP %d", resp.StatusCode)
}

func webdavUpload(ctx context.Context, client *http.Client, input nativeWebDAVInput) (any, error) {
	if input.BackupPassword == "" {
		return nil, errors.New("请输入备份密码")
	}
	plain := []byte(input.Data)
	if len(plain) == 0 {
		return nil, errors.New("备份内容为空，请稍后重试")
	}
	if len(plain) > webdavBackupLimit {
		return nil, errors.New("备份超过 64 MiB 上限，请先整理记录")
	}
	envelope, err := webdavSeal(plain, input.BackupPassword)
	if err != nil {
		return nil, err
	}
	if err := webdavPut(ctx, client, input, envelope); err != nil {
		if !errors.Is(err, errWebdavMissingParent) {
			return nil, err
		}
		// 父目录不存在：逐级建目录后重试一次
		webdavMkdirAll(ctx, client, input)
		if err := webdavPut(ctx, client, input, envelope); err != nil {
			return nil, err
		}
	}
	return webdavUploadResult{OK: true, Size: len(envelope)}, nil
}

var errWebdavMissingParent = errors.New("父目录不存在")

func webdavPut(ctx context.Context, client *http.Client, input nativeWebDAVInput, envelope []byte) error {
	resp, err := webdavRequest(ctx, client, "PUT", input.URL, input, envelope)
	if err != nil {
		return err
	}
	io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	resp.Body.Close()
	switch {
	case resp.StatusCode/100 == 2:
		return nil
	case resp.StatusCode == http.StatusConflict:
		return errWebdavMissingParent
	case resp.StatusCode == http.StatusUnauthorized:
		return errors.New("WebDAV 账号或密码不正确（HTTP 401）")
	case resp.StatusCode == http.StatusForbidden:
		return errors.New("服务器拒绝了写入（HTTP 403），请检查账号权限")
	case resp.StatusCode == http.StatusInsufficientStorage:
		return errors.New("云端空间不足（HTTP 507）")
	}
	return fmt.Errorf("上传失败，服务器返回 HTTP %d", resp.StatusCode)
}

func webdavDownload(ctx context.Context, client *http.Client, input nativeWebDAVInput) (any, error) {
	if input.BackupPassword == "" {
		return nil, errors.New("请输入备份密码")
	}
	resp, err := webdavRequest(ctx, client, "GET", input.URL, input, nil)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusNotFound:
		return webdavDownloadResult{Exists: false}, nil
	case resp.StatusCode == http.StatusUnauthorized:
		return nil, errors.New("WebDAV 账号或密码不正确（HTTP 401）")
	case resp.StatusCode == http.StatusForbidden:
		return nil, errors.New("服务器拒绝了读取（HTTP 403）")
	}
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("下载失败，服务器返回 HTTP %d", resp.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, webdavBackupLimit+(1<<20)))
	if err != nil {
		return nil, fmt.Errorf("下载中断: %w", err)
	}
	plain, err := webdavOpen(body, input.BackupPassword)
	if err != nil {
		return nil, err
	}
	return webdavDownloadResult{Exists: true, Size: len(body), Data: string(plain)}, nil
}

func webdavRequest(ctx context.Context, client *http.Client, method, rawURL string, input nativeWebDAVInput, body []byte) (*http.Response, error) {
	var reader io.Reader
	if body != nil {
		reader = bytes.NewReader(body)
	}
	req, err := http.NewRequestWithContext(ctx, method, rawURL, reader)
	if err != nil {
		return nil, fmt.Errorf("请求地址无效: %w", err)
	}
	req.Header.Set("User-Agent", "duanju-backup/1")
	if method == "PROPFIND" {
		req.Header.Set("Depth", "0")
	}
	if body != nil {
		req.Header.Set("Content-Type", "application/octet-stream")
	}
	if input.Username != "" || input.Password != "" {
		req.SetBasicAuth(input.Username, input.Password)
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("无法连接到服务器: %w", err)
	}
	return resp, nil
}

// webdavParentDirs 返回文件 URL 从主机根到父目录的逐级 URL（best-effort）。
func webdavParentDirs(rawURL string) []string {
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" || (u.Scheme != "http" && u.Scheme != "https") {
		return nil
	}
	dir := path.Dir(u.EscapedPath())
	if dir == "/" || dir == "." {
		return nil
	}
	acc := u.Scheme + "://" + u.Host
	var out []string
	for _, seg := range strings.Split(strings.Trim(dir, "/"), "/") {
		if seg == "" {
			continue
		}
		acc += "/" + seg
		out = append(out, acc)
	}
	return out
}

// webdavMkdirAll 逐级 MKCOL，任何单级失败都不中断（最终以 PUT 结果为准）。
func webdavMkdirAll(ctx context.Context, client *http.Client, input nativeWebDAVInput) {
	for _, dir := range webdavParentDirs(input.URL) {
		resp, err := webdavRequest(ctx, client, "MKCOL", dir, input, nil)
		if err != nil {
			return
		}
		io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		resp.Body.Close()
	}
}

func webdavSeal(plain []byte, password string) ([]byte, error) {
	salt := make([]byte, webdavSaltLen)
	if _, err := rand.Read(salt); err != nil {
		return nil, fmt.Errorf("生成随机盐失败: %w", err)
	}
	key, err := pbkdf2.Key(sha256.New, password, salt, webdavIterations, 32)
	if err != nil {
		return nil, fmt.Errorf("派生密钥失败: %w", err)
	}
	gcm, err := webdavCipher(key)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, webdavNonceLen)
	if _, err := rand.Read(nonce); err != nil {
		return nil, fmt.Errorf("生成随机数失败: %w", err)
	}
	head := webdavEnvelopeHead()
	out := make([]byte, 0, len(head)+len(salt)+len(nonce)+len(plain)+16)
	out = append(out, head...)
	out = append(out, salt...)
	out = append(out, nonce...)
	out = gcm.Seal(out, nonce, plain, head)
	return out, nil
}

func webdavOpen(envelope []byte, password string) ([]byte, error) {
	header := 4 + 1 + webdavSaltLen + webdavNonceLen
	if len(envelope) < header+16 {
		return nil, errors.New("云端内容不是有效的备份文件")
	}
	if string(envelope[:4]) != webdavBackupMagic {
		return nil, errors.New("云端内容不是本应用生成的备份文件")
	}
	if envelope[4] != webdavBackupVersion {
		return nil, fmt.Errorf("备份信封版本不受支持（v%d）", envelope[4])
	}
	salt := envelope[5 : 5+webdavSaltLen]
	nonce := envelope[5+webdavSaltLen : header]
	key, err := pbkdf2.Key(sha256.New, password, salt, webdavIterations, 32)
	if err != nil {
		return nil, fmt.Errorf("派生密钥失败: %w", err)
	}
	gcm, err := webdavCipher(key)
	if err != nil {
		return nil, err
	}
	plain, err := gcm.Open(nil, nonce, envelope[header:], envelope[:5])
	if err != nil {
		return nil, errors.New("备份密码不正确，或备份文件已损坏")
	}
	return plain, nil
}

func webdavEnvelopeHead() []byte {
	return append([]byte(webdavBackupMagic), webdavBackupVersion)
}

func webdavCipher(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("初始化加密失败: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("初始化加密失败: %w", err)
	}
	return gcm, nil
}
