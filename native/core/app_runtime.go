package core

import (
	"context"
	"crypto/tls"
	"duanjuapp/native/provider"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

type Config struct {
	dataDir         string
	MaxPagesPerSort int
	PageSize        int
	Retries         int
	InsecureTLS     bool
	HuangguoAIURL   string
	HuangdouURL     string
	HongguoURL      string
	HuangjuURL      string
	HuangjuAPIURL   string
	YeguoURL        string
	YeguoAPIURL     string
	SoraniAPIURL    string
	Token           string
	AESKeyHex       string
	InterfaceKey    string
	ParamKey        string
	ParamIV         string
	APIBase         string
	CDNURL          string
}

type Downloader struct {
	rankings               rankingCache
	live                   liveCache
	cfg                    Config
	client                 *http.Client
	huangdouDetails        map[string]huangdouDetailEntry
	huangdouDetailPending  map[string]*huangdouDetailCall
	providerMu             sync.Mutex
	providerHosts          map[string]string
	limiter                *requestLimiter
	proxyRouter            *proxyRouter
	hongguoOnce            sync.Once
	rankingOnce            sync.Once
	liveOnce               sync.Once
	hongguo                *hongguoAppClient
	huangjuOnce            sync.Once
	huangju                *huangjuAPIClient
	yeguoOnce              sync.Once
	yeguo                  *yeguoAPIClient
	soraniOnce             sync.Once
	sorani                 *soraniAPIClient
	diagnostics            *diagnosticLog
	apiMu                  sync.Mutex
	apiBase                string
	apiFailures            map[string]time.Time
	legacyOnce             sync.Once
	legacy                 *legacyAPIClient
	dongpiandiDanmakuOnce  sync.Once
	dongpiandiDanmakuStore *dongpiandiDanmakuCache
}

func defaultConfig() Config { return Config{MaxPagesPerSort: 50, PageSize: 30, Retries: 2} }

type nativeDrama struct {
	MetadataSchema int      `json:"metadataSchema"`
	ID             string   `json:"id"`
	Source         string   `json:"source"`
	SourceID       string   `json:"sourceId"`
	Title          string   `json:"title"`
	Description    string   `json:"description"`
	Cover          string   `json:"cover"`
	Episodes       int      `json:"episodes"`
	Category       string   `json:"category"`
	VIP            *bool    `json:"vip"`
	Heat           string   `json:"heat,omitempty"`
	Views          string   `json:"views,omitempty"`
	OnlineDate     string   `json:"onlineDate,omitempty"`
	Area           string   `json:"area,omitempty"`
	Year           string   `json:"year,omitempty"`
	Duration       float64  `json:"duration,omitempty"`
	Score          string   `json:"score,omitempty"`
	Tags           []string `json:"tags,omitempty"`
	Actors         []string `json:"actors,omitempty"`
	ReleaseStatus  string   `json:"releaseStatus,omitempty"`
}

type nativeInput struct {
	LAN              json.RawMessage         `json:"lan"`
	ExpectedVersions map[string]string       `json:"expectedVersions"`
	SystemProxy      nativeSystemProxy       `json:"systemProxy"`
	Settings         nativeResourceSettings  `json:"settings"`
	JobIDs           []string                `json:"jobIds"`
	PlaybackSession  string                  `json:"playbackSession"`
	StartMS          int64                   `json:"startMs"`
	DurationMS       int64                   `json:"durationMs"`
	Board            string                  `json:"board"`
	ListID           string                  `json:"listId"`
	LiveURLs         []string                `json:"liveUrls"`
	Entries          []nativeDownloadEpisode `json:"entries"`
	JobID            string                  `json:"jobId"`
	Command          string                  `json:"command"`
	Action           string                  `json:"action"`
	SourceConfig     map[string]any          `json:"sourceConfig,omitempty"`
	Directory        string                  `json:"directory"`
	Source           string                  `json:"source"`
	Page             int                     `json:"page"`
	Query            string                  `json:"query"`
	Category         string                  `json:"category"`
	Sort             string                  `json:"sort"`
	Drama            nativeDrama             `json:"drama"`
	Chapter          Chapter                 `json:"chapter"`
	Index            int                     `json:"index"`
	Quality          int                     `json:"quality"`
	Route            int                     `json:"route"`
	Session          string                  `json:"session"`
	Sequence         int64                   `json:"sequence"`
	Force            bool                    `json:"force"`
	OfficialOnly     bool                    `json:"officialOnly"`
	WebDAV           json.RawMessage         `json:"webdav"`
}

type nativeCatalogResult struct {
	Items       []nativeDrama `json:"items"`
	HasMore     bool          `json:"hasMore"`
	Page        int           `json:"page"`
	Warning     string        `json:"warning,omitempty"`
	LocalSearch bool          `json:"localSearch"`
	Fresh       bool          `json:"fresh"`
	hongguo     *hongguoCatalogState
	saveError   error
}

type nativePlan struct {
	ExpiresAt       int64  `json:"expiresAt,omitempty"`
	PrefetchedBytes int64  `json:"prefetchedBytes,omitempty"`
	DanmakuID       string `json:"danmakuId,omitempty"`
	// 社区跳过预设（秒，真果·鉴下发）：片头结束位置 / 片尾起点距结尾。
	// 0 表示站源未下发，播放器按既有手动标定逻辑处理。
	SkipIntroSeconds        int               `json:"skipIntroSeconds,omitempty"`
	SkipOutroFromEndSeconds int               `json:"skipOutroFromEndSeconds,omitempty"`
	Local                   bool              `json:"local"`
	URL                     string            `json:"url"`
	Headers                 map[string]string `json:"headers"`
	Key                     string            `json:"decryptionKey,omitempty"`
	Quality                 int               `json:"quality"`
	Qualities               []int             `json:"qualities"`
	Session                 string            `json:"session,omitempty"`
	RouteIndex              int               `json:"routeIndex"`
	RouteCount              int               `json:"routeCount"`
	RouteLabels             []string          `json:"routeLabels,omitempty"`
	// RouteOfficial 与 RouteLabels 一一对应：true 表示该线路是站源官方线。
	// 面板据此把第三方线路折叠，避免几十条三方线把官方源淹没。
	RouteOfficial []bool `json:"routeOfficial,omitempty"`
}

type nativeEngine struct {
	lanMu            sync.Mutex
	lan              *nativeLANServer
	settingsMu       sync.Mutex
	settings         nativeResourceSettings
	readMu           sync.Mutex
	reads            map[string]nativeReadRequest
	readCount        int
	work             map[string]bool
	downloads        *nativeDownloads
	downloader       *Downloader
	directory        string
	mu               sync.Mutex
	catalogs         map[string][]nativeDrama
	catalogStates    map[string]nativeCatalogState
	categoryOptions  map[string][]nativeCategory
	hongguoCatalog   *hongguoCatalogState
	recommendations  map[string]nativeRecommendationState
	catalogSaveError error
	sourceSaveError  error
	// catalogWriteMu 保护合并窗里的待写快照（catalogPending）与定时器。
	// 落盘合并窗：剧库每次变更都要整份重写，代价与库大小成正比，
	// 连续翻页时反复 fsync 会把首屏拖成卡顿。这里把写盘合并到
	// nativeCatalogFlushWindow 的窗口里，窗口内的连续变更只落盘一次。
	catalogWriteMu sync.Mutex
	catalogPending []byte
	// catalogPendingSource 是待写快照所属的站源：切源时用它判断要不要先落盘。
	catalogPendingSource string
	catalogTimer         *time.Timer
	// catalogPendingFailed 标记 catalogPending 是一份已写盘失败、被放回窗口等
	// 本引擎重试的快照：重开路径（stopCatalogWrites/flushPendingCatalogWrite）
	// 不得把它冲回盘里「复活」——重启引擎必须从上次真正落盘的快照恢复，
	// 并让「上次保存未完成」的状态冒出来；补写只走重试定时器/显式 retrySave。
	catalogPendingFailed bool
	// retired 标记这个引擎已被同目录的新引擎接管：它不再进合并窗，
	// 变更直接同步落盘，避免旧引擎的内存快照晚到一步把新数据盖回去。
	retired atomic.Bool
	// loadOnce 磁盘缓存懒加载：构造引擎不再同步读 catalogs.json（上限 32 MiB），
	// 改由第一次真正用到剧库/榜单/直播/站源记录时按需加载。
	loadOnce sync.Once
	// settingsOnce 只负责那份小文件（网络与下载设置）。
	settingsOnce     sync.Once
	covers           *nativeCoverCache
	stream           *nativeStreamServer
	playbacks        map[string]nativePlaybackChoice
	playbackMu       sync.Mutex
	playbackSequence int64
	playbackCancel   context.CancelFunc
	sourceTasks      map[string]*nativeSourceTask
	sourceRecords    map[string]nativeSourceRecord
	sourceCatalogMu  sync.Mutex
	sourceCatalogs   map[string]chan struct{}
	// resolveCache 缓存最近解析出的媒体信息（5 分钟）。红果的取流链
	// （App 接口已失效 → 退回网页兜底）一次解析实测要 8 秒以上，播放
	// 恢复时重新解析会把一次卡顿放大成十几秒停顿。
	resolveCacheMu sync.Mutex
	resolveCache   map[string]nativeResolveCacheEntry
}

// nativeResolveCacheEntry 是一条带过期时间的解析结果。
type nativeResolveCacheEntry struct {
	media    providerMedia
	expireAt time.Time
}

var nativeState struct {
	sync.Mutex
	engine *nativeEngine
}

// nativeEngineRegistry 记录每个数据目录当前活跃的引擎。
//
// 用途有两个：
//  1. 同一目录重建引擎（切用户、重载、测试重启）前，把上一个引擎合并窗里
//     待写的剧库落盘，否则新引擎会读到旧快照；
//  2. 读盘前（loadCatalogCache）把该目录待写的快照冲刷掉，保证「读己之写」。
var nativeEngineRegistry struct {
	sync.Mutex
	byDirectory map[string][]*nativeEngine
}

// registerNativeEngine 登记新引擎，并把该目录上其它引擎待写的剧库落盘。
// 落盘失败也不阻塞新引擎；已写失败被放回窗口的快照不在此复活（见
// stopCatalogWrites）：重启引擎从上次真正落盘的快照恢复并保留失败提示。
func registerNativeEngine(directory string, engine *nativeEngine) {
	nativeEngineRegistry.Lock()
	if nativeEngineRegistry.byDirectory == nil {
		nativeEngineRegistry.byDirectory = map[string][]*nativeEngine{}
	}
	engines := nativeEngineRegistry.byDirectory[directory]
	engines = append(engines, engine)
	nativeEngineRegistry.byDirectory[directory] = engines
	nativeEngineRegistry.Unlock()
	for _, previous := range engines[:len(engines)-1] {
		if previous != engine {
			// 旧引擎退休：待写快照先落盘，之后它的变更直接同步写，
			// 不再进合并窗（否则旧快照可能晚到一步把新引擎的数据盖回去）。
			previous.retired.Store(true)
			previous.stopCatalogWrites()
		}
	}
}

// flushPendingCatalogWrite 把该数据目录上待写的剧库快照落盘（读盘前调用）。
// exclude 是正在读盘的引擎自身：它的数据还在内存里，不必回写。
func flushPendingCatalogWrite(directory string, exclude *nativeEngine) {
	nativeEngineRegistry.Lock()
	engines := append([]*nativeEngine(nil), nativeEngineRegistry.byDirectory[directory]...)
	nativeEngineRegistry.Unlock()
	for _, pending := range engines {
		if pending == nil || pending == exclude {
			continue
		}
		// 不能拿着本引擎的锁去等别的引擎的锁：两个引擎同时首次加载会互等
		// （各自持锁再要对方的锁）。抢不到锁就跳过——那一侧还没落盘，
		// 读到的可能是稍旧的数据，但不会死锁。
		if !pending.mu.TryLock() {
			continue
		}
		if pending.catalogPendingQuarantined() {
			// 已写失败被放回窗口的快照不在这里复活（同 stopCatalogWrites）：
			// 正在读盘的引擎要从上次真正落盘的快照恢复。
			pending.mu.Unlock()
			continue
		}
		_ = pending.flushCatalogDiskLocked()
		pending.mu.Unlock()
	}
}

// ensureLoaded 磁盘缓存懒加载。
//
// 构造引擎时同步读 catalogs.json（上限 32 MiB）会把首帧前的启动链路拖长：
// 解析整份 JSON 的代价与库大小成正比，而这份数据在首页真正请求目录之前
// 用不上。改成按需加载——第一次真正访问剧库/榜单/直播/站源记录时再读。
// 语义不变：首次 cached() 依旧直接返回磁盘目录（Fresh 判定照旧）。
func (engine *nativeEngine) ensureLoaded() {
	engine.ensureSettingsLoaded()
	engine.loadOnce.Do(func() {
		if engine.downloader == nil {
			// 手工拼装的引擎（测试用）没有 downloader，只加载引擎自己的缓存。
			engine.mu.Lock()
			engine.loadCatalogCache()
			engine.loadSourceRecords()
			engine.mu.Unlock()
			return
		}
		engine.mu.Lock()
		defer engine.mu.Unlock()
		engine.downloader.loadRankingCache()
		engine.downloader.loadLiveCache()
		engine.loadCatalogCache()
		engine.loadSourceRecords()
	})
}

// ensureSettingsLoaded 只加载「网络与下载设置」这一份小文件。
// 构造引擎时（newNativeDownloads 会读一次设置）只走这条轻量路径，
// 剧库/榜单/直播/站源记录这些重缓存留到第一次真正用到时再读。
func (engine *nativeEngine) ensureSettingsLoaded() {
	engine.settingsOnce.Do(func() {
		engine.settingsMu.Lock()
		engine.loadResourceSettings()
		engine.settingsMu.Unlock()
	})
}

func nativeText(value any) string {
	return provider.NativeText(value)
}

func nativeNormalize(drama Drama) nativeDrama {
	cover := ""
	for _, value := range []any{drama.Cover, drama.CoverURL, drama.CoverURLSnake, drama.Image, drama.ImageURL, drama.ImageURLSnake, drama.Img, drama.Pic, drama.Picture, drama.Poster, drama.Thumb, drama.Thumbnail} {
		candidate := nativeText(value)
		if strings.HasPrefix(candidate, "//") {
			candidate = "https:" + candidate
		}
		if isProviderHTTPMediaURL(candidate) {
			cover = candidate
			break
		}
	}
	episodes := 0
	// 正规集数字段（totalEpisode/episodeCount/episodes）直接信任；上限防脏大值溢出。
	for _, value := range []any{drama.TotalEpisode, drama.TotalEpisodeSnake, drama.EpisodeCount, drama.EpisodeCountSnake, drama.Episodes} {
		if count, _ := strconv.Atoi(nativeText(value)); count > episodes && count <= 100000 {
			episodes = count
		}
	}
	// ChapterCount/Total 在部分站点是分页总数/播放量/合集数（legacy 行数据透传），
	// 只能当弱证据：正规字段全空时兜底且上限 999，脏大值直接丢弃，
	// 否则榜单会显示「更新至数万集」。
	if episodes == 0 {
		for _, value := range []any{drama.ChapterCount, drama.ChapterCountSnake, drama.Total} {
			if count, _ := strconv.Atoi(nativeText(value)); count > episodes && count <= 999 {
				episodes = count
			}
		}
	}
	source, sourceID, ok := splitProviderDramaID(drama.ID)
	if !ok && drama.Source != "" {
		// 榜单专用源（豆瓣）不注册 provider，条目 ID 反解必然失败；
		// 此类条目构造时已显式带 Source/SourceID，直接采信。
		source, sourceID = drama.Source, drama.SourceID
		if sourceID == "" {
			sourceID = strings.TrimPrefix(drama.ID, source+":")
		}
	}
	return nativeDrama{MetadataSchema: nativeDramaMetadataSchema, ID: drama.ID, Source: source, SourceID: sourceID, Title: drama.DisplayTitle(),
		Description: firstNonEmpty(drama.Desc, drama.Intro), Cover: cover, Episodes: episodes,
		Category: nativeDramaCategory(drama), VIP: drama.VIP,
		Heat: drama.Heat, Views: drama.Views, OnlineDate: providerReleaseDate(drama.OnlineDate),
		Area: drama.Area, Year: drama.Year, Score: drama.Score,
		Duration: flexDurationSeconds(drama.Duration),
		Tags:     append([]string(nil), drama.Tags...), Actors: append([]string(nil), drama.Actors...), ReleaseStatus: drama.ReleaseStatus}
}

// flexDurationSeconds 把 provider 层的时长松散值统一为秒（单集时长）：
// 数字=秒；字符串支持 "1:05:30"/"45:12" 冒号分级与纯数字秒；无效返回 0，
// Dart 侧短剧/长剧判定对 0 走兜底规则。
func flexDurationSeconds(value any) float64 {
	switch typed := value.(type) {
	case float64:
		return typed
	case float32:
		return float64(typed)
	case int:
		return float64(typed)
	case int64:
		return float64(typed)
	case json.Number:
		if n, err := typed.Float64(); err == nil {
			return n
		}
	case string:
		text := strings.TrimSpace(typed)
		if text == "" {
			return 0
		}
		if n, err := strconv.ParseFloat(text, 64); err == nil {
			return n
		}
		parts := strings.Split(text, ":")
		if len(parts) < 2 || len(parts) > 3 {
			return 0
		}
		total := 0.0
		for _, part := range parts {
			n, err := strconv.ParseFloat(strings.TrimSpace(part), 64)
			if err != nil || n < 0 {
				return 0
			}
			total = total*60 + n
		}
		return total
	}
	return 0
}

func nativeDramaCategory(drama Drama) string {
	category := firstNonEmpty(drama.CategoryName, drama.CategoryNameSnake, drama.TypeName, drama.TypeNameSnake, drama.SortName, drama.SortNameSnake, drama.Category)
	if category != "" {
		return category
	}
	switch drama.ChannelName {
	case "真人剧", "短剧", "漫剧", "AI 剧", "AI剧", "AI 短剧", "AI 漫剧", "AI 换脸", "AI 魔改":
		return drama.ChannelName
	}
	return ""
}

func newNativeEngine(directory string) (*nativeEngine, error) {
	if !filepath.IsAbs(directory) {
		return nil, errors.New("应用数据目录无效")
	}
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, err
	}
	// 上次运行学到的优选域名先播种进包级表，随后 providerHostsSeed 交给新引擎；
	// 远程 sourceConfig.providerHosts 到达时仍会整表替换（远程优先）。
	seedProviderHostsFromDisk(directory)
	cfg := defaultConfig()
	cfg.dataDir = directory
	router := &proxyRouter{}
	d := &Downloader{cfg: cfg, providerHosts: providerHostsSeed(), proxyRouter: router,
		limiter: newRequestLimiter(3, 250*time.Millisecond), diagnostics: newDiagnosticLog(directory)}
	transport := http.DefaultTransport.(*http.Transport).Clone()
	transport.TLSClientConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	transport.MaxIdleConnsPerHost = 8
	transport.ResponseHeaderTimeout = 20 * time.Second
	transport.Proxy = router.proxy
	cdn := newCDNTransport(transport, newDNSResolver(transport))
	d.client = &http.Client{Transport: newHuangguoBrowserTransport(cdn, d), Timeout: 45 * time.Second,
		CheckRedirect: func(request *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("站源重定向次数过多")
			}
			return nil
		}}
	engine := &nativeEngine{downloader: d, directory: directory, catalogs: map[string][]nativeDrama{}, catalogStates: map[string]nativeCatalogState{}}
	engine.covers = newNativeCoverCache(directory, d)
	engine.downloads = newNativeDownloads(engine)
	registerNativeEngine(directory, engine)
	return engine, nil
}

