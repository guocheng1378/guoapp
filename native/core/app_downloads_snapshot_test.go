package core

import "testing"

// 界面每 2 秒轮询下载列表：内容没变时必须只回指纹，不重复序列化整张列表。
func TestNativeDownloadsSnapshotSinceSkipsUnchangedJobs(t *testing.T) {
	manager := &nativeDownloads{jobs: map[string]*nativeDownloadRecord{}}

	first, err := manager.snapshotSince("")
	if err != nil {
		t.Fatalf("首次快照失败: %v", err)
	}
	fingerprint, _ := first["fingerprint"].(string)
	if fingerprint == "" {
		t.Fatal("快照应带内容指纹")
	}
	if _, ok := first["jobs"]; !ok {
		t.Fatal("首次请求（客户端还没有指纹）必须返回完整列表")
	}

	second, err := manager.snapshotSince(fingerprint)
	if err != nil {
		t.Fatalf("二次快照失败: %v", err)
	}
	if _, ok := second["jobs"]; ok {
		t.Fatal("指纹命中时不应再传列表")
	}
	if got, _ := second["fingerprint"].(string); got != fingerprint {
		t.Fatalf("指纹应保持不变: %q != %q", got, fingerprint)
	}

	stale, err := manager.snapshotSince("stale-fingerprint")
	if err != nil {
		t.Fatalf("指纹过期时的快照失败: %v", err)
	}
	if _, ok := stale["jobs"]; !ok {
		t.Fatal("指纹不匹配时必须回完整列表")
	}
}
