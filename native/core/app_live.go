package core

// 电视直播（2026-10-22）：独立于站源体系的 m3u/m3u8 直播列表功能。
// 数据面：内置双列表（候选 URL 逐个回退容灾）+ 用户自填源（Dart 经 liveUrls 传入），
// 解析 #EXTINF tvg-logo group-title 与「名称,URL」txt 两种格式，按分组返回频道。
// 缓存照 rankings 模式（内存 + 磁盘 + TTL + 在途去重）；播放走既有 mpv 管线，
// 频道携带多线路（同名频道多 URL），播放端按序重试。

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	liveCacheTTL        = 6 * time.Hour
	liveMaxBodyBytes    = 16 << 20 // 16MB
	liveMaxChannels     = 3000     // 单列表频道上限
	liveMaxGroups       = 300      // 分组数上限
	liveMaxURLs         = 8        // 每频道最多线路数
	liveMaxCacheEntries = 32       // 磁盘缓存条目上限（内置 2 + 自填源）
	liveMaxCacheBytes   = 12 << 20 // 磁盘缓存文件上限
	// 自填订阅并发与总预算：以前串行拉取，N 条订阅里只要有几条黑洞地址，
	// 打开直播页就要等 N × 15s，且期间整页是 loading。
	liveCustomFetchParallel = 4
	liveCustomTotalBudget   = 20 * time.Second
)

const liveUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

// liveAdWords 广告/购物类频道名关键词：命中（频道名或分组名）整频道剔除。
// 2026-10-22 探针实测 iptvorg「国际中文」列表混有四川星空购物/家有购物等 6 个购物频道；
// 2026-10-23 重放实测 vbskycn 央视组混入「支持作者」筹资宣传频道、guovin 电影组混入
// 淘剧场/淘娱乐/淘电影购物导视频道。
var liveAdWords = []string{
	"广告", "购物", "推广", "促销", "推销", "招商", "网购", "电商", "团购", "代购", "导购", "商城", "带货", "秒杀",
	"支持作者", "淘剧场", "淘娱乐", "淘电影",
}

// liveVODHostWords 点播平台 CDN 域名词：部分列表把快手等点播 CDN 的广告循环/原始
// MP4 伪造成卫视直播线路（guovin 列表湖南/广东卫视首线路均为 txmov2.a.kwimgs.com，
// 点开即广告）——直播型频道剔除这类线路；这些 URL 为静态路径无签名时效，剔除不会
// 误杀其他有效内容。
// 2026-10-23 增补 metshop.top：重放取证该域名挂 ~66 个片名伪频道（周星驰电影/
// 人在囧途/七龙珠/海绵宝宝等），零正规电视台频道，纯片名点播源站。
var liveVODHostWords = []string{
	"kwimgs.com", "kuaishou", "yximgs.com", "douyinvod.com", "douyinpic.com", "amemv.com",
	"bilivideo.com", "hdslb.com", "ixigua.com", "toutiaovod.com", "bytecdn.cn", "metshop.top",
}

// liveReplayKeywords 回放型频道豁免：春晚/经典戏曲等频道的点播 CDN 线路是有意内容，
// 保留不剔。2026-10-23 收窄：「电影」「点播」从豁免移除——重放实测 vbskycn 电影频道组
// ~80 个片名伪频道（周星驰电影/人在囧途等）全靠频道名含「电影」豁免 kwimgs 点播线路
// 逃过过滤；正规电影频道（CHC/东森/CCTV-6）用的是运营商 CDN，不受影响。
var liveReplayKeywords = []string{"春晚", "回放", "戏曲", "纪录片", "剧场"}

func liveTextHasAny(text string, words []string) bool {
	if text == "" {
		return false
	}
	for _, word := range words {
		if strings.Contains(text, word) {
			return true
		}
	}
	return false
}