func NativeRequest(raw string) (result string) {
	defer func() {
		if recover() != nil {
			result = `{"ok":false,"error":"本地核心处理失败，请重试"}`
		}
	}()
	var input nativeInput
	if len(raw) > 1<<20 || json.Unmarshal([]byte(raw), &input) != nil {
		return `{"ok":false,"error":"请求格式无效"}`
	}
	data, err := nativeDispatch(input)
	envelope := map[string]any{"ok": err == nil}
	if err != nil {
		envelope["error"] = publicError(err).Error()
		if errors.Is(err, errNativeLocalFile) {
			envelope["code"] = "local_media"
		}
		var backoff *requestBackoff
		if errors.As(err, &backoff) {
			envelope["code"] = "source_blocked"
			envelope["retryAt"] = backoff.until
		}
		source := canonicalProviderSource(input.Source)
		if source == "" {
			source = sourceFromDramaID(input.Drama.ID)
		}
		if !errors.Is(err, context.Canceled) && (input.Action == "catalog" || input.Action == "detail" || input.Action == "resolve") {
			nativeState.Lock()
			engine := nativeState.engine
			nativeState.Unlock()
			if engine != nil && nativeSourceAvailable(source) {
				engine.changeSourceRecord(source, func(record *nativeSourceRecord) {
					record.Error = publicError(err).Error()
					if backoff != nil {
						record.RetryAt = backoff.until
					}
					if !record.Running {
						record.Stage, record.FinishedAt = "访问失败", time.Now()
					}
				})
			}
		}
	} else {
		envelope["data"] = data
	}
	body, marshalErr := json.Marshal(envelope)
	if marshalErr != nil {
		return `{"ok":false,"error":"无法读取站源返回的数据"}`
	}
	return string(body)
}

