package core

import (
	"fmt"
	"testing"
	"time"
)

// 官方直链每次重兑只换预签名查询串：测速缓存键必须忽略查询串，
// 否则每次切集都必然 miss、重跑 1.5s 探针。
func TestDongpiandiSpeedKeyIgnoresPresignedQuery(t *testing.T) {
	line := dongpiandiLine{ID: "l1", URL: "https://cdn.test/v/ep1.mp4?X-Amz-Signature=aaa"}
	redeemed := dongpiandiLine{ID: "l1", URL: "https://cdn.test/v/ep1.mp4?X-Amz-Signature=bbb"}
	if dongpiandiSpeedKey(line) != dongpiandiSpeedKey(redeemed) {
		t.Fatal("re-signing must reuse the speed cache key")
	}
	other := dongpiandiLine{ID: "l2", URL: "https://cdn.test/v/ep1.mp4?X-Amz-Signature=aaa"}
	if dongpiandiSpeedKey(line) == dongpiandiSpeedKey(other) {
		t.Fatal("different lines must not share a speed cache key")
	}
}

// 满表时逐出最旧一条，不能整表清空（旧实现会让一批切集集体重测速）。
func TestDongpiandiSpeedCacheEvictsOldestInsteadOfWiping(t *testing.T) {
	dongpiandiSpeedMu.Lock()
	previous := dongpiandiSpeedCache
	dongpiandiSpeedCache = map[string]dongpiandiSpeedEntry{}
	for i := 0; i < 256; i++ {
		dongpiandiSpeedCache[fmt.Sprintf("k%d", i)] = dongpiandiSpeedEntry{
			res: dongpiandiProbeResult{url: "https://cdn.test/v.mp4", ready: true},
			at:  time.Now(),
		}
	}
	dongpiandiSpeedMu.Unlock()
	t.Cleanup(func() {
		dongpiandiSpeedMu.Lock()
		dongpiandiSpeedCache = previous
		dongpiandiSpeedMu.Unlock()
	})

	dongpiandiSpeedPut("fresh", dongpiandiProbeResult{
		url: "https://cdn.test/v.mp4", ready: true,
	})
	dongpiandiSpeedMu.Lock()
	defer dongpiandiSpeedMu.Unlock()
	if len(dongpiandiSpeedCache) < 250 {
		t.Fatalf("cache wiped instead of LRU eviction: %d entries", len(dongpiandiSpeedCache))
	}
	if _, ok := dongpiandiSpeedCache["fresh"]; !ok {
		t.Fatal("fresh entry missing after eviction")
	}
}
