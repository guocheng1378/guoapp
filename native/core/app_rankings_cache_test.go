package core

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestRankingCacheWriteCoalescing(t *testing.T) {
	// 合并窗用 2s：300ms 窗下读文件（Windows 上可能上百毫秒）会与尾写
	// Rename 撞进同一窗口，测出的是文件系统竞争而非合并逻辑。
	backup := rankingWriteInterval
	rankingWriteInterval = 2 * time.Second
	t.Cleanup(func() { rankingWriteInterval = backup })

	d := &Downloader{cfg: Config{dataDir: t.TempDir()}}
	d.loadRankingCache()
	board, _ := findRankingBoard("douban-realtime")
	cache := &d.rankings
	path := filepath.Join(d.cfg.dataDir, "rankings.json")
	page := func(version string) rankingPage {
		return rankingPage{BoardID: board.ID, Page: 1, UpdatedText: version,
			FetchedAt: time.Now(), Items: []rankingItem{}}
	}

	// 首次写盘立即生效（保住「拉到第一页就能重启恢复」语义）。
	cache.mu.Lock()
	cache.pages[board.ID+":1"] = page("v1")
	d.writeRankingCacheLocked()
	cache.mu.Unlock()
	body, err := os.ReadFile(path)
	if err != nil || !strings.Contains(string(body), "v1") {
		t.Fatal("first ranking write must land on disk immediately", err)
	}

	// 间隔内的后续写合并：磁盘应保持 v1，等尾部写触发后再变 v2。
	cache.mu.Lock()
	cache.pages[board.ID+":1"] = page("v2")
	d.writeRankingCacheLocked()
	cache.mu.Unlock()
	body, err = os.ReadFile(path)
	if err != nil || !strings.Contains(string(body), "v1") || strings.Contains(string(body), "v2") {
		t.Fatal("writes inside the interval must be deferred")
	}
	time.Sleep(rankingWriteInterval + 400*time.Millisecond)
	body, err = os.ReadFile(path)
	if err != nil || !strings.Contains(string(body), "v2") {
		t.Fatal("trailing write must flush the coalesced page", err)
	}
}