// liveBuiltInLists 内置直播列表：候选按序回退——直连（手机网络可达）优先，
// jsdelivr / gh-proxy 镜像兜底（域名被 DNS 污染时仍可取到列表）。
// 2026-10-22 二轮真网探测（probe4）：guovin result.m3u 仍为最稳默认（真机 CCTV-1/3
// 播放通过）；新增 vbskycn iptv4.m3u（484 频道，双镜像均 200）、iptv-org cn.m3u（511 条）、
// YanG-1989 Gather.m3u（123 条）三个存活备选；fanmingming 原站直连超时确认死亡，
// 降为末位仅留镜像候选（其 ipv6 流地址在移动网络下仍可能被 CDN 403）。
// 2026-10-23 新增自托管「星微精选」置顶（lives/xingwei.m3u，835 频道）：包内测速
// top-3 线路、广告/点播 CDN 词表已按 app_live.go 三表净化，首位即成为 app 默认列表。
var liveBuiltInLists = []liveListDef{
	{
		ID:   "xingwei",
		Name: "星微精选",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/guocheng1378/guoapp@main/lives/xingwei.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/guocheng1378/guoapp/main/lives/xingwei.m3u",
		},
	},
	{
		ID:   "guovin",
		Name: "精选列表",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/Guovin/iptv-api@gd/output/result.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/Guovin/iptv-api/gd/output/result.m3u",
		},
	},
	{
		ID:   "vbskycn",
		Name: "央视卫视",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/vbskycn/iptv@master/tv/iptv4.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/vbskycn/iptv/master/tv/iptv4.m3u",
		},
	},
	{
		ID:   "iptvorg",
		Name: "国际中文",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/iptv-org/iptv@master/streams/cn.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/iptv-org/iptv/master/streams/cn.m3u",
		},
	},
	{
		ID:   "yang1989",
		Name: "咪咕聚合",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/YanG-1989/m3u@main/Gather.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/YanG-1989/m3u/main/Gather.m3u",
		},
	},
	{
		ID:   "fanmingming",
		Name: "IPv6 备用",
		Candidates: []string{
			"https://cdn.jsdelivr.net/gh/fanmingming/live@main/tv/m3u/ipv6.m3u",
			"https://gh-proxy.com/https://raw.githubusercontent.com/fanmingming/live/main/tv/m3u/ipv6.m3u",
		},
	},
}

type liveListDef struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// Candidates 按序回退，全部失败视为列表获取失败。
	Candidates []string `json:"-"`
}

func findLiveListDef(id string) (liveListDef, bool) {
	for _, def := range liveBuiltInLists {
		if def.ID == id {
			return def, true
		}
	}
	return liveListDef{}, false
}

type liveChannel struct {
	Name  string `json:"name"`
	Group string `json:"group,omitempty"`
	Logo  string `json:"logo,omitempty"`
	// TVGID 是 m3u 的 tvg-id，EPG 匹配的第一优先级；txt/json 订阅通常没有。
	TVGID string   `json:"tvgId,omitempty"`
	URLs  []string `json:"urls"`
}

// liveSourceInput 是 Dart 侧 live.channels 的新通道条目：URL 订阅可带自定义
// 请求头；Payload 非空表示配置里内嵌的频道正文，直接解析不发起 HTTP。
type liveSourceInput struct {
	URL     string            `json:"url"`
	Headers map[string]string `json:"headers"`
	Payload string            `json:"payload"`
}

