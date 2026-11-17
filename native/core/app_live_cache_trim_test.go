package core

// 直播缓存的容量与净化回归（2026-11-15）：
//   - 超过磁盘上限时必须「按最旧裁剪后落盘」，不能像以前那样直接 return 丢掉整次写；
//   - TTL 内命中内存缓存也要复检 filterLiveChannels，否则同进程内新导入的
//     自填源会带广告频道/点播伪直播线路挂满整个 TTL。

import (
	"context"
	"fmt"
	"os"
	"strings"
	"testing"
	"time"
)

func TestLiveCacheTrimsInsteadOfDroppingWhenOverLimit(t *testing.T) {
	d := rankingTestDownloader(t, liveTestTransport(nil))
	d.loadLiveCache()
	// 每个条目 ~400KB 频道数据 × 32 条 ≈ 12.8MB，刚好越过 liveMaxCacheBytes。
	payload := strings.Repeat("x", 400*1024)
	for i := 0; i < liveMaxCacheEntries; i++ {
		key := fmt.Sprintf("custom|https://live.test/%d.m3u", i)
		d.live.entries[key] = liveListEntry{
			Key: key,
			Channels: []liveChannel{{
				Name:  fmt.Sprintf("CCTV-%d", i),
				Group: "央视",
				URLs:  []string{"http://stream.test/" + payload},
			}},
			FetchedAt: time.Now().Add(-time.Duration(i) * time.Minute),
		}
	}
	d.live.dirty = true
	d.flushLiveCache()

	data, err := os.ReadFile(d.liveFileName())
	if err != nil {
		t.Fatalf("超限时应裁剪后落盘，实际未写盘：%v", err)
	}
	if len(data) > liveMaxCacheBytes {
		t.Fatalf("落盘体积仍超上限：%d > %d", len(data), liveMaxCacheBytes)
	}
	if len(d.live.entries) >= liveMaxCacheEntries {
		t.Fatalf("应逐出部分条目，实际仍剩 %d 条", len(d.live.entries))
	}
	if d.live.dirty {
		t.Fatal("成功落盘后 dirty 应清零")
	}
}

func TestLiveCacheHitAppliesChannelFilter(t *testing.T) {
	d := rankingTestDownloader(t, liveTestTransport(nil))
	d.loadLiveCache()
	key := "custom|https://live.test/dirty.m3u"
	d.live.entries[key] = liveListEntry{
		Key: key,
		Channels: []liveChannel{
			{Name: "CCTV-1", Group: "央视", URLs: []string{"http://stream.test/1.m3u8"}},
			{Name: "家有购物", Group: "购物", URLs: []string{"http://stream.test/ad.m3u8"}},
			{Name: "伪直播", Group: "电影", URLs: []string{"http://txmov2.a.kwimgs.com/ad.mp4"}},
		},
		FetchedAt: time.Now(),
	}

	entry, stale, err := d.loadLiveList(
		context.Background(), key, []string{"https://live.test/dirty.m3u"}, false,
	)
	if err != nil || stale {
		t.Fatalf("TTL 内命中缓存不应失败：err=%v stale=%v", err, stale)
	}
	if len(entry.Channels) != 1 || entry.Channels[0].Name != "CCTV-1" {
		t.Fatalf("命中缓存也应净化脏频道：%+v", entry.Channels)
	}
	if cached := d.live.entries[key]; len(cached.Channels) != 1 {
		t.Fatalf("净化结果应写回缓存：%+v", cached.Channels)
	}
}
