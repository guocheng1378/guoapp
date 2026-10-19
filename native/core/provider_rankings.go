package core

// 榜单数据源双轨（2026-10-19 恢复站源榜）：
//   - 豆瓣官方主题合集（rexxar v2，抓取在 provider_rankings_douban.go），
//     榜单 ID 前缀 douban-* 同时是 Dart 端 ranking_models.sourceForID 的解析依据；
//   - 站源目录榜（红果/黄豆/黄果AI/剧果/野果/真果·鉴/影视工厂），由
//     fetchRankingPage 按源分发（红果 HTML 流式解析，其余复用目录页抓取）。
// Dart 端按站源四分类（短剧/视频/黄果/成人）归属展示，改动 ID/归属需两端同步。

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"
)

const rankingCacheTTL = 5 * time.Minute

type rankingBoard struct {
	ID          string `json:"id"`
	Source      string `json:"source"`
	Name        string `json:"name"`
	Description string `json:"description"`
	// path：站源目录榜的分类路径（豆瓣榜不使用）。
	path string
	// upstreamKey：豆瓣 subject_collection 合集 ID（movie_top250 等），
	// 或红果/黄豆榜的站点 tab 键。
	upstreamKey string
	// ttl：0 用默认 rankingCacheTTL。日更/周更榜可拉长。
	ttl time.Duration
}

