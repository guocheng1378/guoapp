package core

// 电视直播（2026-10-22）：独立于站源体系的 m3u/m3u8 直播列表功能。
// 数据面：内置双列表（候选 URL 逐个回退容灾）+ 用户自填源（Dart 经 liveUrls 传入），
// 解析 #EXTINF tvg-logo group-title 与「名称,URL」txt 两种格式，按分组返回频道。
// 缓存照 rankings 模式（内存 + 磁盘 + TTL + 在途去重）；播放走既有 mpv 管线，
// 频道携带多线路（同名频道多 URL），播放端按序重试。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
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
)

const liveUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/150.0.0.0 Safari/537.36"

// liveAdWords 广告/购物类频道名关键词：命中（频道名或分组名）整频道剔除。
// 2026-10-22 探针实测 iptvorg「国际中文」列表混有四川星空购物/家有购物等 6 个购物频道。
var liveAdWords = []string{
	"广告", "购物", "推广", "促销", "推销", "招商", "网购", "电商", "团购", "代购", "导购", "商城", "带货", "秒杀",
}

// liveVODHostWords 点播平台 CDN 域名词：部分列表把快手等点播 CDN 的广告循环/原始
// MP4 伪造成卫视直播线路（guovin 列表湖南/广东卫视首线路均为 txmov2.a.kwimgs.com，
// 点开即广告）——直播型频道剔除这类线路；这些 URL 为静态路径无签名时效，剔除不会
// 误杀其他有效内容。
var liveVODHostWords = []string{
	"kwimgs.com", "kuaishou", "douyinvod.com", "douyinpic.com", "amemv.com",
	"bilivideo.com", "hdslb.com", "ixigua.com", "toutiaovod.com", "bytecdn.cn",
}

// liveReplayKeywords 回放型频道豁免：春晚/经典电影等频道的点播 CDN 线路是有意内容，
// 保留不剔。
var liveReplayKeywords = []string{"春晚", "回放", "电影", "点播", "戏曲", "纪录片", "剧场"}

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
var liveBuiltInLists = []liveListDef{
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
	Name  string   `json:"name"`
	Group string   `json:"group,omitempty"`
	Logo  string   `json:"logo,omitempty"`
	URLs  []string `json:"urls"`
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
	return filepath.Join(d.cfg.dataDir, "live_cache.json")
}

func (d *Downloader) loadLiveCache() {
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
	if err != nil || len(data) > liveMaxCacheBytes {
		return
	}
	if err := writeNativeCacheFile(d.liveFileName(), data); err == nil {
		d.live.dirty = false
		d.live.lastWrite = time.Now()
	}
	// 写失败保留 dirty，由下次标记或进程退出前的落盘重试。
}

func (d *Downloader) fetchLiveText(ctx context.Context, url string) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", liveUserAgent)
	req.Header.Set("Accept", "*/*")
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
	d.live.mu.Lock()
	entry, ok := d.live.entries[key]
	if !force && ok && time.Since(entry.FetchedAt) < liveCacheTTL {
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

	fetched, err := d.fetchLiveListCandidates(ctx, candidates)
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
	d.live.entries[key] = fetched
	d.live.dirty = true
	d.scheduleLiveWriteLocked()
	d.live.mu.Unlock()
	return fetched, false, nil
}

func (d *Downloader) fetchLiveListCandidates(ctx context.Context, candidates []string) (liveListEntry, error) {
	var lastErr error
	for _, url := range candidates {
		text, err := d.fetchLiveText(ctx, url)
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
func parseLiveExtinf(rest string) (name, logo, group string) {
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
			}
		}
	}
	if title != "" {
		name = title
	}
	return name, logo, group
}

// parseLivePlaylist 支持 m3u（#EXTM3U）与「名称,URL」「分组,#genre#」txt 两种主流格式。
func parseLivePlaylist(body string) []liveChannel {
	body = strings.TrimSpace(strings.TrimPrefix(body, "\ufeff"))
	if body == "" {
		return nil
	}
	if strings.Contains(body, "#EXTM3U") {
		return parseLiveM3U(body)
	}
	return parseLiveTXT(body)
}

func parseLiveM3U(body string) []liveChannel {
	var channels []liveChannel
	name, logo, group, pending := "", "", "", false
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		if line == "" {
			continue
		}
		if strings.HasPrefix(line, "#") {
			if strings.HasPrefix(line, "#EXTINF:") {
				name, logo, group = parseLiveExtinf(strings.TrimPrefix(line, "#EXTINF:"))
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
		channels = append(channels, liveChannel{Name: name, Group: group, Logo: logo, URLs: []string{strings.TrimSpace(line)}})
		name, logo, group, pending = "", "", "", false
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
		merged = append(merged, liveChannel{Name: ch.Name, Group: ch.Group, Logo: ch.Logo, URLs: urls})
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
		slot.Channels = append(slot.Channels, liveChannel{Name: ch.Name, Group: ch.Group, Logo: ch.Logo, URLs: urls})
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

	// 自填源：每条 URL 独立缓存与容错，失败不阻断整体。
	customLists := make([][]liveChannel, 0, len(input.LiveURLs))
	for _, raw := range input.LiveURLs {
		url := strings.TrimSpace(raw)
		if !liveValidURL(url) {
			warnings = append(warnings, "自填直播源地址无效："+raw)
			continue
		}
		key := "custom|" + url
		entry, entryStale, err := d.loadLiveList(ctx, key, []string{url}, input.Force)
		if err != nil {
			warnings = append(warnings, "自填直播源获取失败："+url)
			continue
		}
		if entryStale {
			stale = true
			warnings = append(warnings, "自填直播源使用了过期缓存："+url)
		}
		customLists = append(customLists, entry.Channels)
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
