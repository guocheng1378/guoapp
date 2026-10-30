package core

// 真果·鉴时评弹幕：站内评论端点 GET /v1/comments?variant_id={variantID}
// 自带播放时间轴（metadata.playback_context.episode_id + position_seconds，
// 语义等价红果弹幕的 offset_time）。评论按 quality 排序、limit=30、
// next_cursor（base64 JSON）翻页；status=folded 的是被折叠的低质评论，不取。
//
// 返回契约与红果对齐（Dart 侧 DanmakuController 零改动）：
//   - startMs = 请求的 30 秒窗口起点
//   - nextMs  = 窗口内最晚弹幕之后 30s（至少 start+30s，不超过视频总长）
//   - items   = timeMs 落在 [startMs, nextMs) 内的本集评论
// 全量评论按 (variant, episode) 缓存 10 分钟并做单 flight 合并，
// 同一集反复 seek 不重复打站内接口。

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

type dongpiandiPlaybackContext struct {
	EpisodeID    string `json:"episode_id"`
	EpisodeLabel string `json:"episode_label"`
	LineLabel    string `json:"line_label"`
	PositionSec  any    `json:"position_seconds"`
}

type dongpiandiCommentRow struct {
	ID       string `json:"id"`
	Content  string `json:"content"`
	Status   string `json:"status"`
	Metadata struct {
		PlaybackContext *dongpiandiPlaybackContext `json:"playback_context"`
	} `json:"metadata"`
}

type dongpiandiCommentResp struct {
	Object        string                 `json:"object"`
	ReturnedCount int                    `json:"returned_count"`
	HasMore       bool                   `json:"has_more"`
	NextCursor    any                    `json:"next_cursor"`
	Results       []dongpiandiCommentRow `json:"results"`
}

type dongpiandiDanmakuCache struct {
	mu      sync.Mutex
	entries map[string]dongpiandiDanmakuEntry
	pending map[string]*dongpiandiDanmakuCall
}

type dongpiandiDanmakuEntry struct {
	items   []hongguoDanmakuItem
	err     error
	expires time.Time
}

type dongpiandiDanmakuCall struct {
	done  chan struct{}
	entry dongpiandiDanmakuEntry
}

func (d *Downloader) dongpiandiDanmakuClient() *dongpiandiDanmakuCache {
	d.dongpiandiDanmakuOnce.Do(func() {
		d.dongpiandiDanmakuStore = &dongpiandiDanmakuCache{
			entries: map[string]dongpiandiDanmakuEntry{},
			pending: map[string]*dongpiandiDanmakuCall{},
		}
	})
	return d.dongpiandiDanmakuStore
}

// dongpiandiDanmaku 返回真果·鉴某一集在 [start, nextMs) 窗口内的时评弹幕。
func (d *Downloader) dongpiandiDanmaku(ctx context.Context, variantID, episodeID string, start, duration int64) (hongguoDanmakuPage, error) {
	if err := ctx.Err(); err != nil {
		return hongguoDanmakuPage{}, err
	}
	if variantID == "" || episodeID == "" || len(variantID) > 256 || len(episodeID) > 256 {
		return hongguoDanmakuPage{}, errors.New("弹幕请求参数无效")
	}
	if start < 0 || duration <= start || duration > danmakuMaxDurationMS {
		return hongguoDanmakuPage{}, errors.New("弹幕时间范围无效")
	}
	items, err := d.dongpiandiDanmakuItems(ctx, variantID, episodeID)
	if err != nil {
		return hongguoDanmakuPage{}, err
	}
	// 覆盖页：至少一个 30s 窗口；有更晚的弹幕就延伸到最晚弹幕之后 30s，
	// 让 Dart 侧 _covering 一页覆盖全片，不必逐窗口空打。
	next := start + danmakuWindowMS
	for _, item := range items {
		if edge := item.TimeMS + danmakuWindowMS; edge > next {
			next = edge
		}
	}
	if next > duration {
		next = duration
	}
	if next <= start {
		next = start + 1
	}
	page := hongguoDanmakuPage{
		EpisodeID: episodeID, Items: []hongguoDanmakuItem{}, StartMS: start, NextMS: next, Total: int64(len(items)),
	}
	for _, item := range items {
		if item.TimeMS < start || item.TimeMS >= next {
			continue
		}
		page.Items = append(page.Items, item)
		if len(page.Items) == 90 {
			break
		}
	}
	sort.SliceStable(page.Items, func(i, j int) bool { return page.Items[i].TimeMS < page.Items[j].TimeMS })
	return page, nil
}