// sanitizeLiveHeaders 与自定义站源同口径：限条数/长度、防 CRLF 注入、
// 禁覆盖 Host/Content-Length。非法条目静默丢弃而非拖垮整份列表。
func sanitizeLiveHeaders(raw map[string]string) map[string]string {
	if len(raw) == 0 {
		return nil
	}
	out := make(map[string]string, len(raw))
	keys := make([]string, 0, len(raw))
	for key := range raw {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		name := strings.TrimSpace(key)
		text := strings.TrimSpace(raw[key])
		if name == "" || len(name) > 64 || len(text) > 512 ||
			strings.ContainsAny(name, "\r\n") || strings.ContainsAny(text, "\r\n") {
			continue
		}
		lower := strings.ToLower(name)
		if lower == "host" || lower == "content-length" {
			continue
		}
		out[name] = text
		if len(out) >= 8 {
			break
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

// liveHeaderCacheSuffix 让同一 URL 配不同请求头时各用独立缓存，避免串味。
func liveHeaderCacheSuffix(headers map[string]string) string {
	if len(headers) == 0 {
		return ""
	}
	keys := make([]string, 0, len(headers))
	for key := range headers {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	var builder strings.Builder
	for _, key := range keys {
		builder.WriteString(key)
		builder.WriteByte('=')
		builder.WriteString(headers[key])
		builder.WriteByte(';')
	}
	sum := sha256.Sum256([]byte(builder.String()))
	return "|" + hex.EncodeToString(sum[:4])
}

type liveGroup struct {
	Name     string        `json:"name"`
	Channels []liveChannel `json:"channels"`
}

type liveListEntry struct {
	Key       string        `json:"key"`
	Channels  []liveChannel `json:"channels"`
	FetchedAt time.Time     `json:"fetchedAt"`
}

type liveCall struct {
	done  chan struct{}
	entry liveListEntry
	err   error
}

type liveCache struct {
	mu         sync.Mutex
	entries    map[string]liveListEntry
	pending    map[string]*liveCall
	lastWrite  time.Time
	dirty      bool
	writeTimer *time.Timer
}

func (d *Downloader) liveFileName() string {
	// 直播清单是订阅源拉回来的可重建缓存（6h TTL），跟着系统缓存目录走。
	return filepath.Join(d.cfg.cachePath(), "live_cache.json")
}

func (d *Downloader) loadLiveCache() {
	d.liveOnce.Do(d.loadLiveCacheLocked)
}

func (d *Downloader) loadLiveCacheLocked() {
	d.live.entries, d.live.pending = map[string]liveListEntry{}, map[string]*liveCall{}
	data, err := os.ReadFile(d.liveFileName())
	if err != nil || len(data) == 0 {
		return
	}
	var file struct {
		Version int `json:"version"`
		Entries map[string]struct {
			Key       string        `json:"key"`
			Channels  []liveChannel `json:"channels"`
			FetchedAt time.Time     `json:"fetchedAt"`
		} `json:"entries"`
	}
	if err := json.Unmarshal(data, &file); err != nil || file.Version != 1 || len(file.Entries) == 0 {
		return
	}
	entries := make(map[string]liveListEntry, len(file.Entries))
	for key, item := range file.Entries {
		if key == "" || item.Key != key || len(item.Channels) == 0 {
			continue
		}
		if len(item.Channels) > liveMaxChannels || time.Since(item.FetchedAt) > 7*24*time.Hour {
			continue
		}
		// 旧版本落盘的缓存可能含广告频道/伪直播线路：恢复时统一净化。
		channels := filterLiveChannels(item.Channels)
		if len(channels) == 0 {
			continue
		}
		entries[key] = liveListEntry{Key: key, Channels: channels, FetchedAt: item.FetchedAt}
		if len(entries) >= liveMaxCacheEntries {
			break
		}
	}
	if len(entries) == 0 {
		return
	}
	d.live.mu.Lock()
	d.live.entries = entries
	d.live.mu.Unlock()
}

// scheduleLiveWrite 合并写盘：300ms 合并窗内的多次标记只落一次盘（照 rankings 模式）。
func (d *Downloader) scheduleLiveWriteLocked() {
	if d.live.writeTimer != nil {
		return
	}
	d.live.writeTimer = time.AfterFunc(300*time.Millisecond, d.flushLiveCache)
}

func (d *Downloader) flushLiveCache() {
	d.live.mu.Lock()
	defer d.live.mu.Unlock()
	d.flushLiveCacheLocked()
}

func (d *Downloader) flushLiveCacheLocked() {
	if d.live.writeTimer != nil {
		d.live.writeTimer.Stop()
		d.live.writeTimer = nil
	}
	if !d.live.dirty {
		return
	}
	if len(d.live.entries) == 0 {
		return
	}
	if !d.live.lastWrite.IsZero() && time.Since(d.live.lastWrite) < 200*time.Millisecond {
		if d.live.writeTimer == nil {
			d.live.writeTimer = time.AfterFunc(300*time.Millisecond, d.flushLiveCache)
		}
		return
	}
	file := struct {
		Version int                      `json:"version"`
		Entries map[string]liveListEntry `json:"entries"`
	}{Version: 1, Entries: d.live.entries}
	data, err := json.Marshal(file)
	if err == nil && len(data) > liveMaxCacheBytes {
		// 超限先按最旧裁剪再重试。以前这里直接 return 且保留 dirty，一旦越线，
		// 整份直播缓存（含内置列表）就永久不再落盘，重启只能全量重拉。
		d.trimLiveCacheLocked(len(data))
		file.Entries = d.live.entries
		data, err = json.Marshal(file)
	}
	if err != nil || len(data) > liveMaxCacheBytes {
		return
	}
	if err := writeNativeCacheFile(d.liveFileName(), data); err == nil {
		d.live.dirty = false
		d.live.lastWrite = time.Now()
	}
	// 写失败保留 dirty，由下次标记或进程退出前的落盘重试。
}

// evictLiveEntriesLocked 在写入新条目之前维持条目数上限；调用方须持锁。
func (d *Downloader) evictLiveEntriesLocked() {
	count := len(d.live.entries)
	if count < liveMaxCacheEntries {
		return
	}
	type liveCacheAge struct {
		key       string
		fetchedAt time.Time
	}
	ages := make([]liveCacheAge, 0, count)
	for key, entry := range d.live.entries {
		ages = append(ages, liveCacheAge{key: key, fetchedAt: entry.FetchedAt})
	}
	sort.Slice(ages, func(i, j int) bool { return ages[i].fetchedAt.Before(ages[j].fetchedAt) })
	remove := count - liveMaxCacheEntries + 1
	for i := 0; i < remove && i < len(ages); i++ {
		delete(d.live.entries, ages[i].key)
	}
}

// trimLiveCacheLocked 按体积把条目裁到上限的 90% 以内；调用方须持锁。
func (d *Downloader) trimLiveCacheLocked(size int) {
	count := len(d.live.entries)
	if count <= 1 || size <= liveMaxCacheBytes {
		return
	}
	keep := int(int64(count) * int64(liveMaxCacheBytes) * 9 / (int64(size) * 10))
	if keep < 1 {
		keep = 1
	}
	if keep >= count {
		keep = count - 1
	}
	type liveCacheAge struct {
		key       string
		fetchedAt time.Time
	}
	ages := make([]liveCacheAge, 0, count)
	for key, entry := range d.live.entries {
		ages = append(ages, liveCacheAge{key: key, fetchedAt: entry.FetchedAt})
	}
	sort.Slice(ages, func(i, j int) bool { return ages[i].fetchedAt.Before(ages[j].fetchedAt) })
	for i := 0; i < count-keep; i++ {
		delete(d.live.entries, ages[i].key)
	}
}

func (d *Downloader) fetchLiveText(ctx context.Context, url string) (string, error) {
	return d.fetchLiveTextWithHeaders(ctx, url, nil)
}

// fetchLiveTextWithHeaders 支持自填订阅的防盗链头；headers 里的
// User-Agent 会覆盖默认的 liveUserAgent。
func (d *Downloader) fetchLiveTextWithHeaders(ctx context.Context, url string, headers map[string]string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", liveUserAgent)
	req.Header.Set("Accept", "*/*")
	for key, value := range sanitizeLiveHeaders(headers) {
		req.Header.Set(key, value)
	}
	resp, err := d.doCatalogRequestWithTimeout(req, 15*time.Second)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("直播列表请求失败：%s", resp.Status)
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, liveMaxBodyBytes+1))
	if err != nil {
		return "", err
	}
	if len(body) > liveMaxBodyBytes {
		return "", errors.New("直播列表过大")
	}
	text := strings.TrimPrefix(string(body), "\ufeff")
	return text, nil
}

// loadLiveList 按 key 取列表：内存缓存 → TTL 内直接返回；过期则取盘缓存的过期值兜底并在
// 后台/前台重取（在途去重）；force 绕过 TTL。返回 (entry, 是否过期兜底, error)。
func (d *Downloader) loadLiveList(ctx context.Context, key string, candidates []string, force bool) (liveListEntry, bool, error) {
	return d.loadLiveListWithHeaders(ctx, key, candidates, force, nil)
}

func (d *Downloader) loadLiveListWithHeaders(ctx context.Context, key string, candidates []string, force bool, headers map[string]string) (liveListEntry, bool, error) {
	d.live.mu.Lock()
	entry, ok := d.live.entries[key]
	if !force && ok && time.Since(entry.FetchedAt) < liveCacheTTL {
		// 内存命中也要过一遍净化：同进程内新导入的自填源可能带广告频道/
		// 点播伪直播线路，以前只有重启读盘时才净化，脏数据会挂满整个 TTL。
		entry.Channels = filterLiveChannels(entry.Channels)
		d.live.entries[key] = entry
		d.live.mu.Unlock()
		return entry, false, nil
	}
	if call, pending := d.live.pending[key]; pending {
		d.live.mu.Unlock()
		select {
		case <-call.done:
			if call.err == nil {
				return call.entry, false, nil
			}
			if ok {
				return entry, true, nil
			}
			return liveListEntry{}, false, call.err
		case <-ctx.Done():
			return liveListEntry{}, false, ctx.Err()
		}
	}
	call := &liveCall{done: make(chan struct{})}
	d.live.pending[key] = call
	d.live.mu.Unlock()

	defer func() {
		d.live.mu.Lock()
		delete(d.live.pending, key)
		d.live.mu.Unlock()
	}()

	fetched, err := d.fetchLiveListCandidatesWithHeaders(ctx, candidates, headers)
	if err != nil {
		call.err = err
		close(call.done)
		if ok {
			return entry, true, nil
		}
		return liveListEntry{}, false, err
	}
	fetched.Key = key
	call.entry = fetched
	close(call.done)

	d.live.mu.Lock()
	if d.live.entries == nil {
		d.live.entries = map[string]liveListEntry{}
	}
	// 写入前先按最旧淘汰，避免自填源/订阅无限增长（以前只有读盘时才截断，
	// 进程内 entries 可以一直涨）。
	d.evictLiveEntriesLocked()
	d.live.entries[key] = fetched
	d.live.dirty = true
	d.scheduleLiveWriteLocked()
	d.live.mu.Unlock()
	return fetched, false, nil
}

func (d *Downloader) fetchLiveListCandidates(ctx context.Context, candidates []string) (liveListEntry, error) {
	return d.fetchLiveListCandidatesWithHeaders(ctx, candidates, nil)
}

func (d *Downloader) fetchLiveListCandidatesWithHeaders(ctx context.Context, candidates []string, headers map[string]string) (liveListEntry, error) {
	var lastErr error
	for _, url := range candidates {
		text, err := d.fetchLiveTextWithHeaders(ctx, url, headers)
		if err == nil {
			if channels := filterLiveChannels(mergeLiveChannels(parseLivePlaylist(text))); len(channels) > 0 {
				return liveListEntry{Channels: channels, FetchedAt: time.Now()}, nil
			}
			err = errors.New("直播列表没有可用频道")
		}
		lastErr = err
		if ctx.Err() != nil {
			break
		}
	}
	if lastErr == nil {
		lastErr = errors.New("直播列表候选为空")
	}
	return liveListEntry{}, lastErr
}

// ---------- 解析 ----------

var liveAttrPatterns = []*regexp.Regexp{
	regexp.MustCompile(`([a-zA-Z0-9_-]+)\s*=\s*"([^"]*)"`),
	regexp.MustCompile(`([a-zA-Z0-9_-]+)\s*=\s*'([^']*)'`),
}

func liveSchemeValid(raw string) bool {
	lower := strings.ToLower(raw)
	for _, scheme := range []string{"http://", "https://", "rtmp://", "rtsp://", "rtp://", "udp://", "p3p://"} {
		if strings.HasPrefix(lower, scheme) {
			return true
		}
	}
	return false
}

func liveValidURL(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" || len(raw) > 2048 || strings.ContainsAny(raw, " \t\r\n") {
		return false
	}
	return liveSchemeValid(raw)
}

// parseLiveExtinf 解析 EXTINF 行：先找最后一个不在引号内的逗号切出标题，剩余部分提取属性。
// tvg-id 单独返回（EPG 主键），其余属性顺序不变以免影响既有调用方语义。
func parseLiveExtinf(rest string) (name, logo, group, tvgID string) {
	inQuote := false
	lastComma := -1
	for i := 0; i < len(rest); i++ {
		switch rest[i] {
		case '"':
			inQuote = !inQuote
		case ',':
			if !inQuote {
				lastComma = i
			}
		}
	}
	attrPart := rest
	title := ""
	if lastComma >= 0 {
		attrPart = rest[:lastComma]
		title = strings.TrimSpace(rest[lastComma+1:])
	}
	for _, pattern := range liveAttrPatterns {
		for _, match := range pattern.FindAllStringSubmatch(attrPart, -1) {
			switch strings.ToLower(match[1]) {
			case "tvg-logo":
				if logo == "" {
					logo = strings.TrimSpace(match[2])
				}
			case "group-title":
				if group == "" {
					group = strings.TrimSpace(match[2])
				}
			case "tvg-name":
				if name == "" {
					name = strings.TrimSpace(match[2])
				}
			case "tvg-id":
				if tvgID == "" {
					tvgID = strings.TrimSpace(match[2])
				}
			}
		}
	}
	if title != "" {
		name = title
	}
	return name, logo, group, tvgID
}

// parseLivePlaylist 支持 m3u（#EXTM3U）、「名称,URL」「分组,#genre#」txt，
// 以及 TVBox 常见的 JSON 频道列表（含 lives[].channels 内嵌结构）。
func parseLivePlaylist(body string) []liveChannel {
	body = strings.TrimSpace(strings.TrimPrefix(body, "\ufeff"))
	if body == "" {
		return nil
	}
	if strings.HasPrefix(body, "{") || strings.HasPrefix(body, "[") {
		if channels := parseLiveJSON(body); len(channels) > 0 {
			return channels
		}
	}
	if strings.Contains(body, "#EXTM3U") {
		return parseLiveM3U(body)
	}
	return parseLiveTXT(body)
}

// parseLiveJSON 解析 JSON 订阅：顶层数组或含 channels/lives/list/data 的对象。
// lives[] 里只有 url（指向另一份 m3u/txt 订阅）而无播放线路的条目会被跳过，
// 避免把订阅链接误当成频道线路。
func parseLiveJSON(body string) []liveChannel {
	var root any
	if err := json.Unmarshal([]byte(body), &root); err != nil {
		return nil
	}
	channels := make([]liveChannel, 0)
	var walk func(raw any, group string, livesContext bool)
	walk = func(raw any, group string, livesContext bool) {
		list, ok := raw.([]any)
		if !ok {
			return
		}
		for _, item := range list {
			if len(channels) >= liveMaxChannels {
				return
			}
			entry, ok := item.(map[string]any)
			if !ok {
				continue
			}
			if nested, exists := entry["channels"]; exists {
				nestedGroup := group
				for _, key := range []string{"group", "groupName", "name"} {
					if text := firstLiveString(entry, key); text != "" {
						nestedGroup = text
						break
					}
				}
				walk(nested, nestedGroup, false)
				continue
			}
			if livesContext && entry["urls"] == nil && entry["lines"] == nil {
				continue
			}
			name := firstLiveString(entry, "name", "title")
			if name == "" {
				continue
			}
			urls := liveJSONURLs(entry["urls"])
			if len(urls) == 0 {
				urls = liveJSONURLs(entry["lines"])
			}
			if len(urls) == 0 {
				urls = liveJSONURLs(entry["url"])
			}
			if len(urls) == 0 {
				continue
			}
			rowGroup := group
			if text := firstLiveString(entry, "group", "groupName"); text != "" {
				rowGroup = text
			}
			channels = append(channels, liveChannel{
				Name:  name,
				Group: rowGroup,
				Logo:  firstLiveString(entry, "logo", "tvg-logo"),
				TVGID: firstLiveString(entry, "tvg-id", "tvgid", "tvgId"),
				URLs:  urls,
			})
		}
	}
	switch typed := root.(type) {
	case []any:
		walk(typed, "", false)
	case map[string]any:
		for _, key := range []string{"channels", "lives", "list", "data"} {
			if value, ok := typed[key]; ok {
				walk(value, "", key == "lives")
			}
		}
	}
	return channels
}

func firstLiveString(entry map[string]any, keys ...string) string {
	for _, key := range keys {
		if text, ok := entry[key].(string); ok && strings.TrimSpace(text) != "" {
			return strings.TrimSpace(text)
		}
	}
	return ""
}

func liveJSONURLs(raw any) []string {
	var values []string
	switch typed := raw.(type) {
	case string:
		for _, part := range strings.Split(typed, "#") {
			values = append(values, strings.TrimSpace(part))
		}
	case []any:
		for _, item := range typed {
			if text, ok := item.(string); ok {
				values = append(values, strings.TrimSpace(text))
			}
		}
	}
	out := make([]string, 0, len(values))
	for _, value := range values {
		if liveValidURL(value) {
			out = append(out, value)
		}
		if len(out) >= liveMaxURLs {
			break
		}
	}
	return out
}

func parseLiveM3U(body string) []liveChannel {
	var channels []liveChannel
	name, logo, group, tvgID, pending := "", "", "", "", false
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if strings.HasPrefix(line, "#EXTINF:") {
				name, logo, group, tvgID = parseLiveExtinf(strings.TrimPrefix(line, "#EXTINF:"))
				pending = true
			}
			continue
		}
		if !pending || !liveValidURL(line) {
			continue
		}
		if name == "" {
			name = liveNameFromURL(line)
		}
		channels = append(channels, liveChannel{Name: name, Group: group, Logo: logo, TVGID: tvgID, URLs: []string{strings.TrimSpace(line)}})
		name, logo, group, tvgID, pending = "", "", "", "", false
		if len(channels) >= liveMaxChannels {
			break
		}
	}
	return channels
}

