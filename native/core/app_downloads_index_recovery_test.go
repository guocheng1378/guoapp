package core

// 下载索引的损坏恢复与 Folder 兼容（2026-11-15）：
//   - 主索引坏掉时回退 index.json.bak，不能让整库下载记录永久不可见；
//   - 只丢弃逃出下载根的 Folder，不能因为「旧版本按源分目录」就拒绝整份索引。

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

func newDownloadIndexTestManager(t *testing.T) *nativeDownloads {
	t.Helper()
	return &nativeDownloads{
		root: t.TempDir(),
		jobs: map[string]*nativeDownloadRecord{},
	}
}

func completedDownloadRecord(source string, index int, folder string) nativeDownloadRecord {
	id := nativeDownloadID("drama-1", index)
	return nativeDownloadRecord{
		nativeDownloadJob: nativeDownloadJob{
			ID:      id,
			Index:   index,
			State:   "completed",
			Created: int64(index),
			Folder:  folder,
			Drama:   nativeDrama{ID: "drama-1", Source: source},
		},
		File: "media.mp4",
	}
}

func TestDownloadIndexFallsBackToBackup(t *testing.T) {
	manager := newDownloadIndexTestManager(t)
	record := completedDownloadRecord("hongguo", 1, "")
	data, err := json.Marshal([]nativeDownloadRecord{record})
	if err != nil {
		t.Fatalf("构造索引失败：%v", err)
	}
	broken := []byte(`{"id":"truncated`)
	if err := os.WriteFile(filepath.Join(manager.root, "index.json"), broken, 0600); err != nil {
		t.Fatalf("写坏索引失败：%v", err)
	}
	if err := os.WriteFile(filepath.Join(manager.root, "index.json.bak"), data, 0600); err != nil {
		t.Fatalf("写备份失败：%v", err)
	}

	if err := manager.load(); err != nil {
		t.Fatalf("主索引损坏时应回退备份，实际报错：%v", err)
	}
	if _, ok := manager.jobs[record.ID]; !ok {
		t.Fatalf("备份里的下载记录应被恢复，jobs=%d", len(manager.jobs))
	}
}

func TestDownloadIndexKeepsSafeFolderAndDropsEscape(t *testing.T) {
	manager := newDownloadIndexTestManager(t)
	safe := completedDownloadRecord("hongguo", 1, "hongguo/"+nativeDownloadID("drama-1", 1))
	escape := completedDownloadRecord("hongguo", 2, "../escape")
	data, err := json.Marshal([]nativeDownloadRecord{safe, escape})
	if err != nil {
		t.Fatalf("构造索引失败：%v", err)
	}
	if err := os.WriteFile(filepath.Join(manager.root, "index.json"), data, 0600); err != nil {
		t.Fatalf("写索引失败：%v", err)
	}

	if err := manager.load(); err != nil {
		t.Fatalf("合法 Folder 不应导致整份索引被拒：%v", err)
	}
	kept, ok := manager.jobs[safe.ID]
	if !ok {
		t.Fatal("按源分目录的历史记录应保留")
	}
	if kept.Folder != safe.Folder {
		t.Fatalf("合法 Folder 应原样保留：%q", kept.Folder)
	}
	escaped, ok := manager.jobs[escape.ID]
	if !ok {
		t.Fatal("第二条记录也应加载")
	}
	if escaped.Folder != "" {
		t.Fatalf("逃出下载根的 Folder 应被清空，实际 %q", escaped.Folder)
	}
}