func nativeDispatch(input nativeInput) (any, error) {
	if err := nativeAuthorizeInput(input); err != nil {
		return nil, err
	}
	nativeState.Lock()
	if input.Action == "initialize" {
		if nativeState.engine == nil {
			engine, err := newNativeEngine(input.Directory)
			if err != nil {
				nativeState.Unlock()
				return nil, err
			}
			nativeState.engine = engine
		}
		nativeState.Unlock()
		return map[string]any{"version": "0.2.94", "standalone": true, "allSources": buildAllSources == "true"}, nil
	}
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil {
		return nil, errors.New("应用核心尚未就绪，请重新打开应用")
	}
	// 磁盘缓存懒加载：第一次真正用到时再读盘（首帧不必等 32 MiB 的 JSON）。
	// flush 只冲刷合并窗里已有的待写快照，不必为此把整份目录读进内存。
	if input.Action != "flush" {
		engine.ensureLoaded()
	}
	duration := 60 * time.Second
	if input.Action == "moveDownloads" {
		duration = 10 * time.Minute
	} else if input.Action == "danmaku" {
		duration = 10 * time.Second
	} else if input.Action == "preload" {
		duration = 15 * time.Second
	} else if input.Action == "webdav" {
		duration = 3 * time.Minute
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	if input.Action == "danmaku" || input.Action == "preload" || input.Action == "prepareHandoff" || input.Session != "" && (input.Action == "catalog" || input.Action == "categories" || input.Action == "suggestions" || input.Action == "recommendations" || input.Action == "metadata") {
		work, finish, err := engine.beginRead(ctx, input)
		if err != nil {
			return nil, err
		}
		defer finish()
		ctx = work
	}
	switch input.Action {
	case "lan":
		return engine.nativeLAN(ctx, input.Command, input.LAN)
	case "webdav":
		return nativeWebDAV(ctx, input.Command, input.WebDAV)
	case "updateSystemProxy":
		return true, engine.updateSystemProxy(input.SystemProxy)
	case "resourceSettings":
		return engine.resourceSettings(), nil
	case "config.source":
		return applySourceConfig(input.SourceConfig)
	case "dongpiandi.officialOnly":
		setDongpiandiOfficialOnly(input.OfficialOnly)
		return true, nil
	case "saveResourceSettings":
		return engine.saveResourceSettings(input.Settings)
	case "controlDownloadBatch":
		return engine.downloads.controlBatchExpected(ctx, input.JobIDs, input.Command, input.ExpectedVersions)
	case "preload":
		return engine.nativePreload(ctx, input)
	case "prepareHandoff":
		return engine.nativeResolve(ctx, input)
	case "danmaku":
		return engine.nativeDanmaku(ctx, input)
	case "cancelRead":
		engine.cancelRead(input)
		return true, nil
	case "flush":
		// 落盘合并窗的强制冲刷：切后台/退出前调用，别让待写快照随进程消失。
		if err := engine.flushCatalogDisk(); err != nil {
			return nil, err
		}
		return true, nil
	case "recommendations":
		return engine.nativeRecommendations(ctx, input)
	case "cachedRecommendations":
		return engine.cachedRecommendations(input.Category)
	case "rankingBoards":
		boards := []rankingBoard{}
		for _, board := range rankingBoards {
			if nativeSourceAvailable(board.Source) {
				boards = append(boards, board)
			}
		}
		return map[string]any{"items": boards}, nil
	case "rankings":
		return engine.nativeRanking(ctx, input)
	case "live.channels":
		return engine.nativeLive(ctx, input)
	case "suggestions":
		items, err := engine.suggestions(ctx, input.Query)
		return map[string]any{"items": items}, err
	case "suggest":
		// 真果·鉴站内搜索建议（带直达播放目标）
		if input.Source != sourceDongpiandi {
			return nil, fmt.Errorf("当前站源不支持搜索建议")
		}
		items, err := engine.downloader.fetchDongpiandiSuggest(ctx, newDongpiandiClient(), input.Query, 8)
		if err != nil {
			return nil, err
		}
		return map[string]any{"items": items}, nil
	case "downloadDirectory":
		engine.downloads.mu.Lock()
		root := engine.downloads.root
		engine.downloads.mu.Unlock()
		return map[string]string{"directory": root}, nil
	case "storage":
		return engine.storage()
	case "moveDownloads":
		return true, engine.moveDownloads(ctx, input.Directory)
	case "workLease":
		count, err := engine.workLease(input.JobID, input.Command)
		return map[string]int{"count": count}, err
	case "downloads":
		jobs, err := engine.downloads.snapshot()
		return map[string]any{"jobs": jobs}, err
	case "enqueueDownloads":
		added, err := engine.downloads.enqueueContext(ctx, input)
		return map[string]int{"added": added}, err
	case "controlDownloads":
		return true, engine.downloads.control(input.JobID, input.Command)
	case "localPlayback":
		plan, _, err := engine.downloads.localPlan(input.Drama.ID, input.Index)
		return plan, err
	case "catalog":
		return engine.nativeCatalog(ctx, input)
	case "cached":
		if !validNativeCategory(canonicalProviderSource(input.Source), input.Category) {
			return nil, errors.New("内容分类无效")
		}
		return engine.nativeCached(nativeCatalogKey(input.Source, input.Category, "")), nil
	case "categories":
		items, err := engine.nativeCategories(ctx, input.Source, input.Force)
		return map[string]any{"items": items}, err
	case "homeFeed":
		return engine.nativeHomeFeed(ctx, input)
	case "homeSection":
		return engine.nativeHomeSection(ctx, input)
	case "homeCalendar":
		return engine.nativeHomeCalendar(ctx, input)
	case "sourceStatus":
		return engine.sourceStatus(input.Source), nil
	case "sourceJob":
		return engine.startSourceTask(input.Source, input.Command, input.Drama)
	case "cancelSourceJob":
		return engine.cancelSourceTask(input.Source), nil
	case "cover":
		return engine.loadCover(ctx, input.Drama, input.Force)
	case "prepareCover":
		return engine.prepareCover(ctx, input.Drama)
	case "detail":
		return engine.nativeDetail(ctx, input.Drama)
	case "metadata":
		return engine.nativeMetadata(ctx, input.Drama)
	// selectPlayback 必须与 resolve/fallback 同列：线路面板点选（含红果清晰度
	// 变体）走的就是它。此前这里只写了内层 if 却漏了 case 分支，请求直接落到
	// default 报「不支持的应用操作」，表现为切线一律不能播放（两个源都中）。
	case "resolve", "fallback", "selectPlayback":
		playback, finish, err := engine.nativeBeginPlayback(ctx, input.Sequence)
		if err != nil {
			return nil, err
		}
		defer finish()
		if input.Action == "fallback" {
			return engine.nativeNextPlayback(playback, input.Session)
		}
		if input.Action == "selectPlayback" {
			return engine.nativeSelectPlayback(playback, input.Session, input.Route)
		}
		return engine.nativeResolve(playback, input)
	case "cancelPlayback":
		engine.nativeCancelPlayback(input.Sequence)
		return true, nil
	case "release":
		engine.nativeReleasePlayback(input.Session)
		return true, nil
	default:
		return nil, errors.New("不支持的应用操作")
	}
}

// applySourceConfig 应用远程下发的站源配置（app_config.json 的 sourceConfig 段，
// 由 Dart 侧拉取远程公告配置后经 config.source 转发）。校验规则：scheme 仅
// http/https、镜像去重后 1-8 个、dongpiandi 根地址为合法根、providerHosts 键
// 必须是核心已知的规范站源（拒收黄果剧/野果与未注册 provider 的榜单专用源）、
// 值为合法根地址；任一字段非法则整段丢弃，保留当前生效值（未热更过即内置兜底）。
// 签名密钥不经此通道下发。
func applySourceConfig(config map[string]any) (any, error) {
	if len(config) == 0 {
		return map[string]any{"applied": false, "reason": "缺少 sourceConfig"}, nil
	}
	applied := 0
	if raw, ok := config["huangguoAIMirrors"]; ok {
		list, ok := raw.([]any)
		if !ok {
			return map[string]any{"applied": false, "reason": "huangguoAIMirrors 类型无效"}, nil
		}
		mirrors, ok := sanitizeSourceMirrorList(list)
		if !ok {
			return map[string]any{"applied": false, "reason": "huangguoAIMirrors 含非法地址"}, nil
		}
		setHuangguoAIMirrors(mirrors)
		applied++
	}
	if raw, ok := config["dongpiandiBaseURL"]; ok {
		text, ok := raw.(string)
		if !ok || !validSourceBaseURL(text) {
			return map[string]any{"applied": false, "reason": "dongpiandiBaseURL 非法"}, nil
		}
		setDongpiandiBaseURL(strings.TrimSuffix(strings.TrimSpace(text), "/"))
		applied++
	}
	// 剧果的 API 域与站点域分离（api.huangju.net vs huangju.net），站点域走
	// providerHosts["huangju"]，API 域必须单独下发，否则换域后接口全死。
	if raw, ok := config["huangjuAPIBaseURL"]; ok {
		text, ok := raw.(string)
		if !ok || !validSourceBaseURL(text) {
			return map[string]any{"applied": false, "reason": "huangjuAPIBaseURL 非法"}, nil
		}
		setHuangjuAPIBase(strings.TrimSuffix(strings.TrimSpace(text), "/"))
		applied++
	}
	if raw, ok := config["providerHosts"]; ok {
		table, ok := raw.(map[string]any)
		if !ok {
			return map[string]any{"applied": false, "reason": "providerHosts 类型无效"}, nil
		}
		hosts, ok := sanitizeProviderHosts(table)
		if !ok {
			return map[string]any{"applied": false, "reason": "providerHosts 含非法条目"}, nil
		}
		setProviderHosts(hosts)
		applied++
	}
	// 自定义 maccms 点播源：用户本机添加，Dart 持久化并每次全量重发；
	// 空列表语义为清空。校验/注册见 custom_sources.go。
	if raw, ok := config["customSources"]; ok {
		list, ok := raw.([]any)
		if !ok {
			return map[string]any{"applied": false, "reason": "customSources 类型无效"}, nil
		}
		if _, err := applyCustomSources(list); err != nil {
			return map[string]any{"applied": false, "reason": err.Error()}, nil
		}
		applied++
	}
	if applied == 0 {
		return map[string]any{"applied": false, "reason": "无可识别字段"}, nil
	}
	return map[string]any{"applied": true}, nil
}

// sanitizeSourceMirrorList 校验镜像列表：字符串、http/https 根地址、去重、上限 8；
// 任一项非法即整体失败（调用方整段丢弃），重复项仅去重不拒绝。
func sanitizeSourceMirrorList(list []any) ([]string, bool) {
	seen := map[string]bool{}
	out := make([]string, 0, len(list))
	for _, item := range list {
		text, ok := item.(string)
		if !ok {
			return nil, false
		}
		// 先规范化（去空白+去尾斜杠）再校验/判重，保证 https://x.com/ 与 https://x.com 视为同一镜像。
		text = strings.TrimSuffix(strings.TrimSpace(text), "/")
		if !validSourceBaseURL(text) {
			return nil, false
		}
		if seen[text] {
			continue
		}
		seen[text] = true
		out = append(out, text)
	}
	if len(out) == 0 || len(out) > 8 {
		return nil, false
	}
	return out, true
}

// sanitizeProviderHosts 校验远程下发的通用源站域名覆盖表（providerHosts 键）：
// 键必须是核心已知的规范站源——douban 等榜单专用源未注册 provider，无法消费；
// 剧果的站点域已由 providerBaseURL 消费（其 API 域另走 sourceConfig.huangjuAPIBaseURL）；
// 野果有自发现且被媒体候选链排除，覆盖只会是死配置，仍拒收；值必须是合法根地址，
// 自动去空白与尾斜杠。任一条目非法即整体失败（调用方整段丢弃）；
// 空表合法，语义为清空覆盖回落内置域名。
func sanitizeProviderHosts(table map[string]any) (map[string]string, bool) {
	out := make(map[string]string, len(table))
	for key, raw := range table {
		text, ok := raw.(string)
		if !ok {
			return nil, false
		}
		text = strings.TrimSuffix(strings.TrimSpace(text), "/")
		if !validSourceBaseURL(text) {
			return nil, false
		}
		source := canonicalProviderSource(key)
		if source == "" || !provider.KnownSource(source) || source == sourceYeguo {
			return nil, false
		}
		out[source] = text
	}
	if len(out) > 32 {
		return nil, false
	}
	return out, true
}

// validSourceBaseURL 校验远程下发的源站根地址：http/https scheme + 非空 host。
func validSourceBaseURL(text string) bool {
	u, err := url.Parse(strings.TrimSpace(text))
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return false
	}
	return true
}

