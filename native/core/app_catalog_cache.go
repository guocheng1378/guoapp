package core

import (
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

const nativeCatalogTTL = 15 * time.Minute

// nativeCatalogFlushWindow 剧库落盘合并窗。
//
// 剧库每次变更（翻页、详情补齐）都要把整份目录重新序列化并原子写盘，
// 万级条目时一次 fsync + rename 的代价是几百毫秒，连着翻页就把首屏
// 拖成连续卡顿。这里把「序列化 + 体积判定」留在调用栈内同步完成
// （超 32 MiB 必须当场报错，不能拖到窗口外再算），真正的写盘交给
// 合并窗：窗口内的连续变更只落盘一次。
const nativeCatalogFlushWindow = 2 * time.Second

// nativeCatalogFlushRetry 落盘失败后的重试间隔。
// 磁盘满、文件被占用这类临时故障要能自己恢复，不能让本次会话的剧库变更消失。
const nativeCatalogFlushRetry = 5 * time.Second

type nativeCatalogState struct {
	UpdatedAt time.Time `json:"updatedAt"`
	Page      int       `json:"page"`
	HasMore   bool      `json:"hasMore"`
	Warning   string    `json:"warning,omitempty"`
}

type nativeCatalogDisk struct {
	Version         int                                  `json:"version"`
	Catalogs        map[string][]nativeDrama             `json:"catalogs"`
	States          map[string]nativeCatalogState        `json:"states"`
	Categories      map[string][]nativeCategory          `json:"categories,omitempty"`
	HongguoApp      *hongguoCatalogState                 `json:"hongguoApp,omitempty"`
	Recommendations map[string]nativeRecommendationState `json:"recommendations,omitempty"`
}

func (engine *nativeEngine) loadCatalogCache() {
	// 读盘之前先把合并窗里待写的快照落盘：读到的必须是「已落盘」的最新剧库，
	// 否则同一目录重建引擎（或重启）后会读到旧快照，丢掉最后一次变更。
	flushPendingCatalogWrite(engine.directory, engine)
	file, err := os.Open(filepath.Join(engine.directory, "catalogs.json"))
	if err != nil {
		return
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, nativeCatalogMaxBytes+1))
	if err != nil || len(body) > nativeCatalogMaxBytes {
		return
	}
	var disk nativeCatalogDisk
	if json.Unmarshal(body, &disk) == nil && (disk.Version == 2 || disk.Version == 3) {
		if disk.Catalogs != nil {
			engine.catalogs = disk.Catalogs
			for _, items := range engine.catalogs {
				for index := range items {
					items[index] = migrateNativeDrama(items[index])
				}
			}
		}
		if disk.States != nil {
			engine.catalogStates = disk.States
		}
		engine.categoryOptions = disk.Categories
		engine.recommendations = make(map[string]nativeRecommendationState)
		for genre, state := range disk.Recommendations {
			if genre == state.Query.Genre && state.Query.validate() == nil && state.Page > 0 {
				engine.recommendations[genre] = state
			}
		}
		engine.hongguoCatalog = cloneHongguoCatalogState(disk.HongguoApp)
		if engine.downloader != nil {
			engine.downloader.restoreHongguoCatalog(disk.HongguoApp)
			if disk.HongguoApp != nil {
				engine.hongguoCatalog = engine.downloader.hongguoCatalogSnapshot()
			}
		}
		return
	}
	var legacy map[string][]nativeDrama
	if json.Unmarshal(body, &legacy) == nil && legacy != nil {
		engine.catalogs = legacy
		for _, items := range engine.catalogs {
			for index := range items {
				items[index] = migrateNativeDrama(items[index])
			}
		}
	}
}

// nativeDramaMetadataSchema 剧库条目元数据版本：
//
//	1 → 黄豆 VIP 语义迁移
//	2 → 真果·鉴封面集数改取 playback_groups[].episode_count。此前的版本
//	    可能把 playback_count（总播放量，量级几十到几千）当集数写盘，
//	    用户会看到「共 1150 集」这类错值——加载时清零，等下拉刷新/重新
//	    拉目录后用新数据给出正确集数。
const nativeDramaMetadataSchema = 2

func migrateNativeDrama(drama nativeDrama) nativeDrama {
	if drama.MetadataSchema == 0 && drama.Source == sourceHuangdou && drama.VIP != nil && !*drama.VIP {
		drama.VIP = nil
	}
	if drama.MetadataSchema < nativeDramaMetadataSchema && drama.Source == sourceDongpiandi {
		drama.Episodes = 0
	}
	drama.MetadataSchema = nativeDramaMetadataSchema
	return drama
}