// parseLiveTXT 解析「分组,#genre#」+「频道名,URL#URL2」txt 直播源格式。
func parseLiveTXT(body string) []liveChannel {
	var channels []liveChannel
	currentGroup := ""
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		comma := strings.Index(line, ",")
		if comma <= 0 {
			continue
		}
		label := strings.TrimSpace(line[:comma])
		rest := strings.TrimSpace(line[comma+1:])
		if rest == "#genre#" {
			currentGroup = label
			continue
		}
		urls := make([]string, 0, 4)
		for _, part := range strings.Split(rest, "#") {
			if liveValidURL(part) {
				urls = append(urls, strings.TrimSpace(part))
			}
		}
		if label == "" || len(urls) == 0 {
			continue
		}
		channels = append(channels, liveChannel{Name: label, Group: currentGroup, URLs: urls})
		if len(channels) >= liveMaxChannels {
			break
		}
	}
	return channels
}

func liveNameFromURL(raw string) string {
	raw = strings.TrimRight(raw, "/")
	if idx := strings.LastIndexAny(raw, "/"); idx >= 0 {
		raw = raw[idx+1:]
	}
	raw = strings.TrimSuffix(raw, ".m3u8")
	raw = strings.TrimSuffix(raw, ".m3u")
	if raw == "" {
		return "未命名频道"
	}
	return raw
}

