package core

import (
	"errors"
	"net"
	"os"
	"path/filepath"
	"testing"
)

// 笔盒上次可用线路落盘：重启后先试它，失败才重新发现域名。
func TestBeaboxHostPersistence(t *testing.T) {
	directory := t.TempDir()
	d := &Downloader{cfg: Config{dataDir: directory}}

	if got := d.beaboxStoredHost(); got != "" {
		t.Fatalf("没有存档时应返回空串，实际 %q", got)
	}

	d.beaboxStoreHost("https://bh4066.top")
	if got := d.beaboxStoredHost(); got != "https://bh4066.top" {
		t.Fatalf("存档读回不一致: %q", got)
	}

	// 非 https 的存档视为无效，避免被坏文件带到 http 线路上。
	if err := os.WriteFile(filepath.Join(directory, beaboxHostFile), []byte(`{"host":"ftp://bh4066.top"}`), 0600); err != nil {
		t.Fatalf("写入坏存档失败: %v", err)
	}
	if got := d.beaboxStoredHost(); got != "" {
		t.Fatalf("非法存档应被忽略，实际 %q", got)
	}

	// 未配置数据目录时读写都应是空操作，不能 panic。
	empty := &Downloader{}
	empty.beaboxStoreHost("https://bh4066.top")
	if got := empty.beaboxStoredHost(); got != "" {
		t.Fatalf("无数据目录时不应读出内容，实际 %q", got)
	}
}

// DoH 兜底只对「疑似 DNS 污染/连接被拒」的失败生效，其它失败保持原开销。
func TestNativeDNSSuspect(t *testing.T) {
	if !nativeDNSSuspect(&net.DNSError{Err: "no such host", Name: "x.example"}) {
		t.Fatal("DNS 解析失败应触发 DoH 重试")
	}
	if !nativeDNSSuspect(errors.New("dial tcp 0.0.0.0:443: connect: connection refused")) {
		t.Fatal("被解析到 0.0.0.0 时的连接被拒应触发重试")
	}
	if nativeDNSSuspect(errors.New("read tcp 10.0.0.2:443: connection reset by peer")) {
		t.Fatal("对端主动断开不应触发 DoH 重试")
	}
	if nativeDNSSuspect(nil) {
		t.Fatal("nil 错误不应触发重试")
	}
}
