package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// resetDongpiandiSkipDiskTest 清空两份内存缓存与落盘绑定，绑定到临时目录并
// 首载一次。用例结束还原全部状态，避免污染同二进制里的其他用例。
func resetDongpiandiSkipDiskTest(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	reset := func() {
		dongpiandiSkipDiskMu.Lock()
		dongpiandiSkipDiskDir = ""
		dongpiandiSkipDiskDirty = false
		if dongpiandiSkipDiskTimer != nil {
			dongpiandiSkipDiskTimer.Stop()
			dongpiandiSkipDiskTimer = nil
		}
		dongpiandiSkipDiskMu.Unlock()
		dongpiandiSkipMu.Lock()
		dongpiandiSkipCache = map[string]dongpiandiSkipPreset{}
		dongpiandiSkipMu.Unlock()
		dongpiandiBridgeMu.Lock()
		dongpiandiBridgeCache = map[string]dongpiandiBridgeEntry{}
		dongpiandiBridgeMu.Unlock()
	}
	reset()
	t.Cleanup(reset)
	loadDongpiandiSkipPresets(dir)
	return dir
}

func wipeDongpiandiSkipMemoryCaches() {
	dongpiandiSkipMu.Lock()
	dongpiandiSkipCache = map[string]dongpiandiSkipPreset{}
	dongpiandiSkipMu.Unlock()
	dongpiandiBridgeMu.Lock()
	dongpiandiBridgeCache = map[string]dongpiandiBridgeEntry{}
	dongpiandiBridgeCool = map[string]time.Time{}
	dongpiandiBridgeMu.Unlock()
}

// TestSkipPresetsRoundTrip 写入预设与跨源映射 → 冲刷落盘 → 清内存模拟重启 →
// 重载后两边都能命中；冷却表不出现在盘上文件里。
func TestSkipPresetsRoundTrip(t *testing.T) {
	dir := resetDongpiandiSkipDiskTest(t)

	preset := dongpiandiSkipPreset{Source: "community", IntroEndSeconds: 18.5, OutroFromEndSeconds: 12, SampleCount: 7}
	dongpiandiCacheSkipPreset("dp-detail-rt", preset)
	dongpiandiBridgeStoreEntry("嫁金枝", dongpiandiBridgeEntry{VariantID: "dp-detail-rt", HasPreset: true})
	dongpiandiBridgeStoreCooldown("冷却剧", 0)
	flushDongpiandiSkipPresets()

	body, err := os.ReadFile(filepath.Join(dir, dongpiandiSkipDiskFile))
	if err != nil {
		t.Fatalf("read skip_presets.json: %v", err)
	}
	if strings.Contains(string(body), "cooldown") {
		t.Fatalf("冷却表不应落盘: %s", body)
	}
	var disk dongpiandiSkipDisk
	if err := json.Unmarshal(body, &disk); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if disk.Version != 1 {
		t.Fatalf("version = %d, want 1", disk.Version)
	}
	if disk.Presets["dp-detail-rt"] != preset {
		t.Fatalf("preset mismatch: %+v", disk.Presets["dp-detail-rt"])
	}
	if got := disk.Bridges["嫁金枝"]; got.VariantID != "dp-detail-rt" || !got.HasPreset {
		t.Fatalf("bridge mismatch: %+v", got)
	}

	// 模拟进程重启：内存清零后重载，冷启动即命中。
	wipeDongpiandiSkipMemoryCaches()
	loadDongpiandiSkipPresets(dir)

	dongpiandiSkipMu.Lock()
	gotPreset, okPreset := dongpiandiSkipCache["dp-detail-rt"]
	dongpiandiSkipMu.Unlock()
	if !okPreset || gotPreset != preset {
		t.Fatalf("preset not restored: %+v ok=%v", gotPreset, okPreset)
	}
	dongpiandiBridgeMu.RLock()
	gotBridge, okBridge := dongpiandiBridgeCache["嫁金枝"]
	dongpiandiBridgeMu.RUnlock()
	if !okBridge || gotBridge.VariantID != "dp-detail-rt" || !gotBridge.HasPreset {
		t.Fatalf("bridge not restored: %+v ok=%v", gotBridge, okBridge)
	}
	dongpiandiBridgeMu.RLock()
	_, coolRestored := dongpiandiBridgeCool["冷却剧"]
	dongpiandiBridgeMu.RUnlock()
	if coolRestored {
		t.Fatal("冷却表不应随落盘恢复")
	}
}

// TestSkipPresetsLoadMergesAndKeepsMemory 回填只补内存缺口：内存里已有的键
// 不被盘上旧值覆盖，盘上独有的键照常回填。
func TestSkipPresetsLoadMergesAndKeepsMemory(t *testing.T) {
	dir := resetDongpiandiSkipDiskTest(t)

	memory := dongpiandiSkipPreset{Source: "community", IntroEndSeconds: 10, SampleCount: 3}
	dongpiandiCacheSkipPreset("dp-shared", memory)
	flushDongpiandiSkipPresets()

	// 手工把盘上文件改成：dp-shared 值不同（模拟旧版本数据）+ 新增 dp-disk。
	stale := dongpiandiSkipDisk{Version: 1, Presets: map[string]dongpiandiSkipPreset{
		"dp-shared": {Source: "community", IntroEndSeconds: 99, SampleCount: 3},
		"dp-disk":   {Source: "community", IntroEndSeconds: 20, SampleCount: 1},
	}}
	body, err := json.Marshal(stale)
	if err != nil {
		t.Fatalf("marshal stale: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, dongpiandiSkipDiskFile), body, 0o600); err != nil {
		t.Fatalf("write stale: %v", err)
	}

	loadDongpiandiSkipPresets(dir)

	dongpiandiSkipMu.Lock()
	defer dongpiandiSkipMu.Unlock()
	if got := dongpiandiSkipCache["dp-shared"]; got != memory {
		t.Fatalf("memory entry clobbered: %+v, want %+v", got, memory)
	}
	if got := dongpiandiSkipCache["dp-disk"]; got.IntroEndSeconds != 20 || got.SampleCount != 1 {
		t.Fatalf("disk-only entry not restored: %+v", got)
	}
}

// TestSkipPresetsCorruptFileIgnored 盘上文件损坏时当没有缓存处理，不污染内存。
func TestSkipPresetsCorruptFileIgnored(t *testing.T) {
	dir := resetDongpiandiSkipDiskTest(t)
	if err := os.WriteFile(filepath.Join(dir, dongpiandiSkipDiskFile), []byte("{not json"), 0o600); err != nil {
		t.Fatalf("write corrupt: %v", err)
	}
	loadDongpiandiSkipPresets(dir)

	dongpiandiSkipMu.Lock()
	empty := len(dongpiandiSkipCache) == 0
	dongpiandiSkipMu.Unlock()
	if !empty {
		t.Fatal("损坏文件不应回填任何预设")
	}
}