func (engine *nativeEngine) nativeCatalog(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	engine.ensureLoaded()
	source := canonicalProviderSource(input.Source)
	if !isHuangguoProviderSource(source) {
		return nativeCatalogResult{}, errors.New("请选择有效站源")
	}
	category := strings.TrimSpace(input.Category)
	if !validNativeCategory(source, category) {
		return nativeCatalogResult{}, errors.New("内容分类无效")
	}
	sort := normalizeNativeSort(input.Sort)
	cacheKey := nativeCatalogKey(source, category, sort)
	if err := ctx.Err(); err != nil {
		return nativeCatalogResult{}, err
	}
	page := max(1, input.Page)
	query := strings.TrimSpace(input.Query)
	if query == "" {
		if retried, err := engine.retryCatalogSave(); retried {
			cached := engine.nativeCached(cacheKey)
			if err != nil || len(cached.Items) > 0 {
				return cached, nil
			}
		}
	}
	if query == "" && page == 1 && !input.Force {
		if cached := engine.nativeCached(cacheKey); cached.Fresh {
			return cached, nil
		}
	}
	d := engine.downloader
	result := nativeCatalogResult{Items: []nativeDrama{}, Page: page}
	if query != "" && source == sourceHongguo {
		entry, err := d.searchHongguoDramas(ctx, query)
		if err != nil {
			return result, err
		}
		for _, drama := range entry.Dramas {
			result.Items = append(result.Items, nativeNormalize(drama))
		}
		result.Warning, result.Page = entry.Warning, 1
		if entry.Limited && result.Warning == "" {
			result.Warning = "已显示当前可获取的匹配结果，使用更完整的剧名可继续查找"
		}
		return result, nil
	}
	if query != "" && source == sourceHuangju {
		items, more, err := d.fetchHuangjuCatalogPage(ctx, page, "", query)
		if err != nil {
			return result, err
		}
		for _, drama := range items {
			result.Items = append(result.Items, nativeNormalize(drama))
		}
		result.HasMore = more
		return result, nil
	}
	if query != "" && source == sourceYeguo {
		items, more, err := d.fetchYeguoCatalogPage(ctx, page, "", query)
		if err != nil {
			return result, err
		}
		for _, drama := range items {
			result.Items = append(result.Items, nativeNormalize(drama))
		}
		result.HasMore = more
		return result, nil
	}
	if query != "" && isDuanjuProviderSource(source) {
		if !duanjuSupportsSearch(source) {
			return result, fmt.Errorf("%s 暂不支持在线搜索，可在已加载内容中筛选", duanjuSourceName(source))
		}
		items, err := d.searchDuanju(ctx, source, query)
		if err != nil {
			return result, err
		}
		for _, drama := range items {
			result.Items = append(result.Items, nativeNormalize(drama))
		}
		return result, nil
	}
	if query != "" {
		engine.mu.Lock()
		items := append([]nativeDrama{}, engine.catalogs[source]...)
		engine.mu.Unlock()
		for _, item := range items {
			text := hongguoSearchText(item.Title + " " + item.Description + " " + strings.Join(item.Tags, " "))
			matches := true
			for _, word := range strings.Fields(query) {
				matches = matches && strings.Contains(text, hongguoSearchText(word))
			}
			if matches {
				result.Items = append(result.Items, item)
			}
		}
		result.LocalSearch = true
		return result, nil
	}
	unlock, lockErr := engine.lockSourceCatalog(ctx, source)
	if lockErr != nil {
		return nativeCatalogResult{}, lockErr
	}
	defer unlock()
	if err := ctx.Err(); err != nil {
		return result, err
	}
	var items []Drama
	var err error
	switch source {
	case sourceHongguo:
		engine.mu.Lock()
		known := make(map[string]bool, len(engine.catalogs[cacheKey]))
		for _, drama := range engine.catalogs[cacheKey] {
			known[drama.ID] = true
		}
		engine.mu.Unlock()
		ctx = context.WithValue(ctx, libraryKnownKey{}, known)
		if page > 1 {
			ctx = context.WithValue(ctx, libraryMoreKey{}, true)
		}
		items, err = d.fetchHongguoAppCatalogCategory(ctx, category)
		state := d.hongguoCatalogSnapshot()
		result.hongguo = state
		result.HasMore = hongguoCatalogHasMore(state)
		if category != "" && state != nil {
			result.HasMore = !state.Feeds["category:"+category].Exhausted
		}
		if len(items) == 0 && err != nil && ctx.Err() == nil && (category == "" || category == "short_play") {
			var totalPages int
			items, totalPages, err = d.fetchHongguoCategoryPage(ctx, "real-drama?page="+strconv.Itoa(page), "真人剧")
			result.HasMore = page < totalPages
		}
	case sourceHuangdou:
		client := newHuangdouAPIClient(d)
		var decoded any
		err = client.call(ctx, "/drama/list", map[string]any{"page": strconv.Itoa(page), "page_size": "30"}, &decoded)
		if err == nil {
			rows := huangdouList(decoded)
			for _, row := range rows {
				if drama := huangdouDramaFromMap(row); drama.ID != "" {
					items = append(items, drama)
				}
			}
			result.HasMore = len(rows) >= 30
		}
	case sourceHuangguoAI:
		items, result.HasMore, err = d.fetchHuangguoAICatalogPage(ctx, page, category)
	case sourceHuangju:
		// 服务端排序：剧果「全部」页默认 sort=hot（热度），上线日期映射到「最新」
		// 通道 sort=new；views/name/season 留客户端排序。sort 与分类互斥，
		// 分类非空时保持分类语义交给客户端排序。
		huangjuCategory := category
		if category == "" && sort == "date" {
			huangjuCategory = huangjuNewestCategory
		}
		items, result.HasMore, err = d.fetchHuangjuCatalogPage(ctx, page, huangjuCategory, "")
	case sourceYeguo:
		items, result.HasMore, err = d.fetchYeguoCatalogPage(ctx, page, category, "")
	case sourceCloudFront:
		items, result.HasMore, err = d.fetchLegacyCatalogCategoryPage(ctx, page, category)
	default:
		if isDuanjuProviderSource(source) {
			items, result.HasMore, err = d.fetchDuanjuCatalogPage(ctx, source, page, category, sort)
		}
	}
	if err != nil && len(items) == 0 {
		return result, err
	}
	if len(items) == 0 && page == 1 && source != sourceHuangju && source != sourceYeguo && !isDuanjuProviderSource(source) {
		return result, errors.New("站源暂未返回剧集，请稍后刷新")
	}
	if err != nil {
		result.Warning = publicError(err).Error()
	}
	seen := map[string]bool{}
	for _, drama := range items {
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		result.Items = append(result.Items, nativeNormalize(drama))
	}
	engine.saveCatalogCache(cacheKey, &result)
	return result, nil
}