// filterLiveChannels 直播列表净化（2026-10-23 广告修复）：
// ① 频道名/分组名命中广告词（购物台等）整频道剔除；
// ② 直播型频道的点播平台 CDN 线路剔除（点播循环被列表伪造成第 1 条直播线路，
//
//	点开即广告），回放型频道（春晚/电影等）豁免保留；线路剔光的频道整体删除。
//
// 在「拉取解析」与「磁盘缓存恢复」两处接线，保证 6h TTL 内旧数据同样净化。
func filterLiveChannels(channels []liveChannel) []liveChannel {
	filtered := make([]liveChannel, 0, len(channels))
	for _, ch := range channels {
		if liveTextHasAny(ch.Name, liveAdWords) || liveTextHasAny(ch.Group, liveAdWords) {
			continue
		}
		replay := liveTextHasAny(ch.Name, liveReplayKeywords) || liveTextHasAny(ch.Group, liveReplayKeywords)
		if !replay {
			urls := make([]string, 0, len(ch.URLs))
			for _, u := range ch.URLs {
				if liveTextHasAny(strings.ToLower(u), liveVODHostWords) {
					continue
				}
				urls = append(urls, u)
			}
			if len(urls) == 0 {
				continue
			}
			ch.URLs = urls
		}
		filtered = append(filtered, ch)
	}
	return filtered
}