func (engine *nativeEngine) nativeCached(source string) nativeCatalogResult {
	source = canonicalProviderSource(source)
	engine.ensureLoaded()
	engine.mu.Lock()
	defer engine.mu.Unlock()
	items := append([]nativeDrama{}, engine.catalogs[source]...)
	for index := range items {
		items[index].Cover = repairLegacyCoverURL(items[index])
	}
	state, found := engine.catalogStates[source]
	age := time.Since(state.UpdatedAt)
	result := nativeCatalogResult{
		Items: items, Page: max(1, state.Page), HasMore: !found || state.HasMore,
		Fresh:   len(items) > 0 && state.Warning == "" && !state.UpdatedAt.IsZero() && age >= 0 && age < nativeCatalogTTL,
		Warning: state.Warning,
	}
	if engine.catalogSaveError != nil {
		result.Warning = joinNativeWarnings(result.Warning, engine.catalogSaveError.Error())
		result.saveError = engine.catalogSaveError
		result.Fresh, result.HasMore = false, true
	}
	return result
}

func mergeNativeCatalog(first, second []nativeDrama) []nativeDrama {
	items := append([]nativeDrama{}, first...)
	indices := make(map[string]int, len(items))
	for index, item := range items {
		indices[item.ID] = index
	}
	for _, item := range second {
		if index, found := indices[item.ID]; found {
			items[index] = mergeNativeDrama(items[index], item)
		} else {
			indices[item.ID] = len(items)
			items = append(items, item)
		}
	}
	return items
}

func mergeNativeDrama(previous, fresh nativeDrama) nativeDrama {
	previous, fresh = migrateNativeDrama(previous), migrateNativeDrama(fresh)
	if previous.ID != "" && fresh.ID != previous.ID {
		return fresh
	}
	if fresh.Source == "" {
		fresh.Source = previous.Source
	}
	if fresh.SourceID == "" {
		fresh.SourceID = previous.SourceID
	}
	if fresh.Title == "" || fresh.Title == "短剧" {
		fresh.Title = previous.Title
	}
	if fresh.Description == "" {
		fresh.Description = previous.Description
	}
	if fresh.Cover == "" {
		fresh.Cover = previous.Cover
	}
	if fresh.Category == "" || nativeGenericCategory(fresh.Category) && previous.Category != "" && !nativeGenericCategory(previous.Category) {
		fresh.Category = previous.Category
	}
	if fresh.Episodes == 0 {
		fresh.Episodes = previous.Episodes
	}
	if fresh.VIP == nil {
		fresh.VIP = previous.VIP
	}
	if fresh.Heat == "" {
		fresh.Heat = previous.Heat
	}
	if fresh.Views == "" {
		fresh.Views = previous.Views
	}
	if fresh.OnlineDate == "" {
		fresh.OnlineDate = previous.OnlineDate
	}
	if len(fresh.Tags) == 0 {
		fresh.Tags = previous.Tags
	}
	if len(fresh.Actors) == 0 {
		fresh.Actors = previous.Actors
	}
	if fresh.ReleaseStatus == "" || fresh.ReleaseStatus == "unknown" {
		fresh.ReleaseStatus = previous.ReleaseStatus
	}
	return fresh
}

func nativeGenericCategory(category string) bool {
	switch category {
	case "短剧", "真人剧", "漫剧", "AI剧", "AI 剧", "AI短剧", "AI 短剧", "AI漫剧", "AI 漫剧":
		return true
	}
	return false
}

func (engine *nativeEngine) saveCatalogCache(source string, result *nativeCatalogResult) error {
	engine.ensureLoaded()
	engine.mu.Lock()
	defer engine.mu.Unlock()
	previous := engine.catalogs[source]
	state := engine.catalogStates[source]
	var items []nativeDrama
	if result.Page == 1 {
		items = result.Items
		if len(previous) > 0 {
			old := make(map[string]nativeDrama, len(previous))
			for _, item := range previous {
				old[item.ID] = item
			}
			for index, item := range items {
				items[index] = mergeNativeDrama(old[item.ID], item)
			}
			fresh := make(map[string]bool, len(items))
			for _, item := range items {
				fresh[item.ID] = true
			}
			for _, item := range previous {
				if !fresh[item.ID] {
					items = append(items, item)
				}
			}
			result.Items = items
			result.Page = max(1, state.Page)
			if source != sourceHongguo && state.Page > 1 {
				result.HasMore = state.HasMore
			}
		}
	} else {
		items = mergeNativeCatalog(previous, result.Items)
		if result.Page < state.Page {
			result.Page, result.HasMore = state.Page, state.HasMore
		}
	}
	engine.catalogs[source] = items
	if result.hongguo != nil {
		engine.hongguoCatalog = cloneHongguoCatalogState(result.hongguo)
	}
	if result.Warning != "" {
		result.Page = max(1, state.Page)
		result.HasMore = true
	}
	state.Page, state.HasMore = result.Page, result.HasMore
	state.Warning = result.Warning
	if result.Warning == "" {
		state.UpdatedAt = time.Now()
		result.Fresh = true
	}
	engine.catalogStates[source] = state
	if base, _, categorized := strings.Cut(source, "|"); categorized {
		engine.catalogs[base] = mergeNativeCatalog(engine.catalogs[base], items)
	}
	err := engine.deferCatalogDiskWriteForSourceLocked(source)
	result.saveError = err
	if err == nil && engine.catalogSaveError != nil {
		// 上一次落盘失败还没修复：本次变更同样没能落盘，按旧语义继续报错，
		// 不让「未保存」被当成「已保存」。
		err = engine.catalogSaveError
	}
	if err != nil {
		result.Warning = joinNativeWarnings(result.Warning, err.Error())
		result.Fresh, result.HasMore = false, true
	}
	return err
}

