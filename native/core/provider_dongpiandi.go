package core

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

// dongpiandiBaseURL 是 AI 聚合站 dongpiandi.ai 的 REST API 根地址。
// 平台用静态 HMAC-SHA256 密钥签名 /v1/* 请求，返回聚合后的目录/详情/播放解析。
// 短剧（kind=short_drama）直接返回 m3u8 URL，无需二次票据解析。
const (
	dongpiandiBaseURL  = "https://dongpiandi.ai"
	dongpiandiSignKey  = "8b9a908a05eac640e1ee06f52acaa741bfe4ba9e004eeffdbeb635e532e06666"
	dongpiandiSiteHost = "dongpiandi.ai"
	dongpiandiClientUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
	dongpiandiTimeout  = 15 * time.Second
)

type dongpiandiClient struct {
	http *http.Client
}

func newDongpiandiClient() *dongpiandiClient {
	return &dongpiandiClient{
		http: &http.Client{Timeout: dongpiandiTimeout},
	}
}

// sign 按 payload=`${METHOD}\n${pathname}${search}\n${timestamp}\n${nonce}` 的顺序
// 生成 HMAC-SHA256 十六进制签名。
func dongpiandiSign(method, pathWithQuery, ts, nonce string) string {
	payload := method + "\n" + pathWithQuery + "\n" + ts + "\n" + nonce
	mac := hmac.New(sha256.New, []byte(dongpiandiSignKey))
	mac.Write([]byte(payload))
	return hex.EncodeToString(mac.Sum(nil))
}

func dongpiandiNonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func (c *dongpiandiClient) get(ctx context.Context, path string, q url.Values) ([]byte, error) {
	full := path
	if len(q) > 0 {
		full = path + "?" + q.Encode()
	}
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	nonce := dongpiandiNonce()
	sig := dongpiandiSign("GET", full, ts, nonce)

	reqURL := dongpiandiBaseURL + full
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, reqURL, nil)
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 构造请求失败: %w", err)
	}
	req.Header.Set("x-ai-movie-timestamp", ts)
	req.Header.Set("x-ai-movie-nonce", nonce)
	req.Header.Set("x-ai-movie-signature", sig)
	req.Header.Set("x-ai-movie-site-host", dongpiandiSiteHost)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("User-Agent", dongpiandiClientUA)
	req.Header.Set("Origin", dongpiandiBaseURL)
	req.Header.Set("Referer", dongpiandiBaseURL+"/")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 请求失败: %w", err)
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 读取响应失败: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("dongpiandi: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(body)))
	}
	return body, nil
}

// dongpiandiCatalogCard 对应 /v1/browse/catalog 的单条记录。
type dongpiandiCatalogCard struct {
	ID              string   `json:"id"`
	Title           string   `json:"title"`
	NormalizedTitle string   `json:"normalized_title"`
	ContentKind     string   `json:"content_kind"`
	Year            int      `json:"year"`
	Area            string   `json:"area"`
	Language        string   `json:"language"`
	Genres          []string `json:"genres"`
	Actors          []string `json:"actors"`
	Directors       []string `json:"directors"`
	PosterURL       string   `json:"poster_url"`
	Score           any      `json:"score"`
	Remark          string   `json:"remarks"`
	PlaybackEntry   any      `json:"playback_entry"`
	PlaybackCount   int      `json:"playback_count"`
	HeatValue       any      `json:"heat_value"`
}

type dongpiandiCatalogResp struct {
	Object     string               `json:"object"`
	Cards      []dongpiandiCatalogCard `json:"cards"`
	Pagination struct {
		Total   int `json:"total"`
		Page    int `json:"page"`
		Limit   int `json:"limit"`
		HasMore bool `json:"has_more"`
	} `json:"pagination"`
}

// fetchDongpiandiCatalogPage 拉取目录分页。kind 默认 short_drama；
// 上游返回固定 total=1000 占位，按 has_more 判断是否有下一页。
func (d *Downloader) fetchDongpiandiCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	client := newDongpiandiClient()
	q := url.Values{}
	q.Set("page", strconv.Itoa(page))
	q.Set("limit", "20")
	if category != "" {
		q.Set("kind", category)
	} else if query != "" {
		q.Set("q", query)
	} else {
		q.Set("kind", "short_drama")
	}

	body, err := client.get(ctx, "/v1/browse/catalog", q)
	if err != nil {
		return nil, false, err
	}
	var resp dongpiandiCatalogResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, false, fmt.Errorf("dongpiandi: 解析目录失败: %w", err)
	}
	items := make([]Drama, 0, len(resp.Cards))
	for _, card := range resp.Cards {
		drama := dongpiandiDramaFromCard(card)
		if drama.Title == "" {
			continue
		}
		items = append(items, drama)
	}
	return items, resp.Pagination.HasMore, nil
}