// 豆瓣官方榜单（2026-10-19 逐个实测可用，名称取自接口返回）：
//
//	电影：实时热门电影 / 一周口碑电影榜 / 豆瓣Top250 / 影院热映 / 近期热门电影
//	剧集：近期热门剧集 / 近期热门国产剧 / 近期热门美剧 / 近期热门日剧 / 近期热门韩剧
//	综艺：近期热门国内综艺 / 近期热门国外综艺
var rankingBoards = []rankingBoard{
	// —— 豆瓣官方合集 ——
	{ID: "douban-realtime", Name: "实时热门电影", Source: sourceDouban, upstreamKey: "movie_real_time_hotest"},
	{ID: "douban-weekly", Name: "一周口碑电影榜", Source: sourceDouban, upstreamKey: "movie_weekly_best", ttl: time.Hour},
	{ID: "douban-top250", Name: "豆瓣Top250", Source: sourceDouban, upstreamKey: "movie_top250", ttl: 12 * time.Hour},
	{ID: "douban-showing", Name: "影院热映", Source: sourceDouban, upstreamKey: "movie_showing", ttl: time.Hour},
	{ID: "douban-latest", Name: "近期热门电影", Source: sourceDouban, upstreamKey: "movie_latest", ttl: time.Hour},
	{ID: "douban-tv-hot", Name: "近期热门剧集", Source: sourceDouban, upstreamKey: "tv_hot"},
	{ID: "douban-tv-domestic", Name: "近期热门国产剧", Source: sourceDouban, upstreamKey: "tv_domestic", ttl: time.Hour},
	{ID: "douban-tv-american", Name: "近期热门美剧", Source: sourceDouban, upstreamKey: "tv_american", ttl: 6 * time.Hour},
	{ID: "douban-tv-japanese", Name: "近期热门日剧", Source: sourceDouban, upstreamKey: "tv_japanese", ttl: 6 * time.Hour},
	{ID: "douban-tv-korean", Name: "近期热门韩剧", Source: sourceDouban, upstreamKey: "tv_korean", ttl: 6 * time.Hour},
	{ID: "douban-show-domestic", Name: "近期热门国内综艺", Source: sourceDouban, upstreamKey: "show_domestic", ttl: time.Hour},
	{ID: "douban-show-foreign", Name: "近期热门国外综艺", Source: sourceDouban, upstreamKey: "show_foreign", ttl: 6 * time.Hour},
	// —— 站源目录榜 ——
	{ID: "hongguo-hot", Source: sourceHongguo, Name: "总热播榜", Description: "红果观看、互动等综合热度；每日更新。", path: "hot-drama", upstreamKey: "hongguo"},
	{ID: "hongguo-real", Source: sourceHongguo, Name: "真人剧榜", Description: "红果真人剧热播榜；每日更新。", path: "hot-real-drama", upstreamKey: "real"},
	{ID: "hongguo-comic", Source: sourceHongguo, Name: "漫剧榜", Description: "红果漫剧热播榜；每日更新。", path: "hot-comic-drama", upstreamKey: "comic"},
	{ID: "hongguo-ai", Source: sourceHongguo, Name: "AI剧榜", Description: "红果 AI 剧热播榜；每日更新。", path: "hot-ai-drama", upstreamKey: "ai"},
	{ID: "huangdou-all", Source: sourceHuangdou, Name: "总榜", Description: "黄豆短剧总榜，保留站点返回的顺序。", upstreamKey: "all"},
	{ID: "huangdou-mogai", Source: sourceHuangdou, Name: "魔改榜", Description: "黄豆站点魔改榜。", upstreamKey: "mogai"},
	{ID: "huangdou-search", Source: sourceHuangdou, Name: "搜索榜", Description: "黄豆站点搜索榜。", upstreamKey: "search"},
	{ID: "huangdou-favorite", Source: sourceHuangdou, Name: "收藏榜", Description: "黄豆站点收藏榜。", upstreamKey: "favorite"},
	{ID: "huangdou-finish", Source: sourceHuangdou, Name: "完结榜", Description: "黄豆站点完结榜。", upstreamKey: "finish"},
	{ID: "huangguo-hot", Source: sourceHuangguoAI, Name: "热播榜", Description: "黄果站点热播 TOP 20；每日更新。", path: "ranks/hot"},
	{ID: "huangguo-recommend", Source: sourceHuangguoAI, Name: "推荐榜", Description: "黄果 AI 成人短剧最新上新。", path: "ai-duanju"},
	{ID: "huangguo-potential", Source: sourceHuangguoAI, Name: "潜力榜", Description: "黄果 AI 成人漫剧最新上新。", path: "ai-manju"},
	{ID: "huangju-hot", Source: sourceHuangju, Name: "热门榜", Description: "剧果目录热门顺序，按源站返回顺序展示。"},
	{ID: "huangju-new", Source: sourceHuangju, Name: "最新榜", Description: "剧果最新目录顺序，按源站返回顺序展示。", path: huangjuNewestCategory},
	{ID: "yeguo-recommend", Source: sourceYeguo, Name: "目录榜", Description: "野果默认目录顺序，按源站返回顺序展示。"},
	{ID: "dongpiandi-hot", Source: sourceDongpiandi, Name: "热度榜", Description: "真果·鉴全类型热门短剧与影视，热度来自站点真实热度值。"},
	{ID: "dongpiandi-short-drama", Source: sourceDongpiandi, Name: "短剧榜", Description: "真果·鉴短剧热门，按源站返回顺序展示。", path: "short_drama"},
	{ID: "dongpiandi-series", Source: sourceDongpiandi, Name: "电视剧榜", Description: "真果·鉴电视剧热门，按源站返回顺序展示。", path: "series"},
	{ID: "dongpiandi-movie", Source: sourceDongpiandi, Name: "电影榜", Description: "真果·鉴电影热门，按源站返回顺序展示。", path: "movie"},
	{ID: "dongpiandi-anime", Source: sourceDongpiandi, Name: "动画榜", Description: "真果·鉴动画热门，按源站返回顺序展示。", path: "anime"},
	{ID: "dongpiandi-variety", Source: sourceDongpiandi, Name: "综艺榜", Description: "真果·鉴综艺热门，按源站返回顺序展示。", path: "variety"},
	{ID: "yingshigongchang-new", Source: sourceYingshigongchang, Name: "最近更新榜", Description: "影视工厂最新收录与更新，按源站返回顺序展示。"},
}

func findRankingBoard(id string) (rankingBoard, bool) {
	for _, board := range rankingBoards {
		if board.ID == id {
			return board, true
		}
	}
	return rankingBoard{}, false
}