// marshalCatalogDiskLocked 序列化当前剧库快照并做体积判定（调用方持有 engine.mu）。
// 体积上限必须当场判定：超限要在同一个调用栈里报错，拖到合并窗外就没人拦了。
func (engine *nativeEngine) marshalCatalogDiskLocked() ([]byte, error) {
	body, err := json.Marshal(nativeCatalogDisk{Version: 3, Catalogs: engine.catalogs, States: engine.catalogStates, Categories: engine.categoryOptions, HongguoApp: engine.hongguoCatalog, Recommendations: engine.recommendations})
	if err == nil && len(body) > nativeCatalogMaxBytes {
		err = errNativeCatalogLimit
	}
	return body, err
}

// deferCatalogDiskWriteLocked 把剧库快照交给合并窗落盘（调用方持有 engine.mu）。
// 返回值只含「当场可判定」的错误（序列化失败、超过 32 MiB 上限）；窗口内的
// 实际写盘失败由下一次读取/重试路径回报（catalogSaveError 通道不变）。
//
// source 是这次变更所属的站源：切源时用来判断「上一源的快照要不要先落盘」。
func (engine *nativeEngine) deferCatalogDiskWriteLocked(source string) error {
	if engine.retired.Load() {
		// 引擎已被同目录的新引擎接管：不再进合并窗，直接同步落盘，
		// 免得旧快照晚到一步把新引擎写的数据盖回去。
		return engine.writeCatalogDiskLocked()
	}
	body, err := engine.marshalCatalogDiskLocked()
	if err != nil {
		engine.catalogSaveError = nativeSaveError("剧库", err)
		engine.markCatalogSavePendingLocked()
		return engine.catalogSaveError
	}
	engine.catalogWriteMu.Lock()
	engine.catalogPending = body
	engine.catalogPendingSource = source
	// 新快照从头计窗：它从未写失败，重开路径照常可以补写。
	engine.catalogPendingFailed = false
	if engine.catalogTimer == nil {
		engine.catalogTimer = time.AfterFunc(nativeCatalogFlushWindow, engine.flushCatalogDiskAsync)
	} else {
		engine.catalogTimer.Reset(nativeCatalogFlushWindow)
	}
	engine.catalogWriteMu.Unlock()
	return nil
}

// deferCatalogDiskWriteForSourceLocked 切源时立即把上一源的快照落盘。
//
// 合并窗把「同一源的连续翻页」合成一次写盘；换了站源就是另一份数据，
// 这时上一源的快照必须先落盘，否则切源后进程被杀会丢掉那一段。
func (engine *nativeEngine) deferCatalogDiskWriteForSourceLocked(source string) error {
	engine.catalogWriteMu.Lock()
	pendingSource := engine.catalogPendingSource
	engine.catalogWriteMu.Unlock()
	if pendingSource != "" && source != "" && catalogBaseSource(pendingSource) != catalogBaseSource(source) {
		engine.flushCatalogDiskLocked()
	}
	return engine.deferCatalogDiskWriteLocked(source)
}

// catalogBaseSource 取目录键里的站源部分（"站源|分类" → "站源"）。
func catalogBaseSource(key string) string {
	base, _, _ := strings.Cut(key, "|")
	return base
}

// flushCatalogDiskAsync 合并窗到点后的落盘入口（定时器回调）。
func (engine *nativeEngine) flushCatalogDiskAsync() {
	_ = engine.flushCatalogDisk()
}

