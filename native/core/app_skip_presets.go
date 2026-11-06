package core

// 跳过片头片尾预设与跨源桥映射的落盘持久化。
//
// dongpiandiSkipCache（真果·鉴 detail ID → 社区预设）与 dongpiandiBridgeCache
// （跨源归一化剧名 → variant 映射）此前只存内存，进程重启后要靠重新拉详情、
// 重新 suggest 回填：冷启动的前几集拿不到预设，跨源桥每次启动都要重探一遍。
// 预设是剧级常量（社区中位数不频繁变），落盘一份即可长期复用。
//
// 冷却表（dongpiandiBridgeCooldown / missing 重探退避）是临时态，有意不落盘：
// 重启后允许立即重探一次，反而能吃到站点新增长的预设数据。
//
// 文件走独立 skip_presets.json 而不是把预设塞进 catalogs.json 的剧条目：
// 预设的键是 detail ID 与跨源剧名，跟剧库条目的生命周期不对齐（没进目录的
// 剧同样会有预设；跨源借来的 variant ID 也未必对应任何目录条目）。

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"sync"
	"time"
)

const (
	dongpiandiSkipDiskFile  = "skip_presets.json"
	dongpiandiSkipMaxBytes  = 8 << 20 // 8 MiB 读盘上限：512 预设 + 512 桥映射远小于此
	dongpiandiSkipFlushWait = time.Second
)

// dongpiandiSkipCacheLimit 与 dongpiandiBridgeCacheLimit 同款容量护栏，
// provider 侧写入与盘上回填共用这一个真源。
const dongpiandiSkipCacheLimit = 512

// dongpiandiSkipDisk 是 skip_presets.json 的盘上形态。Version 便于将来加字段。
type dongpiandiSkipDisk struct {
	Version int                              `json:"version"`
	Presets map[string]dongpiandiSkipPreset  `json:"presets,omitempty"`
	Bridges map[string]dongpiandiBridgeEntry `json:"bridges,omitempty"`
}

var (
	dongpiandiSkipDiskMu    sync.Mutex
	dongpiandiSkipDiskDir   string
	dongpiandiSkipDiskDirty bool
	dongpiandiSkipDiskTimer *time.Timer
)

// loadDongpiandiSkipPresets 换绑落盘目录并从盘回填两个内存缓存（引擎懒加载入口）。
//
// 回填用合并语义：盘上条目只补内存缺失的键，内存里还没落盘的新数据保留。
// 换目录前先把旧目录的待写数据冲掉，引擎重建指向同一目录时也不会丢。
func loadDongpiandiSkipPresets(directory string) {
	if directory == "" {
		return
	}
	dongpiandiSkipDiskMu.Lock()
	if previous := dongpiandiSkipDiskDir; previous != "" && previous != directory && dongpiandiSkipDiskDirty {
		_ = dongpiandiWriteSkipDiskLocked(previous)
	}
	if dongpiandiSkipDiskTimer != nil {
		dongpiandiSkipDiskTimer.Stop()
		dongpiandiSkipDiskTimer = nil
	}
	dongpiandiSkipDiskDirty = false
	dongpiandiSkipDiskDir = directory
	dongpiandiSkipDiskMu.Unlock()

	body, err := dongpiandiReadSkipDisk(directory)
	if err != nil || len(body) == 0 {
		return
	}
	var disk dongpiandiSkipDisk
	if err := json.Unmarshal(body, &disk); err != nil || disk.Version != 1 {
		// 损坏或陌生版本即当作没有缓存：重新探一遍即可。
		return
	}
	dongpiandiSkipMu.Lock()
	for id, preset := range disk.Presets {
		if len(dongpiandiSkipCache) >= dongpiandiSkipCacheLimit {
			break
		}
		if _, ok := dongpiandiSkipCache[id]; !ok {
			dongpiandiSkipCache[id] = preset
		}
	}
	dongpiandiSkipMu.Unlock()

	dongpiandiBridgeMu.Lock()
	for title, entry := range disk.Bridges {
		if len(dongpiandiBridgeCache) >= dongpiandiBridgeCacheLimit {
			break
		}
		if _, ok := dongpiandiBridgeCache[title]; !ok {
			dongpiandiBridgeCache[title] = entry
		}
	}
	dongpiandiBridgeMu.Unlock()
}

