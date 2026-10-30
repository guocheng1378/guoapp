package core

// 真果·鉴社区共创跳过预设（playback_skip_settings_preset）回归：
// 详情顶层下发 → 按剧缓存 → nativePlan 透出给播放器。

import (
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

func resetDongpiandiSkipCache(t *testing.T) {
	t.Helper()
	dongpiandiSkipMu.Lock()
	dongpiandiSkipCache = map[string]dongpiandiSkipPreset{}
	dongpiandiSkipMu.Unlock()
	t.Cleanup(func() {
		dongpiandiSkipMu.Lock()
		dongpiandiSkipCache = map[string]dongpiandiSkipPreset{}
		dongpiandiSkipMu.Unlock()
	})
}

// 详情响应顶层的预设必须解析进结构体；站点没有共创数据时整段缺失，
// 两段秒数为 0（播放器沿用既有手动标定逻辑）。
func TestDongpiandiDetailPresetUnmarshal(t *testing.T) {
	var detail dongpiandiDetail
	body := []byte(`{
		"id": "dp-detail-1",
		"title": "样例剧",
		"playback_skip_settings_preset": {
			"source": "community_median",
			"intro_end_seconds": 110,
			"outro_from_end_seconds": 145,
			"sample_count": 33
		}
	}`)
	if err := json.Unmarshal(body, &detail); err != nil {
		t.Fatal(err)
	}
	preset := detail.PlaybackSkipSettingsPreset
	if preset.Source != "community_median" || preset.IntroEndSeconds != 110 ||
		preset.OutroFromEndSeconds != 145 || preset.SampleCount != 33 {
		t.Fatalf("预设字段解析失真: %+v", preset)
	}
	if !preset.valid() {
		t.Fatal("有正数秒数的预设必须判定有效")
	}

	var empty dongpiandiDetail
	if err := json.Unmarshal([]byte(`{"id":"dp-detail-2","title":"空"}`), &empty); err != nil {
		t.Fatal(err)
	}
	if empty.PlaybackSkipSettingsPreset.valid() {
		t.Fatal("缺失预设必须判定无效，不得当成 0 秒跳过下发")
	}

	// 站点实测会下发小数秒（兰香如故 intro_end_seconds=113.4），
	// 字段必须是 float64，否则整条详情 JSON 解析失败。
	var frac dongpiandiDetail
	fracBody := []byte(`{
		"id": "dp-detail-3",
		"title": "小数秒剧",
		"playback_skip_settings_preset": {
			"source": "community_median",
			"intro_end_seconds": 113.4,
			"outro_from_end_seconds": 145.8
		}
	}`)
	if err := json.Unmarshal(fracBody, &frac); err != nil {
		t.Fatalf("小数秒预设解析失败: %v", err)
	}
	if frac.PlaybackSkipSettingsPreset.IntroEndSeconds != 113.4 ||
		frac.PlaybackSkipSettingsPreset.OutroFromEndSeconds != 145.8 {
		t.Fatalf("小数秒解析失真: %+v", frac.PlaybackSkipSettingsPreset)
	}
}

// 缓存只收有效值；容量护栏塞满时逐出旧条目，防无界增长。
func TestDongpiandiSkipPresetCache(t *testing.T) {
	resetDongpiandiSkipCache(t)

	// 空 detail ID / 全零秒数的预设都不入库。
	dongpiandiCacheSkipPreset("", dongpiandiSkipPreset{IntroEndSeconds: 90})
	dongpiandiCacheSkipPreset("dp-cache-bad", dongpiandiSkipPreset{Source: "community_median"})
	if len(dongpiandiSkipCache) != 0 {
		t.Fatalf("空 ID 或全零秒数的预设不得入库: %+v", dongpiandiSkipCache)
	}

	dongpiandiCacheSkipPreset("dp-cache-live",
		dongpiandiSkipPreset{Source: "community_median", IntroEndSeconds: 110, OutroFromEndSeconds: 145})
	got, ok := dongpiandiCachedSkipPreset("dp-cache-live")
	if !ok || got.IntroEndSeconds != 110 || got.OutroFromEndSeconds != 145 {
		t.Fatalf("预设缓存往返失真: %+v ok=%v", got, ok)
	}
	if _, ok := dongpiandiCachedSkipPreset("dp-cache-miss"); ok {
		t.Fatal("未缓存的剧不得命中")
	}

	// 容量护栏：填满后溢出写入一条，总数维持上限且新条目入库。
	for i := 0; i < 512; i++ {
		dongpiandiCacheSkipPreset(fmt.Sprintf("dp-cache-fill-%04d", i), dongpiandiSkipPreset{IntroEndSeconds: 1})
	}
	if len(dongpiandiSkipCache) != 512 {
		t.Fatalf("缓存必须受 512 上限约束，实际 %d", len(dongpiandiSkipCache))
	}
	dongpiandiCacheSkipPreset("dp-cache-spill", dongpiandiSkipPreset{IntroEndSeconds: 2})
	if len(dongpiandiSkipCache) != 512 {
		t.Fatalf("溢出写入后仍须维持上限，实际 %d", len(dongpiandiSkipCache))
	}
	if _, ok := dongpiandiCachedSkipPreset("dp-cache-spill"); !ok {
		t.Fatal("溢出后的新写入必须入库")
	}
}

// 预设字段透出到 Dart 的 JSON 形态：非零下发、零值省略（老计划无多余键）。
func TestNativePlanSkipPresetJSON(t *testing.T) {
	data, err := json.Marshal(nativePlan{SkipIntroSeconds: 110, SkipOutroFromEndSeconds: 145})
	if err != nil {
		t.Fatal(err)
	}
	var decoded map[string]any
	if err := json.Unmarshal(data, &decoded); err != nil {
		t.Fatal(err)
	}
	if decoded["skipIntroSeconds"] != float64(110) || decoded["skipOutroFromEndSeconds"] != float64(145) {
		t.Fatalf("预设字段 JSON 形态不对: %s", data)
	}

	bare, err := json.Marshal(nativePlan{})
	if err != nil {
		t.Fatal(err)
	}
	if strings.Contains(string(bare), "skipIntro") {
		t.Fatalf("零值预设必须省略，避免旧计划出现多余键: %s", bare)
	}
}