// mergeLiveChannels 同分组同名频道合并多线路（保留首见顺序，URL 去重，线路数封顶）。
func mergeLiveChannels(channels []liveChannel) []liveChannel {
	type key struct{ group, name string }
	order := make([]key, 0, len(channels))
	index := make(map[key]int, len(channels))
	urlSeen := make(map[string]bool)
	merged := make([]liveChannel, 0, len(channels))
	for _, ch := range channels {
		k := key{group: ch.Group, name: ch.Name}
		urls := make([]string, 0, len(ch.URLs))
		for _, u := range ch.URLs {
			if u == "" || urlSeen[u] || len(urls) >= liveMaxURLs {
				continue
			}
			urlSeen[u] = true
			urls = append(urls, u)
		}
		if len(urls) == 0 {
			continue
		}
		if idx, ok := index[k]; ok {
			slot := &merged[idx]
			if slot.TVGID == "" {
				slot.TVGID = ch.TVGID
			}
			for _, u := range urls {
				if len(slot.URLs) >= liveMaxURLs {
					break
				}
				slot.URLs = append(slot.URLs, u)
			}
			continue
		}
		index[k] = len(merged)
		order = append(order, k)
		merged = append(merged, liveChannel{Name: ch.Name, Group: ch.Group, Logo: ch.Logo, TVGID: ch.TVGID, URLs: urls})
	}
	return merged
}

