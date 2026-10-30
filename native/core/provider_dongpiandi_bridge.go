package core

// 跨源借真果·鉴的社区跳过片头片尾预设：其他站源（红果、影视工厂等）
// 的剧按剧名映射到真果·鉴条目，命中后复用 dongpiandiSkipCache 的剧级
// 预设。真网探针实证（2026-10-30）：红果锚点剧名 suggest 精确命中 5/6，
// 命中剧里约 3/4 带预设数据。
//
// 设计约定：
//   - 同步路径（nativeResolve）只读内存缓存，零网络，绝不阻塞起播；
//   - 未命中时后台 goroutine 静默补映射，本次播放拿不到，下一集/下次
//     播放生效——映射补齐后整个剧的所有集都受益；
//   - 映射条目与冷却表仅存内存，与 dongpiandiSkipCache 同生命周期，
//     重启后随首次播放重建（站点数据在增长，重建反而拿到更新数据）；
//   - suggest 只有标题精确相等才算命中，防「同名不同剧」错配。

import (
	"context"
	"strings"
	"sync"
	"time"
	"unicode"
)

const (
	// dongpiandiBridgeCacheLimit 映射条目上限，塞满时逐出一条
	//（与 dongpiandiSkipCache 同款随机逐出护栏）。
	dongpiandiBridgeCacheLimit = 512
	// 未收录（suggest 无精确相等）：大概率长期没有，冷却拉长。
	dongpiandiBridgeCooldownMissing = 24 * time.Hour
	// 网络失败：短暂冷却后允许重试，避免把暂时性故障当成「没有」。
	dongpiandiBridgeCooldownError = 10 * time.Minute
	dongpiandiBridgePrimeTimeout  = 20 * time.Second
	// 后台映射并发上限，防批量切集时映射请求挤占正常播放解析。
	dongpiandiBridgeConcurrency = 2
)

// dongpiandiBridgeEntry 是一条跨源映射：其他源剧名（归一化）→ 真果·鉴
// variant ID。HasPreset 在探测完成后定格：映射成功但该剧没有预设时不再
// 无谓重拉详情（冷却到期才会重探一次，站点可能后续补数据）。
type dongpiandiBridgeEntry struct {
	VariantID string
	HasPreset bool
}

var (
	dongpiandiBridgeMu    sync.RWMutex
	dongpiandiBridgeCache = map[string]dongpiandiBridgeEntry{}
	dongpiandiBridgeCool  = map[string]time.Time{}
	// dongpiandiBridgeFlight 在途去重：同一剧名连续切集只触发一次探测。
	dongpiandiBridgeFlight sync.Map
	dongpiandiBridgeSem    = make(chan struct{}, dongpiandiBridgeConcurrency)
)

// normalizeDongpiandiLookupTitle 归一化剧名：去空白与书名号/标点装饰、
// 转小写，两侧同规则比较，容忍「嫁金枝」vs「《嫁金枝 》」之类的排版差异。
func normalizeDongpiandiLookupTitle(s string) string {
	var b strings.Builder
	for _, r := range s {
		if unicode.IsSpace(r) {
			continue
		}
		if strings.ContainsRune("《》〈〉「」『』()（）[]【】〔〕·・.!！?？,，、:：;；'\"‘’“”…—–-~～|／/", r) {
			continue
		}
		b.WriteRune(unicode.ToLower(r))
	}
	return b.String()
}

func dongpiandiBridgeLookup(norm string) (dongpiandiBridgeEntry, bool) {
	dongpiandiBridgeMu.RLock()
	defer dongpiandiBridgeMu.RUnlock()
	entry, ok := dongpiandiBridgeCache[norm]
	return entry, ok
}

func dongpiandiBridgeCooldownUntil(norm string) (time.Time, bool) {
	dongpiandiBridgeMu.RLock()
	defer dongpiandiBridgeMu.RUnlock()
	until, ok := dongpiandiBridgeCool[norm]
	return until, ok
}

func dongpiandiBridgeStoreEntry(norm string, entry dongpiandiBridgeEntry) {
	dongpiandiBridgeMu.Lock()
	defer dongpiandiBridgeMu.Unlock()
	if _, exists := dongpiandiBridgeCache[norm]; !exists && len(dongpiandiBridgeCache) >= dongpiandiBridgeCacheLimit {
		for key := range dongpiandiBridgeCache {
			delete(dongpiandiBridgeCache, key)
			break
		}
	}
	dongpiandiBridgeCache[norm] = entry
}

