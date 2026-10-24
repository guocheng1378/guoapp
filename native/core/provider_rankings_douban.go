package core

// 豆瓣榜单：rexxar v2 主题合集接口（movie_top250 / movie_real_time_hotest /
// movie_weekly_best）。接口要点（2026-10-19 实测）：
//   - 基址 https://m.douban.com/rexxar/api/v2/subject_collection/{id}/items
//   - 必须带浏览器 UA + Referer: https://m.douban.com/，否则 403
//   - 响应为明文 JSON：{start, count, total, subject_collection_items[]}
//   - 豆瓣条目仅展示（评分/年份/类型/封面），不提供播放链路，点击由 UI 拦截。
//   - 解析按条目降级：脏行跳过不拖垮整页；瞬时 403/429/5xx 退避重试一次。

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

const sourceDouban = "douban"

const (
	doubanReferer   = "https://m.douban.com/"
	doubanUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
	doubanPageSize  = 20
)

// 基址用 var 仅为测试注入本地服务器；瞬时失败（403/429/5xx/网络错）退避重试一次。
var (
	doubanRexxarBaseURL = "https://m.douban.com/rexxar/api/v2"
	doubanRetryDelay    = 300 * time.Millisecond
)

var errDoubanRankingFormat = errors.New("豆瓣榜单格式已变化，请稍后重试")

// 包内共享 client：豆瓣无需特殊 TLS/代理配置，仅统一超时与连接复用。
var doubanHTTPClient = &http.Client{
	Timeout: 15 * time.Second,
}

type doubanCollectionItem struct {
	ID           string `json:"id"`
	Title        string `json:"title"`
	RankValue    int    `json:"rank_value"`
	CoverURL     string `json:"cover_url"`
	CardSubtitle string `json:"card_subtitle"`
	Description  string `json:"description"`
	// pic 是 TV 剧集合集（如 tv_domestic）的封面字段（large/normal 两档），
	// 电影合集则直接给 cover_url 字符串；两种格式都收。
	Pic *struct {
		Large  string `json:"large"`
		Normal string `json:"normal"`
	} `json:"pic"`
	// cover 是部分电影合集（如 movie_showing / movie_latest）的封面字段
	//（单 url + 尺寸元数据）；rexxar 各合集响应形态不一，三种都要收。
	Cover *struct {
		URL string `json:"url"`
	} `json:"cover"`
	Rating *struct {
		Value float64 `json:"value"`
		Count int     `json:"count"`
	} `json:"rating"`
	Tags []struct {
		Name string `json:"name"`
		Type string `json:"type"`
	} `json:"tags"`
}

type doubanCollectionResponse struct {
	Start int                    `json:"start"`
	Total int                    `json:"total"`
	Items []doubanCollectionItem `json:"subject_collection_items"`
}

func (d *Downloader) fetchDoubanRankingPage(ctx context.Context, board rankingBoard, page int) (rankingPage, error) {
	result, retryable, err := d.fetchDoubanRankingPageOnce(ctx, board, page)
	if err == nil || !retryable {
		return result, err
	}
	// 只退避重试一次；解析类错误与 4xx（除 403/429）不重试，ctx 取消优先。
	select {
	case <-ctx.Done():
		return rankingPage{}, ctx.Err()
	case <-time.After(doubanRetryDelay):
	}
	result, _, err = d.fetchDoubanRankingPageOnce(ctx, board, page)
	return result, err
}

func (d *Downloader) fetchDoubanRankingPageOnce(ctx context.Context, board rankingBoard, page int) (result rankingPage, retryable bool, err error) {
	if page < 1 {
		return rankingPage{}, false, errDoubanRankingFormat
	}
	collection := board.upstreamKey
	if collection == "" {
		return rankingPage{}, false, fmt.Errorf("未知的豆瓣榜单 %s", board.ID)
	}
	address := fmt.Sprintf(
		"%s/subject_collection/%s/items?start=%d&count=%d",
		doubanRexxarBaseURL, collection, (page-1)*doubanPageSize, doubanPageSize,
	)
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return rankingPage{}, false, err
	}
	request.Header.Set("User-Agent", doubanUserAgent)
	request.Header.Set("Referer", doubanReferer)
	request.Header.Set("Accept", "application/json")
	response, err := doubanHTTPClient.Do(request)
	if err != nil {
		return rankingPage{}, true, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return rankingPage{}, doubanStatusRetryable(response.StatusCode), fmt.Errorf("豆瓣榜单返回 %d", response.StatusCode)
	}
	body, err := io.ReadAll(io.LimitReader(response.Body, duanjuMaxBodyBytes+1))
	if err != nil {
		return rankingPage{}, true, err
	}
	if len(body) > duanjuMaxBodyBytes {
		return rankingPage{}, false, errors.New("豆瓣榜单响应过大")
	}
	result, err = parseDoubanRanking(body, board, page)
	return result, false, err
}