func dongpiandiDramaFromCard(card dongpiandiCatalogCard) Drama {
	tags := make([]string, 0, 12)
	seen := map[string]bool{}
	add := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] || len([]rune(s)) > 48 {
			return
		}
		seen[s] = true
		tags = append(tags, s)
	}
	for _, g := range card.Genres {
		add(g)
	}
	if card.Area != "" {
		add(card.Area)
	}
	if card.Year > 0 {
		add(strconv.Itoa(card.Year) + "年")
	}
	if card.Remark != "" {
		add(card.Remark)
	}
	score := dongpiandiScore(card.Score)
	if score != "" {
		add("评分 " + score)
	}

	epCount := 0
	if card.PlaybackCount > 0 {
		epCount = card.PlaybackCount
	}
	if len(tags) == 0 {
		add("短剧")
	}

	return Drama{
		ID:          providerDramaID(sourceDongpiandi, card.ID),
		Source:      sourceDongpiandi,
		SourceID:    card.ID,
		Title:       truncate(card.Title, 256),
		Name:        truncate(card.Title, 256),
		Cover:       card.PosterURL,
		CoverURL:    card.PosterURL,
		Image:       card.PosterURL,
		Pic:         card.PosterURL,
		Poster:      card.PosterURL,
		Tags:        tags,
		Score:       score,
		Remark:      card.Remark,
		EpisodeCount: epCount,
		TotalEpisode: epCount,
		ChannelName: "真果·鉴",
		Category:    dongpiandiKindLabel(card.ContentKind),
	}
}

func dongpiandiScore(v any) string {
	switch n := v.(type) {
	case float64:
		if n > 0 && n <= 10 {
			return strconv.FormatFloat(n, 'f', 1, 64)
		}
	case int:
		if n > 0 && n <= 100 {
			return strconv.Itoa(n)
		}
	case string:
		if n != "" {
			return n
		}
	}
	return ""
}

func dongpiandiKindLabel(kind string) string {
	switch kind {
	case "short_drama":
		return "短剧"
	case "series":
		return "电视剧"
	case "movie":
		return "电影"
	case "anime":
		return "动画"
	case "variety":
		return "综艺"
	default:
		return "影视"
	}
}

// dongpiandiDetail 对应 /v1/catalog/{id} 的完整响应。
type dongpiandiDetail struct {
	ID                    string                  `json:"id"`
	Title                 string                  `json:"title"`
	ContentKind           string                  `json:"content_kind"`
	Year                  int                     `json:"year"`
	Area                  string                  `json:"area"`
	Language              string                  `json:"language"`
	Genres                []string                `json:"genres"`
	Actors                []string                `json:"actors"`
	Directors             []string                `json:"directors"`
	PosterURL             string                  `json:"poster_url"`
	Description           string                  `json:"description"`
	Remark                string                  `json:"remarks"`
	EpisodeCount          int                     `json:"episode_count"`
	AvailableEpisodeCount int                     `json:"available_episode_count"`
	CurrentEpisodeCount   int                     `json:"current_episode_count"`
	TotalEpisodeCount     int                     `json:"total_episode_count"`
	IsCompleted           bool                    `json:"is_completed"`
	UpdateStatus          string                  `json:"update_status"`
	EpisodeProgressText   string                  `json:"episode_progress_text"`
	Episodes              []dongpiandiEpisode     `json:"episodes"`
	EpisodePagination     struct {
		Offset     int  `json:"offset"`
		Limit      int  `json:"limit"`
		HasMore    bool `json:"has_more"`
		TotalCount int  `json:"total_count"`
	} `json:"episode_pagination"`
}

type dongpiandiEpisode struct {
	ID              string `json:"id"`
	Key             string `json:"key"`
	Title           string `json:"title"`
	Number          any    `json:"number"`
	Token           string `json:"token"`
	PlaybackCount   int    `json:"playback_count"`
	PlaybackURL     string `json:"playback_url"`
	EpisodeTrack    any    `json:"episode_track"`
}