// liveGroupsFromLists 把多份频道列表合并分组：内置列表在前（首见分组顺序），自填源追加在后；
// 跨列表同名同分组频道合并线路；全列表 URL 去重。
func liveGroupsFromLists(lists ...[]liveChannel) ([]liveGroup, int) {
	groupIndex := make(map[string]int)
	urlSeen := make(map[string]bool)
	groups := make([]liveGroup, 0, 32)
	total := 0
	appendChannel := func(ch liveChannel) {
		if total >= liveMaxChannels {
			return
		}
		if ch.Group == "" {
			ch.Group = "其他频道"
		}
		idx, ok := groupIndex[ch.Group]
		if !ok {
			if len(groups) >= liveMaxGroups {
				ch.Group = "其他频道"
				idx, ok = groupIndex[ch.Group]
			}
			if !ok {
				idx = len(groups)
				groupIndex[ch.Group] = idx
				groups = append(groups, liveGroup{Name: ch.Group, Channels: make([]liveChannel, 0, 8)})
			}
		}
		slot := &groups[idx]
		for i := range slot.Channels {
			if slot.Channels[i].Name != ch.Name {
				continue
			}
			appended := false
			if slot.Channels[i].TVGID == "" {
				slot.Channels[i].TVGID = ch.TVGID
			}
			for _, u := range ch.URLs {
				if urlSeen[u] || len(slot.Channels[i].URLs) >= liveMaxURLs {
					continue
				}
				urlSeen[u] = true
				slot.Channels[i].URLs = append(slot.Channels[i].URLs, u)
				appended = true
			}
			if appended {
				total++
			}
			return
		}
		if len(slot.Channels) >= liveMaxChannels {
			return
		}
		urls := make([]string, 0, len(ch.URLs))
		for _, u := range ch.URLs {
			if urlSeen[u] {
				continue
			}
			urlSeen[u] = true
			urls = append(urls, u)
		}
		if len(urls) == 0 {
			return
		}
		slot.Channels = append(slot.Channels, liveChannel{Name: ch.Name, Group: ch.Group, Logo: ch.Logo, TVGID: ch.TVGID, URLs: urls})
		total++
	}
	for _, list := range lists {
		for _, ch := range list {
			appendChannel(ch)
		}
	}
	return groups, total
}

// ---------- dispatch ----------