// dongpiandiScheduleSkipFlush 标脏并安排合并窗落盘（缓存写入方调用）。
// 没有目录（纯 Downloader 测试、引擎未初始化）时只标脏不安排定时器。
func dongpiandiScheduleSkipFlush() {
	dongpiandiSkipDiskMu.Lock()
	defer dongpiandiSkipDiskMu.Unlock()
	dongpiandiSkipDiskDirty = true
	if dongpiandiSkipDiskDir == "" {
		return
	}
	if dongpiandiSkipDiskTimer == nil {
		dongpiandiSkipDiskTimer = time.AfterFunc(dongpiandiSkipFlushWait, dongpiandiSkipFlushTick)
		return
	}
	dongpiandiSkipDiskTimer.Reset(dongpiandiSkipFlushWait)
}

// dongpiandiSkipFlushTick 合并窗到期：落盘一次；失败保留脏标记做退避重试。
func dongpiandiSkipFlushTick() {
	dongpiandiSkipDiskMu.Lock()
	defer dongpiandiSkipDiskMu.Unlock()
	if !dongpiandiSkipDiskDirty || dongpiandiSkipDiskDir == "" {
		return
	}
	if err := dongpiandiWriteSkipDiskLocked(dongpiandiSkipDiskDir); err != nil {
		if dongpiandiSkipDiskTimer == nil {
			dongpiandiSkipDiskTimer = time.AfterFunc(5*time.Second, dongpiandiSkipFlushTick)
		} else {
			dongpiandiSkipDiskTimer.Reset(5 * time.Second)
		}
		return
	}
	dongpiandiSkipDiskDirty = false
}

// flushDongpiandiSkipPresets 立即把待写数据落盘（引擎退役钩子与测试用）。
func flushDongpiandiSkipPresets() {
	dongpiandiSkipDiskMu.Lock()
	defer dongpiandiSkipDiskMu.Unlock()
	if dongpiandiSkipDiskTimer != nil {
		dongpiandiSkipDiskTimer.Stop()
		dongpiandiSkipDiskTimer = nil
	}
	if !dongpiandiSkipDiskDirty || dongpiandiSkipDiskDir == "" {
		return
	}
	if err := dongpiandiWriteSkipDiskLocked(dongpiandiSkipDiskDir); err == nil {
		dongpiandiSkipDiskDirty = false
	}
}

// dongpiandiReadSkipDisk 读一份跳过预设落盘（超限当缺失：缓存重建即可）。
func dongpiandiReadSkipDisk(directory string) ([]byte, error) {
	file, err := os.Open(filepath.Join(directory, dongpiandiSkipDiskFile))
	if err != nil {
		return nil, err
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, dongpiandiSkipMaxBytes+1))
	if err != nil || len(body) > dongpiandiSkipMaxBytes {
		return nil, err
	}
	return body, nil
}

// dongpiandiWriteSkipDiskLocked 序列化两个缓存并落盘（调用方持 dongpiandiSkipDiskMu）。
// 序列化时短暂分别抓两把缓存锁，避免与写入方长时间互斥。
func dongpiandiWriteSkipDiskLocked(directory string) error {
	dongpiandiSkipMu.Lock()
	presets := make(map[string]dongpiandiSkipPreset, len(dongpiandiSkipCache))
	for id, preset := range dongpiandiSkipCache {
		presets[id] = preset
	}
	dongpiandiSkipMu.Unlock()

	dongpiandiBridgeMu.Lock()
	bridges := make(map[string]dongpiandiBridgeEntry, len(dongpiandiBridgeCache))
	for title, entry := range dongpiandiBridgeCache {
		bridges[title] = entry
	}
	dongpiandiBridgeMu.Unlock()

	body, err := json.Marshal(dongpiandiSkipDisk{Version: 1, Presets: presets, Bridges: bridges})
	if err != nil {
		return err
	}
	return writeNativeCacheFile(filepath.Join(directory, dongpiandiSkipDiskFile), body)
}