// dongpiandiResolveResp 对应 /v1/playback/resolve/{token}。
// short_drama 返回 resolved=true、resolve_mode=direct 的 m3u8 URL。
type dongpiandiResolveResp struct {
	Object        string              `json:"object"`
	Token         string              `json:"token"`
	LineOptions   []dongpiandiLine    `json:"line_options"`
	CurrentEpisode dongpiandiResolved `json:"current_episode"`
}

type dongpiandiResolved struct {
	ID     string         `json:"id"`
	Token  string         `json:"token"`
	Number int            `json:"episode_number"`
	URLs   map[string]any `json:"urls"`
}

type dongpiandiLine struct {
	ID               string `json:"id"`
	ProviderID       string `json:"provider_id"`
	ProviderName     string `json:"provider_name"`
	PlayFrom         string `json:"play_from"`
	Label            string `json:"label"`
	URL              string `json:"url"`
	URLKind          string `json:"url_kind"`
	Resolved         bool   `json:"resolved"`
	ResolveMode      string `json:"resolve_mode"`
	ResolveRequired  bool   `json:"resolve_required"`
	DefaultPriority  bool   `json:"default_priority"`
	Selected         bool   `json:"selected"`
	PreferenceWeight int    `json:"preference_weight"`
}

// fetchDongpiandiDetail 拉取详情并同步解析每一集的 m3u8 地址。
// 对于 short_drama，episodes 字段是批次（如 第1-20集），每个批次一个 m3u8。
func (d *Downloader) fetchDongpiandiDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	if strings.TrimSpace(sourceID) == "" || len(sourceID) > 256 {
		return Drama{}, nil, errors.New("真果·鉴 sourceID 不合法")
	}
	client := newDongpiandiClient()

	body, err := client.get(ctx, "/v1/catalog/"+url.PathEscape(sourceID), nil)
	if err != nil {
		return Drama{}, nil, err
	}
	var detail dongpiandiDetail
	if err := json.Unmarshal(body, &detail); err != nil {
		return Drama{}, nil, fmt.Errorf("dongpiandi: 解析详情失败: %w", err)
	}
	if detail.Title == "" {
		return Drama{}, nil, errors.New("真果·鉴返回的详情不完整")
	}

	tags := make([]string, 0, 16)
	seen := map[string]bool{}
	addTag := func(s string) {
		s = strings.TrimSpace(s)
		if s == "" || seen[s] || len([]rune(s)) > 48 || len(tags) >= 16 {
			return
		}
		seen[s] = true
		tags = append(tags, s)
	}
	for _, g := range detail.Genres {
		addTag(g)
	}
	if detail.Area != "" {
		addTag(detail.Area)
	}
	if detail.Year > 0 {
		addTag(strconv.Itoa(detail.Year) + "年")
	}
	if detail.Remark != "" {
		addTag(detail.Remark)
	}

	epCount := detail.AvailableEpisodeCount
	if epCount <= 0 {
		epCount = detail.CurrentEpisodeCount
	}
	if epCount <= 0 {
		epCount = detail.EpisodeCount
	}
	if epCount <= 0 {
		epCount = len(detail.Episodes)
	}
	total := detail.TotalEpisodeCount
	if total <= 0 {
		total = epCount
	}

	drama := Drama{
		ID:            providerDramaID(sourceDongpiandi, detail.ID),
		Source:        sourceDongpiandi,
		SourceID:      detail.ID,
		Title:         truncate(detail.Title, 256),
		Name:          truncate(detail.Title, 256),
		Desc:          truncate(detail.Description, 12000),
		Intro:         truncate(detail.Description, 12000),
		Cover:         detail.PosterURL,
		CoverURL:      detail.PosterURL,
		Image:         detail.PosterURL,
		Pic:           detail.PosterURL,
		Poster:        detail.PosterURL,
		Remark:        detail.EpisodeProgressText,
		Tags:          tags,
		ChannelName:   "真果·鉴",
		Category:      dongpiandiKindLabel(detail.ContentKind),
		EpisodeCount:  total,
		TotalEpisode:  total,
	}

	// 对每集同步调用 playback resolve，拿到真实 m3u8。
	chapters := make([]Chapter, 0, len(detail.Episodes))
	for i, ep := range detail.Episodes {
		if ep.Token == "" {
			continue
		}
		resolveBody, err := client.get(ctx, "/v1/playback/resolve/"+url.PathEscape(ep.Token), nil)
		var m3u8 string
		if err == nil {
			var resp dongpiandiResolveResp
			if json.Unmarshal(resolveBody, &resp) == nil {
				m3u8 = dongpiandiPickM3U8(resp.LineOptions)
			}
		}
		num := dongpiandiEpisodeNumber(ep.Number, i+1)
		title := strings.TrimSpace(ep.Title)
		if title == "" {
			title = "第" + strconv.Itoa(num) + "集"
		}
		chapter := Chapter{
			ID:       providerDramaID(sourceDongpiandi, ep.ID),
			Source:   sourceDongpiandi,
			Title:    title,
			VideoURL: m3u8,
			PageURL:  dongpiandiBaseURL + "/player/" + url.PathEscape(detail.ID),
			Referer:  dongpiandiBaseURL + "/",
		}
		raw, _ := json.Marshal(num)
		chapter.CurrentEpisode = raw
		chapters = append(chapters, chapter)
	}

	return drama, chapters, nil
}