// dongpiandiDanmakuItems 拉取并缓存某一集的全部时评（含单 flight 合并）。
func (d *Downloader) dongpiandiDanmakuItems(ctx context.Context, variantID, episodeID string) ([]hongguoDanmakuItem, error) {
	cache := d.dongpiandiDanmakuClient()
	key := variantID + "\x00" + episodeID
	cache.mu.Lock()
	if entry, found := cache.entries[key]; found && time.Now().Before(entry.expires) {
		cache.mu.Unlock()
		return entry.items, entry.err
	}
	if pending := cache.pending[key]; pending != nil {
		cache.mu.Unlock()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-pending.done:
			if ctx.Err() == nil && (errors.Is(pending.entry.err, context.Canceled) || errors.Is(pending.entry.err, context.DeadlineExceeded)) {
				return d.dongpiandiDanmakuItems(ctx, variantID, episodeID)
			}
			return pending.entry.items, pending.entry.err
		}
	}
	if cache.pending == nil {
		cache.pending = map[string]*dongpiandiDanmakuCall{}
	}
	if len(cache.pending) >= 16 {
		cache.mu.Unlock()
		return nil, errors.New("弹幕请求繁忙")
	}
	pending := &dongpiandiDanmakuCall{done: make(chan struct{})}
	cache.pending[key] = pending
	cache.mu.Unlock()

	items, err := d.fetchDongpiandiComments(ctx, newDongpiandiClient(), variantID, episodeID)
	entry := dongpiandiDanmakuEntry{items: items, err: err, expires: time.Now().Add(10 * time.Minute)}
	if err != nil {
		entry.expires = time.Now().Add(15 * time.Second)
	}
	cache.mu.Lock()
	if !errors.Is(err, context.Canceled) && !errors.Is(err, context.DeadlineExceeded) {
		if cache.entries == nil || len(cache.entries) >= 64 {
			cache.entries = map[string]dongpiandiDanmakuEntry{}
		}
		cache.entries[key] = entry
	}
	pending.entry = entry
	delete(cache.pending, key)
	close(pending.done)
	cache.mu.Unlock()
	return items, err
}

// fetchDongpiandiComments 翻页拉全量评论，过滤出当前集的 visible 时评。
func (d *Downloader) fetchDongpiandiComments(ctx context.Context, client *dongpiandiClient, variantID, episodeID string) ([]hongguoDanmakuItem, error) {
	var items []hongguoDanmakuItem
	seen := map[string]bool{}
	cursor := ""
	for page := 0; page < 4; page++ {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		params := url.Values{}
		params.Set("variant_id", variantID)
		params.Set("limit", "30")
		if cursor != "" {
			params.Set("cursor", cursor)
		}
		body, err := client.get(ctx, "/v1/comments", params)
		if err != nil {
			return nil, err
		}
		var resp dongpiandiCommentResp
		if err := json.Unmarshal(body, &resp); err != nil {
			return nil, errors.New("解析评论失败")
		}
		for _, row := range resp.Results {
			if row.Status != "visible" || row.ID == "" || seen[row.ID] {
				continue
			}
			playback := row.Metadata.PlaybackContext
			if playback == nil || playback.EpisodeID != episodeID {
				continue
			}
			positionMS, ok := dongpiandiPositionMS(playback.PositionSec)
			if !ok {
				continue
			}
			text := dongpiandiDanmakuText(row.Content)
			if text == "" {
				continue
			}
			seen[row.ID] = true
			items = append(items, hongguoDanmakuItem{ID: row.ID, Text: text, TimeMS: positionMS})
		}
		next, _ := resp.NextCursor.(string)
		if !resp.HasMore || next == "" || next == cursor {
			break
		}
		cursor = next
	}
	sort.SliceStable(items, func(i, j int) bool { return items[i].TimeMS < items[j].TimeMS })
	return items, nil
}

// dongpiandiPositionMS 把 playback_context.position_seconds 归一为毫秒。
// 站点返回 JSON 数字（float64）或少数情况下的字符串；非法/越界（>7 天）丢弃。
func dongpiandiPositionMS(raw any) (int64, bool) {
	var seconds float64
	switch v := raw.(type) {
	case float64:
		seconds = v
	case int:
		seconds = float64(v)
	case int64:
		seconds = float64(v)
	case json.Number:
		parsed, err := v.Float64()
		if err != nil {
			return 0, false
		}
		seconds = parsed
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(v), 64)
		if err != nil {
			return 0, false
		}
		seconds = parsed
	default:
		return 0, false
	}
	if seconds < 0 || seconds > 7*24*3600 {
		return 0, false
	}
	return int64(seconds * 1000), true
}

// dongpiandiDanmakuText 清洗评论文本：去控制符、压缩空白、限长 180 字。
func dongpiandiDanmakuText(text string) string {
	text = strings.TrimSpace(strings.Map(func(r rune) rune {
		if unicode.IsControl(r) || r == '\u2028' || r == '\u2029' {
			return ' '
		}
		return r
	}, text))
	text = strings.Join(strings.Fields(text), " ")
	if runes := []rune(text); len(runes) > 180 {
		text = string(runes[:180]) + "…"
	}
	return text
}
