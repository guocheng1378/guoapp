package core

import (
	"fmt"
	"testing"
	"time"
)

// 满额时只逐出最久未更新的一条，其余已解析的集必须保留。
// 旧实现是整表清空：所有集在同一时刻失效，随后并发重走详情+兑换形成重解析风暴。
func TestDongpiandiLinesCacheEvictsOldestInsteadOfWiping(t *testing.T) {
	dongpiandiLinesMu.Lock()
	dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
	dongpiandiLinesMu.Unlock()
	t.Cleanup(func() {
		dongpiandiLinesMu.Lock()
		dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
		dongpiandiLinesMu.Unlock()
	})

	line := []dongpiandiLine{{URL: "http://cdn.example.cn/1.m3u8", URLKind: "m3u8", Resolved: true}}
	for i := 0; i < 256; i++ {
		dongpiandiCacheLines(fmt.Sprintf("ep-%d", i), line, false)
		// 制造确定的「新旧」顺序：ep-0 最旧。
		dongpiandiLinesMu.Lock()
		entry := dongpiandiLinesCache[fmt.Sprintf("ep-%d", i)]
		entry.thirdAt = time.Now().Add(time.Duration(i) * time.Millisecond)
		dongpiandiLinesCache[fmt.Sprintf("ep-%d", i)] = entry
		dongpiandiLinesMu.Unlock()
	}

	dongpiandiCacheLines("ep-new", line, false)

	dongpiandiLinesMu.Lock()
	size := len(dongpiandiLinesCache)
	dongpiandiLinesMu.Unlock()
	if size != 256 {
		t.Fatalf("逐出一条后应仍为 256 条，实际 %d（整表清空会得到 1）", size)
	}
	if got := dongpiandiCachedLines("ep-0"); len(got) != 0 {
		t.Fatalf("最久未更新的 ep-0 应被逐出")
	}
	if got := dongpiandiCachedLines("ep-255"); len(got) == 0 {
		t.Fatalf("较新的 ep-255 不应被逐出")
	}
	if got := dongpiandiCachedLines("ep-new"); len(got) == 0 {
		t.Fatalf("新写入的条目应保留")
	}
}

// 过期条目优先清理，且不会波及仍有效的条目。
func TestDongpiandiLinesCacheDropsStaleFirst(t *testing.T) {
	dongpiandiLinesMu.Lock()
	dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
	dongpiandiLinesMu.Unlock()
	t.Cleanup(func() {
		dongpiandiLinesMu.Lock()
		dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
		dongpiandiLinesMu.Unlock()
	})

	line := []dongpiandiLine{{URL: "http://cdn.example.cn/1.m3u8", URLKind: "m3u8", Resolved: true}}
	for i := 0; i < 255; i++ {
		dongpiandiCacheLines(fmt.Sprintf("fresh-%d", i), line, false)
	}
	// 一条三方线已过期（thirdAt 早于 TTL），官方线也没有。
	staleAt := time.Now().Add(-dongpiandiThirdLineTTL - time.Minute)
	dongpiandiLinesMu.Lock()
	dongpiandiLinesCache["stale"] = dongpiandiLineCacheEntry{third: line, thirdAt: staleAt}
	dongpiandiLinesMu.Unlock()

	dongpiandiCacheLines("fresh-new", line, false)

	if got := dongpiandiCachedLines("stale"); len(got) != 0 {
		t.Fatalf("过期条目应被清理")
	}
	if got := dongpiandiCachedLines("fresh-0"); len(got) == 0 {
		t.Fatalf("有效条目不应被清理")
	}
}