// doubanStatusRetryable：反爬 403、限流 429、服务端 5xx 值得退避重试一次。
func doubanStatusRetryable(code int) bool {
	return code == http.StatusForbidden || code == http.StatusTooManyRequests || code >= 500
}

func parseDoubanRanking(body []byte, board rankingBoard, page int) (rankingPage, error) {
	var decoded doubanCollectionResponse
	if json.Unmarshal(body, &decoded) != nil {
		return rankingPage{}, errDoubanRankingFormat
	}
	if decoded.Start != (page-1)*doubanPageSize || decoded.Total < 0 {
		return rankingPage{}, errDoubanRankingFormat
	}
	result := rankingPage{
		Items:   make([]rankingItem, 0, len(decoded.Items)),
		HasMore: decoded.Start+len(decoded.Items) < decoded.Total,
	}
	seen := map[string]bool{}
	previous := 0
	for index, row := range decoded.Items {
		// 条目级降级：实时榜条目频繁上下榜，脏行（空标题/空 id/重复 id/序号
		// 跳变）直接跳过，不拖垮整页——整页失败时用户只能看到错误页。
		title := strings.TrimSpace(row.Title)
		if title == "" || row.ID == "" || seen[row.ID] {
			continue
		}
		seen[row.ID] = true
		rank := row.RankValue
		if rank <= 0 {
			rank = (page-1)*doubanPageSize + index + 1
		}
		if rank <= previous {
			continue
		}
		previous = rank
		drama := Drama{
			ID:          providerDramaID(sourceDouban, row.ID),
			Source:      sourceDouban,
			SourceID:    row.ID,
			Title:       title,
			Name:        title,
			Desc:        row.Description,
			Intro:       row.Description,
			ChannelName: "豆瓣",
		}
		coverURL := row.CoverURL
		if coverURL == "" && row.Cover != nil {
			coverURL = row.Cover.URL
		}
		if coverURL == "" && row.Pic != nil {
			if row.Pic.Large != "" {
				coverURL = row.Pic.Large
			} else {
				coverURL = row.Pic.Normal
			}
		}
		if coverURL != "" {
			drama.Cover, drama.CoverURL = coverURL, coverURL
		}
		for _, tag := range row.Tags {
			drama.Tags = append(drama.Tags, tag.Name)
		}
		if len(drama.Tags) > 0 {
			drama.CategoryName = drama.Tags[0]
		}
		if row.Rating != nil && row.Rating.Value > 0 {
			score := strconv.FormatFloat(row.Rating.Value, 'f', 1, 64)
			drama.Score = score
			metric := score + "分"
			if row.Rating.Count > 0 {
				metric = fmt.Sprintf("%s分 · %s人评价", score, doubanCountLabel(row.Rating.Count))
			}
			if year := doubanCardSubtitleYear(row.CardSubtitle); year != "" {
				metric += " · " + year
			}
			result.Items = append(result.Items, rankingItem{Rank: rank, Drama: drama, Metric: metric})
			continue
		}
		if year := doubanCardSubtitleYear(row.CardSubtitle); year != "" {
			// 未开分条目显式标注，避免光秃秃一个年份被误读为指标。
			result.Items = append(result.Items, rankingItem{Rank: rank, Drama: drama, Metric: "暂无评分 · " + year})
			continue
		}
		result.Items = append(result.Items, rankingItem{Rank: rank, Drama: drama})
	}
	if len(result.Items) == 0 && result.HasMore {
		return rankingPage{}, errDoubanRankingFormat
	}
	return result, nil
}

// doubanCardSubtitleYear 从 card_subtitle（如 "2026 / 德国 法国 / 科幻 惊悚"）
// 首段取 4 位年份；格式不符返回空串。
func doubanCardSubtitleYear(subtitle string) string {
	fields := strings.SplitN(subtitle, "/", 2)
	if len(fields) == 0 {
		return ""
	}
	first := strings.TrimSpace(fields[0])
	if len(first) < 4 {
		return ""
	}
	year := first[:4]
	for i := 0; i < len(year); i++ {
		if year[i] < '0' || year[i] > '9' {
			return ""
		}
	}
	return year
}

// doubanCountLabel 把豆瓣评价人数压成"X.X万"样式，避免 metric 过长。
func doubanCountLabel(count int) string {
	switch {
	case count >= 100000000:
		return strconv.FormatFloat(float64(count)/100000000, 'f', 1, 64) + "亿"
	case count >= 10000:
		return strconv.FormatFloat(float64(count)/10000, 'f', 1, 64) + "万"
	default:
		return strconv.Itoa(count)
	}
}