// flushCatalogDiskLocked 立即把合并窗里待写的快照落盘（调用方持有 engine.mu）。
func (engine *nativeEngine) flushCatalogDiskLocked() error {
	engine.catalogWriteMu.Lock()
	body := engine.catalogPending
	source := engine.catalogPendingSource
	engine.catalogPending = nil
	engine.catalogPendingSource = ""
	engine.catalogWriteMu.Unlock()
	if len(body) == 0 {
		return engine.catalogSaveError
	}
	err := writeNativeCacheFile(filepath.Join(engine.directory, "catalogs.json"), body)
	if err != nil {
		engine.catalogSaveError = nativeSaveError("剧库", err)
		engine.markCatalogSavePendingLocked()
		// 失败时把快照放回窗口并退避重试：磁盘满、文件被占用这类临时故障
		// 不能让本次会话的剧库变更凭空消失。
		engine.catalogWriteMu.Lock()
		engine.catalogPending = body
		engine.catalogPendingSource = source
		// 标记隔离：这份快照此刻「未落盘」，重开路径不许复活它。
		engine.catalogPendingFailed = true
		if engine.catalogTimer != nil {
			engine.catalogTimer.Reset(nativeCatalogFlushRetry)
		}
		engine.catalogWriteMu.Unlock()
		return engine.catalogSaveError
	}
	engine.catalogSaveError = nil
	engine.finishCatalogSaveLocked()
	return nil
}

// flushCatalogDisk 供未持有 engine.mu 的上下文调用（合并窗定时器、进程退出前冲刷）。
func (engine *nativeEngine) flushCatalogDisk() error {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	return engine.flushCatalogDiskLocked()
}

// catalogPendingQuarantined 报告合并窗里的待写快照是否「已写盘失败、被放回
// 窗口等本引擎重试」（内部只取 catalogWriteMu；重开路径用它决定跳过冲刷）。
func (engine *nativeEngine) catalogPendingQuarantined() bool {
	engine.catalogWriteMu.Lock()
	defer engine.catalogWriteMu.Unlock()
	return engine.catalogPending != nil && engine.catalogPendingFailed
}

// stopCatalogWrites 停止合并窗并把待写快照落盘（引擎重建/退出前调用）。
// 已写失败的快照不在这里补写：引擎重建/重启必须从上次真正落盘的快照恢复，
// 并让「上次保存未完成」冒出来；把失败快照冲回盘里等于复活未落盘数据、
// 吞掉失败信号，还会让重启引擎越过旧游标继续翻页。快照留在内存里，
// 由本引擎的重试定时器或显式 retrySave 落盘。
func (engine *nativeEngine) stopCatalogWrites() {
	engine.catalogWriteMu.Lock()
	if engine.catalogTimer != nil {
		engine.catalogTimer.Stop()
		engine.catalogTimer = nil
	}
	quarantined := engine.catalogPending != nil && engine.catalogPendingFailed
	engine.catalogWriteMu.Unlock()
	if quarantined {
		return
	}
	_ = engine.flushCatalogDisk()
}

func (engine *nativeEngine) writeCatalogDiskLocked() error {
	body, err := engine.marshalCatalogDiskLocked()
	if err == nil {
		err = writeNativeCacheFile(filepath.Join(engine.directory, "catalogs.json"), body)
	}
	engine.catalogSaveError = nativeSaveError("剧库", err)
	if err == nil {
		// 整份重写成功：合并窗里那份更旧的快照作废，免得窗口到点后写回去。
		engine.catalogWriteMu.Lock()
		engine.catalogPending = nil
		engine.catalogPendingSource = ""
		engine.catalogWriteMu.Unlock()
		engine.finishCatalogSaveLocked()
	} else {
		// 写失败时把「当前状态」放回待写快照：它比窗口里那份更新，
		// 重试时落盘的应该是最新内容，而不是更早的旧快照。
		engine.catalogWriteMu.Lock()
		if len(body) > 0 {
			engine.catalogPending = body
			engine.catalogPendingFailed = true
		}
		engine.catalogWriteMu.Unlock()
		engine.markCatalogSavePendingLocked()
	}
	return engine.catalogSaveError
}

func writeNativeCacheFile(path string, data []byte) error {
	if err := os.MkdirAll(filepath.Dir(path), 0700); err != nil {
		return err
	}
	temporary, err := os.CreateTemp(filepath.Dir(path), ".cache-write-*")
	if err != nil {
		return err
	}
	defer os.Remove(temporary.Name())
	_, writeErr := temporary.Write(data)
	if writeErr == nil {
		writeErr = temporary.Sync()
	}
	closeErr := temporary.Close()
	if writeErr != nil {
		return writeErr
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(temporary.Name(), path)
}

func (engine *nativeEngine) saveDetailMetadata(drama nativeDrama) error {
	engine.ensureLoaded()
	engine.mu.Lock()
	defer engine.mu.Unlock()
	changed := false
	for _, items := range engine.catalogs {
		for index := range items {
			if items[index].ID == drama.ID {
				items[index] = mergeNativeDrama(items[index], drama)
				changed = true
			}
		}
	}
	if changed {
		return engine.deferCatalogDiskWriteLocked(drama.Source)
	}
	return nil
}