// nativeLive 处理 live.channels：按 listId 取内置列表 + 合并 liveUrls 自填源。
func (engine *nativeEngine) nativeLive(ctx context.Context, input nativeInput) (any, error) {
	engine.ensureLoaded()
	d := engine.downloader
	listID := strings.TrimSpace(input.ListID)
	if listID == "" {
		listID = liveBuiltInLists[0].ID
	}
	def, ok := findLiveListDef(listID)
	if !ok {
		return nil, fmt.Errorf("未知的直播列表：%s", listID)
	}
	var lists []liveListDef
	for _, item := range liveBuiltInLists {
		lists = append(lists, liveListDef{ID: item.ID, Name: item.Name})
	}

	stale := false
	var warnings []string
	mainEntry, mainStale, mainErr := d.loadLiveList(ctx, def.ID, def.Candidates, input.Force)
	if mainErr != nil {
		warnings = append(warnings, "内置列表获取失败，请检查网络后重试")
	}
	stale = mainStale
	if mainStale {
		warnings = append(warnings, "内置列表使用了过期缓存")
	}

	// 自填源：优先用带请求头/内联正文的新通道，缺省回退旧的 liveUrls。
	// 每条订阅独立缓存与容错，失败不阻断整体。
	var sources []liveSourceInput
	if len(input.LiveSources) > 0 {
		sources = input.LiveSources
	} else {
		for _, raw := range input.LiveURLs {
			sources = append(sources, liveSourceInput{URL: strings.TrimSpace(raw)})
		}
	}
	customLists := make([][]liveChannel, 0, len(sources))
	type liveCustomOutcome struct {
		url      string
		channels []liveChannel
		warning  string
		stale    bool
		ok       bool
	}
	outcomes := make([]liveCustomOutcome, len(sources))
	batchCtx, batchCancel := context.WithTimeout(ctx, liveCustomTotalBudget)
	defer batchCancel()
	var batch sync.WaitGroup
	slots := make(chan struct{}, liveCustomFetchParallel)
	for index, spec := range sources {
		url := strings.TrimSpace(spec.URL)
		// TVBox 配置内嵌的 channels：正文已在配置里，纯本地解析，不必并发。
		if spec.Payload != "" {
			channels := filterLiveChannels(
				mergeLiveChannels(parseLivePlaylist(spec.Payload)),
			)
			if len(channels) == 0 {
				outcomes[index] = liveCustomOutcome{url: url, warning: "自填直播源没有可用频道：" + url}
				continue
			}
			outcomes[index] = liveCustomOutcome{url: url, channels: channels, ok: true}
			continue
		}
		if !liveValidURL(url) {
			outcomes[index] = liveCustomOutcome{url: url, warning: "自填直播源地址无效：" + url}
			continue
		}
		headers := sanitizeLiveHeaders(spec.Headers)
		key := "custom|" + url + liveHeaderCacheSuffix(headers)
		force := input.Force
		batch.Add(1)
		go func(index int, url, key string, headers map[string]string) {
			defer batch.Done()
			slots <- struct{}{}
			defer func() { <-slots }()
			entry, entryStale, err := d.loadLiveListWithHeaders(
				batchCtx, key, []string{url}, force, headers,
			)
			if err != nil {
				outcomes[index] = liveCustomOutcome{url: url, warning: "自填直播源获取失败：" + url}
				return
			}
			outcomes[index] = liveCustomOutcome{url: url, channels: entry.Channels, ok: true, stale: entryStale}
		}(index, url, key, headers)
	}
	batch.Wait()
	for _, outcome := range outcomes {
		if outcome.warning != "" {
			warnings = append(warnings, outcome.warning)
		}
		if outcome.stale {
			stale = true
			warnings = append(warnings, "自填直播源使用了过期缓存："+outcome.url)
		}
		if outcome.ok {
			customLists = append(customLists, outcome.channels)
		}
	}

	listArgs := make([][]liveChannel, 0, 1+len(customLists))
	if mainErr == nil {
		listArgs = append(listArgs, mainEntry.Channels)
	}
	listArgs = append(listArgs, customLists...)
	groups, count := liveGroupsFromLists(listArgs...)
	if count == 0 && len(warnings) > 0 && mainErr != nil {
		return nil, mainErr
	}

	var fetchedAt time.Time
	if mainErr == nil {
		fetchedAt = mainEntry.FetchedAt
	} else {
		d.live.mu.Lock()
		if entry, ok := d.live.entries[def.ID]; ok {
			fetchedAt = entry.FetchedAt
		}
		d.live.mu.Unlock()
	}

	response := map[string]any{
		"listId":       def.ID,
		"lists":        lists,
		"groups":       groups,
		"channelCount": count,
		"fetchedAt":    "",
		"stale":        stale,
		"warning":      strings.Join(warnings, "；"),
	}
	if !fetchedAt.IsZero() {
		response["fetchedAt"] = fetchedAt.UTC().Format(time.RFC3339)
	}
	return response, nil
}