// singlePageRankingBoard：黄果 AI 站点榜单为整页静态内容，无分页。
func singlePageRankingBoard(board rankingBoard) bool {
	return board.Source == sourceHuangguoAI
}

func rankingDramaWithoutImages(drama Drama) Drama {
	drama.Cover, drama.CoverURL, drama.CoverURLSnake = nil, nil, nil
	drama.Image, drama.ImageURL, drama.ImageURLSnake = nil, nil, nil
	drama.Img, drama.Pic, drama.Picture = nil, nil, nil
	drama.Poster, drama.Thumb, drama.Thumbnail = nil, nil, nil
	return drama
}

type rankingPage struct {
	BoardID     string        `json:"boardId"`
	Page        int           `json:"page"`
	Items       []rankingItem `json:"items"`
	HasMore     bool          `json:"hasMore"`
	TotalPages  int           `json:"totalPages"`
	UpdatedText string        `json:"updatedText,omitempty"`
	FetchedAt   time.Time     `json:"fetchedAt"`
	Stale       bool          `json:"stale,omitempty"`
	Warning     string        `json:"warning,omitempty"`
}

type rankingItem struct {
	Rank   int    `json:"rank"`
	Metric string `json:"metric,omitempty"`
	Drama  Drama  `json:"drama"`
}

func cloneRankingPage(value rankingPage) rankingPage {
	result := value
	result.Items = append([]rankingItem(nil), value.Items...)
	return result
}

type rankingCall struct {
	done chan struct{}
	page rankingPage
	err  error
}

// rankingCache：内存页缓存 + 在途请求去重 + 落盘状态。mu 保护全部字段。
type rankingCache struct {
	mu         sync.Mutex
	pages      map[string]rankingPage
	pending    map[string]*rankingCall
	lastWrite  time.Time
	dirty      bool
	writeTimer *time.Timer
}

// loadRankingPage：TTL 内走内存缓存，在途请求去重，网络失败回退过期缓存
// （重启后磁盘页已由 loadRankingCache 灌回内存，同一条兜底路径生效）。
func (d *Downloader) loadRankingPage(ctx context.Context, board rankingBoard, page int, force bool) (rankingPage, error) {
	ttl := rankingCacheTTL
	if board.ttl > 0 {
		ttl = board.ttl
	}
	key := board.ID + ":" + strconv.Itoa(page)

	d.rankings.mu.Lock()
	entry, cached := d.rankings.pages[key]
	if cached && !force && time.Since(entry.FetchedAt) < ttl {
		d.rankings.mu.Unlock()
		return cloneRankingPage(entry), nil
	}
	var stale rankingPage
	if cached {
		stale = cloneRankingPage(entry)
	}
	if call := d.rankings.pending[key]; call != nil && !force {
		d.rankings.mu.Unlock()
		select {
		case <-ctx.Done():
			return rankingPage{}, ctx.Err()
		case <-call.done:
			// 领头请求因本调用方取消而失败时，自己重试一次。
			if (errors.Is(call.err, context.Canceled) || errors.Is(call.err, context.DeadlineExceeded)) && ctx.Err() == nil {
				return d.loadRankingPage(ctx, board, page, false)
			}
			if call.err != nil {
				return rankingPage{}, call.err
			}
			return cloneRankingPage(call.page), nil
		}
	}
	call := &rankingCall{done: make(chan struct{})}
	d.rankings.pending[key] = call
	d.rankings.mu.Unlock()

	result, err := d.fetchRankingPage(ctx, board, page)
	d.rankings.mu.Lock()
	if err == nil {
		result.BoardID = board.ID
		result.Page = page
		result.FetchedAt = time.Now()
		// 强刷第 1 页时清掉同榜其余缓存页，后续翻页重新拉取。
		if force && page == 1 {
			for cachedKey, old := range d.rankings.pages {
				if old.BoardID == board.ID {
					delete(d.rankings.pages, cachedKey)
				}
			}
		}
		// 缓存页上限 128，超出时淘汰最旧一页，防长驻膨胀。
		if len(d.rankings.pages) >= 128 {
			oldestKey, oldest := "", time.Now()
			for cachedKey, old := range d.rankings.pages {
				if old.FetchedAt.Before(oldest) {
					oldestKey, oldest = cachedKey, old.FetchedAt
				}
			}
			delete(d.rankings.pages, oldestKey)
		}
		d.rankings.pages[key] = result
		d.writeRankingCacheLocked()
	}
	call.page, call.err = result, err
	delete(d.rankings.pending, key)
	close(call.done)
	d.rankings.mu.Unlock()

	if err != nil {
		if len(stale.Items) > 0 {
			stale.BoardID, stale.Page = board.ID, page
			stale.Stale = true
			stale.Warning = "站点暂不可用，正在显示上次取得的榜单，请稍后刷新。"
			return stale, nil
		}
		return rankingPage{}, err
	}
	return cloneRankingPage(result), nil
}