func (engine *nativeEngine) nativeDetail(ctx context.Context, drama nativeDrama) (any, error) {
	source, sourceID, valid := splitProviderDramaID(drama.ID)
	if !valid {
		return nil, errors.New("剧集信息无效，请刷新剧库")
	}
	var title string
	var raw Drama
	var chapters []Chapter
	var err error
	switch source {
	case sourceHuangguoAI:
		raw, chapters, err = engine.downloader.fetchHuangguoAIDetail(ctx, sourceID)
	case sourceCloudFront:
		raw, chapters, err = engine.downloader.fetchLegacyDetail(ctx, sourceID)
	case sourceHuangju:
		raw, chapters, err = engine.downloader.fetchHuangjuDetail(ctx, sourceID)
	case sourceYeguo:
		raw, chapters, err = engine.downloader.fetchYeguoDetail(ctx, sourceID)
	default:
		if isDuanjuProviderSource(source) {
			raw, chapters, err = engine.downloader.fetchDuanjuDetail(ctx, source, sourceID)
			break
		}
		title, chapters, err = engine.downloader.GetHuangguoChapters(ctx, source, sourceID)
	}
	if err != nil {
		return nil, err
	}
	if len(chapters) == 0 {
		return nil, errors.New("该剧暂时没有可播放的分集")
	}
	if title != "" && title != "短剧" {
		drama.Title = title
	}
	if raw.ID == drama.ID {
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHongguo {
		raw := engine.downloader.hongguoCachedDrama(Drama{ID: drama.ID, Title: drama.Title, Source: source})
		drama = mergeNativeDrama(drama, nativeNormalize(raw))
	}
	if source == sourceHuangdou {
		if row, err := engine.downloader.huangdouDetail(ctx, sourceID); err == nil {
			fresh := nativeNormalize(huangdouDramaFromMap(row))
			if fresh.ID == drama.ID {
				drama = mergeNativeDrama(drama, fresh)
			}
		}
	}
	drama.Source, drama.SourceID, drama.Episodes = source, sourceID, len(chapters)
	if source == sourceHuangju || source == sourceYeguo {
		drama.Episodes = max(drama.Episodes, nativeNormalize(raw).Episodes)
	}
	warning := ""
	if err := engine.saveDetailMetadata(drama); err != nil {
		warning = err.Error()
	}
	return map[string]any{"drama": drama, "chapters": chapters, "warning": warning}, nil
}

func (engine *nativeEngine) nativeResolve(ctx context.Context, input nativeInput) (nativePlan, error) {
	if _, _, valid := splitProviderDramaID(input.Drama.ID); !valid {
		return nativePlan{}, errors.New("剧集信息无效")
	}
	if !input.Force && engine.downloads != nil {
		if plan, found, err := engine.downloads.localPlan(input.Drama.ID, input.Index); found || err != nil {
			if input.Action != "prepareHandoff" || !errors.Is(err, errNativeLocalFile) {
				return plan, err
			}
		}
	}
	task := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
	media, err := engine.nativeResolveMedia(ctx, task, input)
	if err != nil {
		return nativePlan{}, err
	}
	choice := nativePlaybackChoices(media, input.Quality)
	// CDN 直链多带短时效签名，播放中途过期时由本机流代理回调这里重新
	// 解析并热替换地址，播放器无感知（见 nativeForward / nativeRenewAsset）。
	choice.refresher = func(ctx context.Context) (providerMedia, error) {
		renewTask := Task{DramaID: input.Drama.ID, DramaTitle: input.Drama.Title, Chapter: input.Chapter, Index: input.Index}
		if source, _, valid := splitProviderDramaID(renewTask.Chapter.ID); valid && source == sourceDongpiandi {
			// 真果·鉴：官方直链是 15 分钟预签名，原地重兑票据即可（约
			// 200ms），比重新解析整条链（1~3s）快一个数量级；失败再回退。
			if media, err := engine.downloader.dongpiandiRenewMedia(ctx, renewTask); err == nil {
				return media, nil
			}
		}
		return engine.downloader.resolveProviderMedia(ctx, renewTask)
	}
	if danmakuSource, series, video, valid := danmakuPlaybackIDs(task); valid {
		choice.danmakuSource, choice.danmakuSeries, choice.danmakuVideo = danmakuSource, series, video
		// 真果·鉴的剧集维度弹幕 ID 恰好也是详情 ID，顺手查社区跳过预设
		//（详情/线路刷新拉取时已写入缓存，这里只读不打网络）。
		if danmakuSource == sourceDongpiandi {
			if preset, ok := dongpiandiCachedSkipPreset(series); ok {
				choice.skipIntro = int(preset.IntroEndSeconds + 0.5)
				choice.skipOutroFromEnd = int(preset.OutroFromEndSeconds + 0.5)
			}
		}
	}
	// 跨源：其他站源的剧按剧名借真果·鉴的社区跳过预设（只读缓存零网络，
	// 未命中后台静默补映射，下一集/下次播放生效）。真果·鉴本源走上面的
	// 分支，不再重复。
	if source, _, valid := splitProviderDramaID(input.Drama.ID); valid && source != sourceDongpiandi {
		engine.downloader.dongpiandiBridgeApplySkip(input.Drama.Title, &choice)
	}
	return engine.nativeOpenPlayback(ctx, choice)
}

// nativeResolveCacheTTL 是解析结果的缓存时长。短时效签名地址过期后会
// 由本机流代理的重签路径兜底，缓存只影响「同一集短时间内重复解析」。
const nativeResolveCacheTTL = 5 * time.Minute

// nativeResolveMedia 解析媒体信息，命中 5 分钟缓存则直接复用。
func (engine *nativeEngine) nativeResolveMedia(ctx context.Context, task Task, input nativeInput) (providerMedia, error) {
	key := nativeResolveCacheKey(task, input)
	if !input.Force && key != "" {
		engine.resolveCacheMu.Lock()
		if engine.resolveCache != nil {
			if entry, found := engine.resolveCache[key]; found && time.Now().Before(entry.expireAt) {
				engine.resolveCacheMu.Unlock()
				return entry.media, nil
			}
			delete(engine.resolveCache, key)
		}
		engine.resolveCacheMu.Unlock()
	}
	media, err := engine.downloader.resolveProviderMedia(ctx, task)
	if err != nil {
		return providerMedia{}, err
	}
	if key != "" {
		engine.resolveCacheMu.Lock()
		if engine.resolveCache == nil {
			engine.resolveCache = map[string]nativeResolveCacheEntry{}
		}
		engine.resolveCache[key] = nativeResolveCacheEntry{media: media, expireAt: time.Now().Add(nativeResolveCacheTTL)}
		engine.resolveCacheMu.Unlock()
	}
	return media, nil
}

// nativeResolveCacheKey 生成解析缓存键；无法稳定标识时返回空串（不缓存）。
func nativeResolveCacheKey(task Task, input nativeInput) string {
	reference := task.Chapter.VideoURL
	if reference == "" {
		return ""
	}
	return task.DramaID + "|" + reference + "|" + strconv.Itoa(task.Index) + "|" + strconv.Itoa(input.Quality)
}
