package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"time"
)

func (d *Downloader) loadRankingCache() {
	cache := &d.rankings
	cache.pages, cache.pending = map[string]rankingPage{}, map[string]*rankingCall{}
	file, err := os.Open(filepath.Join(d.cfg.dataDir, "rankings.json"))
	if err != nil {
		return
	}
	defer file.Close()
	body, err := io.ReadAll(io.LimitReader(file, (8<<20)+1))
	if err != nil || len(body) > 8<<20 {
		return
	}
	var pages map[string]rankingPage
	if json.Unmarshal(body, &pages) != nil {
		return
	}
	for key, page := range pages {
		board, valid := findRankingBoard(page.BoardID)
		age := time.Since(page.FetchedAt)
		if !valid || !nativeSourceAvailable(board.Source) || page.Page < 1 || page.Page > 500 ||
			key != page.BoardID+":"+strconv.Itoa(page.Page) || age < 0 || age >= 24*time.Hour || len(page.Items) > 100 {
			continue
		}
		valid = true
		for _, item := range page.Items {
			if sourceFromDramaID(item.Drama.ID) != board.Source || item.Rank < 1 {
				valid = false
				break
			}
		}
		if valid && len(cache.pages) < 128 {
			cache.pages[key] = page
		}
	}
}

// rankingWriteInterval 内的重复写盘合并为一次尾部落盘；写盘是全量 marshal
// （上限 8MB），连续翻页每页都写是 O(n²) IO。首次写仍立即落盘，保住
// 「拉到第一页即可重启恢复」的语义。
var rankingWriteInterval = 2 * time.Second

// writeRankingCacheLocked 请求落盘 rankings.json：距上次落盘超过间隔则立即
// 写，否则只标脏并调度一次延后合并写。须持 cache.mu。
func (d *Downloader) writeRankingCacheLocked() {
	if d.cfg.dataDir == "" {
		return
	}
	cache := &d.rankings
	if elapsed := time.Since(cache.lastWrite); !cache.lastWrite.IsZero() && elapsed < rankingWriteInterval {
		cache.dirty = true
		if cache.writeTimer == nil {
			cache.writeTimer = time.AfterFunc(rankingWriteInterval-elapsed, func() {
				cache.mu.Lock()
				defer cache.mu.Unlock()
				cache.writeTimer = nil
				if cache.dirty {
					d.flushRankingCacheLocked()
				}
			})
		}
		return
	}
	d.flushRankingCacheLocked()
}

// flushRankingCacheLocked 同步全量落盘。落盘失败（Windows 上目标文件恰被
// 读句柄占用时 os.Rename 会失败）时保留 dirty，由下一次写或尾写重试；
// 只有成功落盘才推进 lastWrite/清 dirty。须持 cache.mu。
func (d *Downloader) flushRankingCacheLocked() {
	cache := &d.rankings
	body, err := json.Marshal(cache.pages)
	if err != nil || len(body) > 8<<20 {
		return
	}
	if writeNativeCacheFile(filepath.Join(d.cfg.dataDir, "rankings.json"), body) != nil {
		return
	}
	cache.lastWrite, cache.dirty = time.Now(), false
}

func (engine *nativeEngine) nativeRanking(ctx context.Context, input nativeInput) (any, error) {
	board, found := findRankingBoard(input.Board)
	if !found || !nativeSourceAvailable(board.Source) {
		return nil, errNativeBuildSource
	}
	if input.Page < 1 || input.Page > 500 {
		return nil, errors.New("榜单页码无效")
	}
	page, err := engine.downloader.loadRankingPage(ctx, board, input.Page, input.Force)
	if err != nil {
		return nil, err
	}
	type item struct {
		Rank   int         `json:"rank"`
		Drama  nativeDrama `json:"drama"`
		Metric string      `json:"metric,omitempty"`
	}
	items := make([]item, 0, len(page.Items))
	engine.mu.Lock()
	defer engine.mu.Unlock()
	library := map[string]nativeDrama{}
	for _, drama := range engine.catalogs[board.Source] {
		library[drama.ID] = drama
	}
	for _, row := range page.Items {
		drama := nativeNormalize(row.Drama)
		if old, found := library[drama.ID]; found {
			drama = mergeNativeDrama(old, drama)
		}
		items = append(items, item{Rank: row.Rank, Drama: drama, Metric: row.Metric})
	}
	return map[string]any{"boardId": page.BoardID, "page": page.Page, "items": items,
		"hasMore": page.HasMore, "totalPages": page.TotalPages, "updatedText": page.UpdatedText,
		"fetchedAt": page.FetchedAt, "stale": page.Stale, "warning": page.Warning}, nil
}