// fetchRankingPage：按榜单站源分发。豆瓣走官方合集抓取，站源榜各有链路。
func (d *Downloader) fetchRankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	switch board.Source {
	case sourceDouban:
		return d.fetchDoubanRankingPage(ctx, board, page)
	case sourceHongguo:
		return d.fetchHongguoRankingPage(ctx, board, page)
	case sourceHuangdou:
		var decoded any
		err := newHuangdouAPIClient(d).call(ctx, "/drama/rank", map[string]any{"tab": board.upstreamKey, "page": strconv.Itoa(page)}, &decoded)
		if err != nil {
			return rankingPage{}, err
		}
		return parseHuangdouRanking(decoded, page)
	case sourceHuangguoAI:
		if page != 1 {
			return rankingPage{}, errors.New("该榜单只有一页")
		}
		pageURL := d.providerBaseURL(sourceHuangguoAI) + "/" + strings.Trim(board.path, "/") + "/"
		body, err := d.fetchProviderText(ctx, pageURL, d.providerBaseURL(sourceHuangguoAI)+"/")
		if err != nil {
			return rankingPage{}, err
		}
		return parseHuangguoRanking(body, board)
	case sourceHuangju, sourceYeguo, sourceYingshigongchang, sourceDongpiandi:
		return d.fetchCatalogRankingPage(ctx, board, page)
	default:
		return rankingPage{}, fmt.Errorf("不支持的榜单站源 %s", board.Source)
	}
}

// fetchCatalogRankingPage：目录型站源榜直接复用目录抓取，按源站返回顺序出榜。
func (d *Downloader) fetchCatalogRankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	if singlePageRankingBoard(board) && page != 1 {
		return rankingPage{}, errors.New("该榜单只有一页")
	}
	category := board.path
	if board.Source == sourceYeguo && category == "recommend" {
		category = ""
		categories, err := d.fetchYeguoCategories(ctx)
		if err == nil {
			for _, item := range categories {
				if strings.HasPrefix(item.ID, "recommend:") {
					category = item.ID
					break
				}
			}
		}
	}
	var items []Drama
	var more bool
	var err error
	switch board.Source {
	case sourceHuangju:
		items, more, err = d.fetchHuangjuCatalogPage(ctx, page, category, "")
	case sourceYeguo:
		items, more, err = d.fetchYeguoCatalogPage(ctx, page, category, "")
	case sourceYingshigongchang:
		items, more, err = d.fetchDuanjuCatalogPage(ctx, sourceYingshigongchang, page, "", "")
	case sourceDongpiandi:
		items, more, err = d.fetchDongpiandiCatalogPage(ctx, page, category, "")
	}
	if err != nil {
		return rankingPage{}, err
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(items)), HasMore: more}
	for index, drama := range items {
		drama = rankingDramaWithoutImages(drama)
		metric := ""
		if board.Source == sourceDongpiandi && drama.Heat != "" {
			metric = drama.Heat
		}
		result.Items = append(result.Items, rankingItem{Rank: (page-1)*20 + index + 1, Drama: drama, Metric: metric})
	}
	return result, nil
}