// dongpiandiPickM3U8 从线路数组里挑出最优 m3u8：
// 优先选 selected=true 或 preference_weight 最高的，必须 resolved=true 且是 m3u8/mp4。
func dongpiandiPickM3U8(lines []dongpiandiLine) string {
	if len(lines) == 0 {
		return ""
	}
	best := lines[0]
	bestScore := dongpiandiLineScore(best)
	for _, l := range lines[1:] {
		if s := dongpiandiLineScore(l); s > bestScore {
			best = l
			bestScore = s
		}
	}
	if !best.Resolved || best.URL == "" {
		return ""
	}
	lower := strings.ToLower(best.URL)
	if !strings.HasSuffix(lower, ".m3u8") && !strings.HasSuffix(lower, ".mp4") && !strings.HasPrefix(best.URL, "http") {
		return ""
	}
	return best.URL
}

func dongpiandiLineScore(l dongpiandiLine) int {
	score := l.PreferenceWeight
	if l.Resolved {
		score += 10000
	}
	if l.Selected {
		score += 5000
	}
	if l.DefaultPriority {
		score += 2000
	}
	if l.URLKind == "m3u8" || l.URLKind == "mp4" {
		score += 1000
	}
	return score
}

func dongpiandiEpisodeNumber(v any, fallback int) int {
	switch n := v.(type) {
	case float64:
		if n > 0 && n < 1e7 {
			return int(n)
		}
	case int:
		if n > 0 {
			return n
		}
	case json.Number:
		if i, err := n.Int64(); err == nil && i > 0 {
			return int(i)
		}
	case string:
		if i, err := strconv.Atoi(strings.TrimSpace(n)); err == nil && i > 0 {
			return i
		}
	}
	return fallback
}

// searchDongpiandi 用 /v1/browse/catalog 的 kind=short_drama 做关键字过滤。
// 上游专用的 /v1/catalog/search 返回 500，因此先用目录端点模拟搜索。
func (d *Downloader) searchDongpiandi(ctx context.Context, query string) ([]Drama, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("搜索关键字不能为空")
	}
	items, _, err := d.fetchDongpiandiCatalogPage(ctx, 1, "short_drama", query)
	if err != nil {
		return nil, err
	}
	if query == "" {
		return items, nil
	}
	lq := strings.ToLower(query)
	filtered := items[:0]
	for _, it := range items {
		if strings.Contains(strings.ToLower(it.Title), lq) {
			filtered = append(filtered, it)
		}
	}
	if len(filtered) == 0 {
		return items, nil
	}
	return filtered, nil
}

// fetchDongpiandiCategories 返回静态一级分类。
// 上游 /v1/browse/catalog 通过 kind 参数（short_drama/series/movie/anime/variety 等）切换。
func fetchDongpiandiCategories() []nativeCategory {
	return []nativeCategory{
		{ID: "short_drama", Name: "短剧"},
		{ID: "series", Name: "电视剧"},
		{ID: "movie", Name: "电影"},
		{ID: "anime", Name: "动画"},
		{ID: "variety", Name: "综艺"},
	}
}