func dongpiandiBridgeStoreCooldown(norm string, coolFor time.Duration) {
	dongpiandiBridgeMu.Lock()
	defer dongpiandiBridgeMu.Unlock()
	dongpiandiBridgeCool[norm] = time.Now().Add(coolFor)
}

// dongpiandiBridgeApplySkip 为非真果·鉴源的剧查跨源跳过预设并填充 choice。
// 只查映射缓存，零网络；未命中触发后台补映射。
func (d *Downloader) dongpiandiBridgeApplySkip(title string, choice *nativePlaybackChoice) {
	trimmed := strings.TrimSpace(title)
	norm := normalizeDongpiandiLookupTitle(trimmed)
	if norm == "" {
		return
	}
	entry, ok := dongpiandiBridgeLookup(norm)
	if !ok {
		d.dongpiandiBridgePrimeAsync(norm, trimmed)
		return
	}
	if !entry.HasPreset {
		// 站点可能后续补数据：冷却到期后重探一次。
		if until, cool := dongpiandiBridgeCooldownUntil(norm); !cool || time.Now().After(until) {
			d.dongpiandiBridgePrimeAsync(norm, trimmed)
		}
		return
	}
	if preset, ok := dongpiandiCachedSkipPreset(entry.VariantID); ok {
		choice.skipIntro = int(preset.IntroEndSeconds + 0.5)
		choice.skipOutroFromEnd = int(preset.OutroFromEndSeconds + 0.5)
	} else {
		// 映射还在、预设缓存被容量护栏逐出：重拉详情回填。
		d.dongpiandiBridgePrimeAsync(norm, trimmed)
	}
}

// dongpiandiBridgePrimeAsync 后台补映射：在途去重 + 并发闸门 + 冷却三重
// 防抖，闸门满员时直接放弃（下一次集解析会再触发）。
func (d *Downloader) dongpiandiBridgePrimeAsync(norm, display string) {
	if until, ok := dongpiandiBridgeCooldownUntil(norm); ok && time.Now().Before(until) {
		return
	}
	if _, loaded := dongpiandiBridgeFlight.LoadOrStore(norm, struct{}{}); loaded {
		return
	}
	go func() {
		defer dongpiandiBridgeFlight.Delete(norm)
		select {
		case dongpiandiBridgeSem <- struct{}{}:
			defer func() { <-dongpiandiBridgeSem }()
		default:
			return
		}
		d.dongpiandiBridgePrime(norm, display)
	}()
}

// dongpiandiBridgePrime 同步完成一次跨源映射探测：suggest 精确相等 →
// 拉详情（沿途写入 dongpiandiSkipCache）→ 定格映射条目。已有映射时直接
// 重拉详情（覆盖 skipCache 逐出恢复场景），不再发 suggest。
func (d *Downloader) dongpiandiBridgePrime(norm, display string) {
	if until, ok := dongpiandiBridgeCooldownUntil(norm); ok && time.Now().Before(until) {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), dongpiandiBridgePrimeTimeout)
	defer cancel()

	variantID := ""
	if entry, ok := dongpiandiBridgeLookup(norm); ok {
		variantID = entry.VariantID
	} else {
		rows, err := d.fetchDongpiandiSuggest(ctx, newDongpiandiClient(), display, 8)
		if err != nil {
			dongpiandiBridgeStoreCooldown(norm, dongpiandiBridgeCooldownError)
			return
		}
		for _, row := range rows {
			if row.VariantID == "" {
				continue
			}
			// 标题精确相等才收，防「同名不同剧」错配。
			if normalizeDongpiandiLookupTitle(row.Label) == norm {
				variantID = row.VariantID
				break
			}
		}
		if variantID == "" {
			dongpiandiBridgeStoreCooldown(norm, dongpiandiBridgeCooldownMissing)
			return
		}
	}
	if _, _, err := d.fetchDongpiandiDetail(ctx, variantID); err != nil {
		dongpiandiBridgeStoreCooldown(norm, dongpiandiBridgeCooldownError)
		return
	}
	_, hasPreset := dongpiandiCachedSkipPreset(variantID)
	dongpiandiBridgeStoreEntry(norm, dongpiandiBridgeEntry{VariantID: variantID, HasPreset: hasPreset})
	if !hasPreset {
		// 命中映射但没有预设：也冷却，避免每集 resolve 都白拉一次详情。
		dongpiandiBridgeStoreCooldown(norm, dongpiandiBridgeCooldownMissing)
	}
}
