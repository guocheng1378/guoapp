package core

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"mime"
	"net"
	"net/url"
	"strings"
)

// 本机播放代理的诊断埋点（对齐上游 app_stream_diagnostics.go）：会话用短哈希
// 标识而不是明文 token；上游地址的长路径段脱敏；错误按类型归类。所有事件写进
// 既有 app.log，播放器报「暂时无法播放」时可从诊断日志看到根因。

type nativeStreamDiagnosticKey struct{}

type nativeStreamDiagnostic struct {
	session string
	asset   string
}

func nativeStreamID(value string) string {
	digest := sha256.Sum256([]byte(value))
	return hex.EncodeToString(digest[:6])
}

// nativeStreamTarget 返回上游主机与脱敏后的路径：长于 48 字符的路径段（通常是
// 签名/票据）换成短哈希，避免把可播放直链写进日志。
func nativeStreamTarget(address string) (string, string) {
	parsed, err := url.Parse(address)
	if err != nil {
		return "", "invalid"
	}
	parts := strings.Split(parsed.EscapedPath(), "/")
	for index, part := range parts {
		if len(part) > 48 {
			parts[index] = "[redacted-" + nativeStreamID(part) + "]"
		}
	}
	return parsed.Hostname(), truncate(strings.Join(parts, "/"), 512)
}

// nativeStreamError 把底层错误归并成稳定的类别，便于按类统计而不泄露地址细节。
func nativeStreamError(err error) string {
	if err == nil {
		return "none"
	}
	if errors.Is(err, context.Canceled) {
		return "canceled"
	}
	if errors.Is(err, context.DeadlineExceeded) {
		return "deadline"
	}
	var certificate *tls.CertificateVerificationError
	if errors.As(err, &certificate) {
		return "tls"
	}
	var dns *net.DNSError
	if errors.As(err, &dns) {
		return "dns"
	}
	var op *net.OpError
	if errors.As(err, &op) && op.Op == "dial" {
		return "connect"
	}
	var timeout net.Error
	if errors.As(err, &timeout) && timeout.Timeout() {
		return "timeout"
	}
	if errors.Is(err, io.ErrUnexpectedEOF) {
		return "unexpected_eof"
	}
	return "io_error"
}

func (stream *nativeStreamServer) nativeLog(info nativeStreamDiagnostic, event, address, detail string, status int, contentType string) {
	if stream == nil || stream.downloader == nil {
		return
	}
	host, target := nativeStreamTarget(address)
	mediaType, _, _ := mime.ParseMediaType(contentType)
	stream.downloader.recordDiagnostic(diagnosticEvent{
		Event: "stream." + event, Level: "warning", Host: host, HTTPStatus: status, ResponseType: mediaType,
		Message: strings.TrimSpace(fmt.Sprintf("session=%s asset=%s path=%s %s", info.session, info.asset, target, detail)),
	})
}

func (stream *nativeStreamServer) nativeLogError(info nativeStreamDiagnostic, event, address string, err error, contentType string) {
	if errors.Is(err, context.Canceled) {
		return
	}
	stream.nativeLog(info, event, address, "error="+nativeStreamError(err), 0, contentType)
}

func nativePlaylistKind(body string) string {
	if strings.Contains(body, "#EXT-X-STREAM-INF:") || strings.Contains(body, "#EXT-X-I-FRAME-STREAM-INF:") {
		return "master_playlist"
	}
	return "media_playlist"
}

// nativeDiagnosticBody 包装上游响应体：读取中途出错（连接被 reset、EOF 等）
// 也记一条诊断，否则播放器只看到「暂时无法播放」，无法区分回源失败与断流。
type nativeDiagnosticBody struct {
	io.ReadCloser
	stream  *nativeStreamServer
	info    nativeStreamDiagnostic
	address string
}

func (body *nativeDiagnosticBody) Read(buffer []byte) (int, error) {
	count, err := body.ReadCloser.Read(buffer)
	if err != nil && !errors.Is(err, io.EOF) {
		body.stream.nativeLogError(body.info, "upstream_read_error", body.address, err, "")
	}
	return count, err
}
