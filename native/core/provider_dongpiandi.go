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
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// AI 聚合站 dongpiandi.ai 的 REST API 根地址。平台用静态 HMAC-SHA256 密钥签名
// /v1/* 请求，返回聚合后的目录/详情/播放解析；短剧（kind=short_drama）直接返回
// m3u8 URL，无需二次票据解析。
// dongpiandiBaseURLDefault 为内置兜底；根地址可经 config.source（applySourceConfig）
// 远程热更（域名被墙/失效时切镜像根）。签名密钥 dongpiandiSignKey 不参与远程下发。
const (
	dongpiandiBaseURLDefault = "https://dongpiandi.ai"
	dongpiandiSignKey        = "8b9a908a05eac640e1ee06f52acaa741bfe4ba9e004eeffdbeb635e532e06666"
	dongpiandiSiteHost       = "dongpiandi.ai"
	dongpiandiClientUA       = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
	dongpiandiTimeout        = 15 * time.Second
)

var (
	dongpiandiConfigMu   sync.RWMutex
	dongpiandiBaseURLHot string
)

// dongpiandiBaseURL 返回当前 API 根地址：热更值优先，空则回退内置。
func dongpiandiBaseURL() string {
	dongpiandiConfigMu.RLock()
	defer dongpiandiConfigMu.RUnlock()
	if dongpiandiBaseURLHot != "" {
		return dongpiandiBaseURLHot
	}
	return dongpiandiBaseURLDefault
}

// setDongpiandiBaseURL 热更 API 根地址（调用方负责校验；传空回退内置）。
func setDongpiandiBaseURL(base string) {
	dongpiandiConfigMu.Lock()
	defer dongpiandiConfigMu.Unlock()
	dongpiandiBaseURLHot = base
}

// dongpiandiBaseURLCandidates 返回解析缓存 PageURL 的根地址候选（当前值在前、
// 内置值兜底，已去重）：旧缓存内嵌旧域名，切换根地址后仍需可解析出剧集 ID。
func dongpiandiBaseURLCandidates() []string {
	current := dongpiandiBaseURL()
	if current == dongpiandiBaseURLDefault {
		return []string{dongpiandiBaseURLDefault}
	}
	return []string{current, dongpiandiBaseURLDefault}
}

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

	reqURL := dongpiandiBaseURL() + full
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
	req.Header.Set("Origin", dongpiandiBaseURL())
	req.Header.Set("Referer", dongpiandiBaseURL()+"/")

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
	Object     string                  `json:"object"`
	Cards      []dongpiandiCatalogCard `json:"cards"`
	Pagination struct {
		Total   int  `json:"total"`
		Page    int  `json:"page"`
		Limit   int  `json:"limit"`
		HasMore bool `json:"has_more"`
	} `json:"pagination"`
}

// fetchDongpiandiCatalogPage 拉取目录分页。默认不传 kind，上游返回全类型热门；
// 按 kind 切换短剧/电视剧/电影/动画/综艺。上游返回固定 total 占位，按 has_more 判断。
func (d *Downloader) fetchDongpiandiCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	client := newDongpiandiClient()
	q := url.Values{}
	q.Set("page", strconv.Itoa(page))
	q.Set("limit", "20")
	if category != "" {
		q.Set("kind", category)
	} else if query != "" {
		q.Set("q", query)
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
	heat := dongpiandiHeat(card.HeatValue)
	if len(tags) == 0 {
		add("短剧")
	}

	return Drama{
		ID:           providerDramaID(sourceDongpiandi, card.ID),
		Source:       sourceDongpiandi,
		SourceID:     card.ID,
		Title:        truncate(card.Title, 256),
		Name:         truncate(card.Title, 256),
		Cover:        card.PosterURL,
		CoverURL:     card.PosterURL,
		Image:        card.PosterURL,
		Pic:          card.PosterURL,
		Poster:       card.PosterURL,
		Tags:         tags,
		Score:        score,
		Heat:         heat,
		Remark:       card.Remark,
		EpisodeCount: epCount,
		TotalEpisode: epCount,
		ChannelName:  "真果·鉴",
		Category:     dongpiandiKindLabel(card.ContentKind),
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

// dongpiandiHeat 把 heat_value（数字或字符串）格式化为"X万热度/X亿热度"。
func dongpiandiHeat(v any) string {
	var n float64
	switch x := v.(type) {
	case float64:
		n = x
	case int:
		n = float64(x)
	case json.Number:
		if parsed, err := x.Float64(); err == nil {
			n = parsed
		}
	case string:
		parsed, err := strconv.ParseFloat(strings.TrimSpace(x), 64)
		if err != nil {
			return ""
		}
		n = parsed
	default:
		return ""
	}
	if n <= 0 {
		return ""
	}
	switch {
	case n >= 1e8:
		return strconv.FormatFloat(n/1e8, 'f', 1, 64) + "亿热度"
	case n >= 1e4:
		return strconv.FormatFloat(n/1e4, 'f', 1, 64) + "万热度"
	default:
		return strconv.FormatInt(int64(n), 10) + "热度"
	}
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
	ID                    string              `json:"id"`
	Title                 string              `json:"title"`
	ContentKind           string              `json:"content_kind"`
	Year                  int                 `json:"year"`
	Area                  string              `json:"area"`
	Language              string              `json:"language"`
	Genres                []string            `json:"genres"`
	Actors                []string            `json:"actors"`
	Directors             []string            `json:"directors"`
	PosterURL             string              `json:"poster_url"`
	Description           string              `json:"description"`
	Remark                string              `json:"remarks"`
	EpisodeCount          int                 `json:"episode_count"`
	AvailableEpisodeCount int                 `json:"available_episode_count"`
	CurrentEpisodeCount   int                 `json:"current_episode_count"`
	TotalEpisodeCount     int                 `json:"total_episode_count"`
	IsCompleted           bool                `json:"is_completed"`
	UpdateStatus          string              `json:"update_status"`
	EpisodeProgressText   string              `json:"episode_progress_text"`
	Episodes              []dongpiandiEpisode `json:"episodes"`
	EpisodePagination     struct {
		Offset     int  `json:"offset"`
		Limit      int  `json:"limit"`
		HasMore    bool `json:"has_more"`
		TotalCount int  `json:"total_count"`
	} `json:"episode_pagination"`
}

type dongpiandiEpisode struct {
	ID            string `json:"id"`
	Key           string `json:"key"`
	Title         string `json:"title"`
	Number        any    `json:"number"`
	Token         string `json:"token"`
	PlaybackCount int    `json:"playback_count"`
	PlaybackURL   string `json:"playback_url"`
	EpisodeTrack  any    `json:"episode_track"`
}

// dongpiandiResolveResp 对应 /v1/playback/resolve/{token}。
// short_drama 返回 resolved=true、resolve_mode=direct 的 m3u8 URL。
type dongpiandiResolveResp struct {
	Object         string             `json:"object"`
	Token          string             `json:"token"`
	LineOptions    []dongpiandiLine   `json:"line_options"`
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
		ID:           providerDramaID(sourceDongpiandi, detail.ID),
		Source:       sourceDongpiandi,
		SourceID:     detail.ID,
		Title:        truncate(detail.Title, 256),
		Name:         truncate(detail.Title, 256),
		Desc:         truncate(detail.Description, 12000),
		Intro:        truncate(detail.Description, 12000),
		Cover:        detail.PosterURL,
		CoverURL:     detail.PosterURL,
		Image:        detail.PosterURL,
		Pic:          detail.PosterURL,
		Poster:       detail.PosterURL,
		Remark:       detail.EpisodeProgressText,
		Tags:         tags,
		ChannelName:  "真果·鉴",
		Category:     dongpiandiKindLabel(detail.ContentKind),
		EpisodeCount: total,
		TotalEpisode: total,
	}

	// 对每集并发调用 playback resolve，拿到真实 m3u8（按原序回填）。
	chapters := make([]Chapter, len(detail.Episodes))
	var wg sync.WaitGroup
	sem := make(chan struct{}, 4)
	for i := range detail.Episodes {
		ep := detail.Episodes[i]
		if ep.Token == "" {
			continue
		}
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			m3u8, _ := dongpiandiResolveEpisodeM3U8(ctx, client, ep.Token, false)
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
				PageURL:  dongpiandiBaseURL() + "/player/" + url.PathEscape(detail.ID),
				Referer:  dongpiandiBaseURL() + "/",
			}
			raw, _ := json.Marshal(num)
			chapter.CurrentEpisode = raw
			chapters[i] = chapter
		}()
	}
	wg.Wait()
	compact := make([]Chapter, 0, len(chapters))
	for _, chapter := range chapters {
		if chapter.ID != "" {
			compact = append(compact, chapter)
		}
	}

	return drama, compact, nil
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

// dongpiandiResolveEpisodeM3U8 对单集调用 playback resolve 拿播放地址。
// probe=false 按站点权重直接挑线（详情页快速路径）；
// probe=true 对权重最高的若干条已解析线路并发实测（可达性 + 首分片吞吐）后择优，
// 实测无结果时回退权重挑线。真网实测站点推荐的线路可能只有 ~200KB/s 甚至 404，
// 这是"真果·鉴一卡一卡"的直接根因，所以播放前必须实测。
func dongpiandiResolveEpisodeM3U8(ctx context.Context, client *dongpiandiClient, epToken string, probe bool) (string, error) {
	body, err := client.get(ctx, "/v1/playback/resolve/"+url.PathEscape(epToken), nil)
	if err != nil {
		return "", err
	}
	var resp dongpiandiResolveResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return "", fmt.Errorf("dongpiandi: 解析播放响应失败: %w", err)
	}
	if probe {
		if best := dongpiandiProbeBest(ctx, resp.LineOptions); best != "" {
			return best, nil
		}
	}
	return dongpiandiPickM3U8(resp.LineOptions), nil
}

// dongpiandiProbeCandidates 取权重最高的前 N 条已解析 m3u8/mp4 线路作为实测候选。
func dongpiandiProbeCandidates(lines []dongpiandiLine) []dongpiandiLine {
	scored := make([]dongpiandiLine, 0, len(lines))
	for _, l := range lines {
		if !l.Resolved || l.URL == "" {
			continue
		}
		lower := strings.ToLower(l.URL)
		if !strings.Contains(lower, ".m3u8") && !strings.Contains(lower, ".mp4") {
			continue
		}
		scored = append(scored, l)
	}
	sort.SliceStable(scored, func(i, j int) bool {
		return dongpiandiLineScore(scored[i]) > dongpiandiLineScore(scored[j])
	})
	if len(scored) > 4 {
		scored = scored[:4]
	}
	return scored
}

type dongpiandiProbeResult struct {
	url      string
	ready    bool
	ttfb     time.Duration
	segBytes int64
	segDur   time.Duration
}

// dongpiandiProbeBest 并发实测候选线路（整体预算 6 秒，到点收已完成者）：
// 首分片吞吐最高且 >=64KB 者胜；无分片数据时取 m3u8 响应最快者；全部失败返回空串。
func dongpiandiProbeBest(ctx context.Context, lines []dongpiandiLine) string {
	candidates := dongpiandiProbeCandidates(lines)
	if len(candidates) == 0 {
		return ""
	}
	probeCtx, cancel := context.WithTimeout(ctx, 4500*time.Millisecond)
	defer cancel()
	results := make([]dongpiandiProbeResult, len(candidates))
	var wg sync.WaitGroup
	for i := range candidates {
		i, line := i, candidates[i]
		wg.Add(1)
		go func() {
			defer wg.Done()
			results[i] = dongpiandiProbeLine(probeCtx, line.URL)
		}()
	}
	done := make(chan struct{})
	go func() { wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-probeCtx.Done():
	}
	best := -1
	for i := range results {
		r := results[i]
		if !r.ready {
			continue
		}
		if best < 0 {
			best = i
			continue
		}
		b := results[best]
		bSeg := b.segBytes >= 64*1024
		cSeg := r.segBytes >= 64*1024
		switch {
		case cSeg && !bSeg:
			best = i
		case cSeg == bSeg && cSeg:
			if r.segDur > 0 && (b.segDur <= 0 || float64(r.segBytes)*float64(b.segDur) > float64(b.segBytes)*float64(r.segDur)) {
				best = i
			}
		case !cSeg && !bSeg && (r.ttfb < b.ttfb || !b.ready):
			best = i
		}
	}
	if best >= 0 {
		return results[best].url
	}
	return ""
}

// dongpiandiProbeLine 实测单条线路：拉 m3u8 主单（可达性）+ 下载首个分片前 256KB 计吞吐。
func dongpiandiProbeLine(ctx context.Context, address string) dongpiandiProbeResult {
	res := dongpiandiProbeResult{url: address}
	lower := strings.ToLower(address)
	if strings.Contains(lower, ".mp4") {
		total, dur, _ := dongpiandiFetchSpeedCapture(ctx, address, 256*1024)
		if total > 0 {
			res.ready = true
			res.segBytes, res.segDur = total, dur
		}
		return res
	}
	t0 := time.Now()
	body, err := dongpiandiFetchLimited(ctx, address, 96*1024)
	res.ttfb = time.Since(t0)
	if err != nil || !strings.Contains(string(body), "#EXTM3U") {
		return res
	}
	res.ready = true
	seg := dongpiandiFirstSegment(address, string(body))
	if seg == "" {
		return res
	}
	total, dur := dongpiandiProbeMediaSpeed(ctx, seg, 0)
	res.segBytes, res.segDur = total, dur
	return res
}

// dongpiandiProbeMediaSpeed 测一个媒体地址的吞吐；若返回内容是嵌套 m3u8（master）
// 则下钻一层继续测真实分片，最多两层。
func dongpiandiProbeMediaSpeed(ctx context.Context, address string, depth int) (int64, time.Duration) {
	total, dur, head := dongpiandiFetchSpeedCapture(ctx, address, 256*1024)
	if depth < 2 && total > 0 && total < 64*1024 && strings.Contains(head, "#EXTM3U") {
		if next := dongpiandiFirstSegment(address, head); next != "" {
			return dongpiandiProbeMediaSpeed(ctx, next, depth+1)
		}
	}
	return total, dur
}

// dongpiandiFetchLimited GET 一个地址，最多读 limit 字节；非 2xx 视为失败。
func dongpiandiFetchLimited(ctx context.Context, address string, limit int64) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", dongpiandiClientUA)
	resp, err := (&http.Client{Timeout: 5 * time.Second}).Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return nil, fmt.Errorf("dongpiandi: 媒体地址 HTTP %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, limit))
}

// dongpiandiFetchSpeedCapture 以 Range 请求下载最多 maxBytes，返回 (前512字节, 总字节, 耗时)。
func dongpiandiFetchSpeedCapture(ctx context.Context, address string, maxBytes int64) (int64, time.Duration, string) {
	ctx, cancel := context.WithTimeout(ctx, 4*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return 0, 0, ""
	}
	req.Header.Set("User-Agent", dongpiandiClientUA)
	req.Header.Set("Range", "bytes=0-"+strconv.FormatInt(maxBytes-1, 10))
	start := time.Now()
	resp, err := (&http.Client{Timeout: 4 * time.Second}).Do(req)
	if err != nil {
		return 0, 0, ""
	}
	defer resp.Body.Close()
	if resp.StatusCode/100 != 2 {
		return 0, 0, ""
	}
	buf := make([]byte, 32*1024)
	var total int64
	var head []byte
	for total < maxBytes {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if len(head) < 512 {
				head = append(head, buf[:min(n, 512-len(head))]...)
			}
			total += int64(n)
		}
		if err != nil {
			break
		}
	}
	return total, time.Since(start), string(head)
}

// dongpiandiFirstSegment 从 m3u8 文本解析第一个媒体条目地址（支持相对路径，
// master playlist 的下一级 m3u8 也按地址返回，由调用方下钻）。
func dongpiandiFirstSegment(base, body string) string {
	baseURL, err := url.Parse(base)
	if err != nil {
		return ""
	}
	for _, ln := range strings.Split(body, "\n") {
		ln = strings.TrimSpace(ln)
		if ln == "" || strings.HasPrefix(ln, "#") {
			continue
		}
		if ref, err := baseURL.Parse(ln); err == nil {
			return ref.String()
		}
	}
	return ""
}

// dongpiandiMediaAlive 轻量验证播放地址当前可用（m3u8 内容校验 / mp4 Range 2xx）。
func dongpiandiMediaAlive(ctx context.Context, address string) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if strings.Contains(strings.ToLower(address), ".mp4") {
		total, _, _ := dongpiandiFetchSpeedCapture(ctx, address, 16*1024)
		return total > 0
	}
	body, err := dongpiandiFetchLimited(ctx, address, 16*1024)
	return err == nil && strings.Contains(string(body), "#EXTM3U")
}

// dongpiandiDetailIDFromPageURL 从 /player/{id} 形态的章节页地址里抽剧集 ID。
// 兼容内置域名与热更域名：旧缓存内嵌旧域名，切根地址后仍需可解析。
func dongpiandiDetailIDFromPageURL(pageURL string) string {
	pageURL = strings.TrimSpace(pageURL)
	for _, base := range dongpiandiBaseURLCandidates() {
		marker := base + "/player/"
		if !strings.HasPrefix(pageURL, marker) {
			continue
		}
		id := strings.Trim(strings.TrimPrefix(pageURL, marker), "/")
		if id == "" || strings.ContainsAny(id, "/?#") {
			return ""
		}
		return id
	}
	return ""
}

// resolveDongpiandiMedia 播放期解析真果·鉴：
// 1) 详情页缓存的线路先轻量存活验证，可用即直接播（零额外等待）；
// 2) 失效（404/超时/非 m3u8）时按剧集 ID 重新解析并对候选线路实测择优，自动换线；
// 3) 全部失败回退原地址走通用路径，由上层报标准错误。
// 返回的 Referer 置空：实测资源站 CDN 不校验 Referer，且不带时吞吐明显更高。
func (d *Downloader) resolveDongpiandiMedia(ctx context.Context, task Task) (providerMedia, error) {
	address := strings.TrimSpace(task.Chapter.VideoURL)
	if address != "" && dongpiandiMediaAlive(ctx, address) {
		return d.prepareWebProviderMedia(ctx, providerMedia{URL: address}, "真果·鉴")
	}
	if detailID := dongpiandiDetailIDFromPageURL(strings.TrimSpace(task.Chapter.PageURL)); detailID != "" {
		if _, sourceID, valid := splitProviderDramaID(task.Chapter.ID); valid {
			client := newDongpiandiClient()
			body, err := client.get(ctx, "/v1/catalog/"+url.PathEscape(detailID), nil)
			if err == nil {
				var detail dongpiandiDetail
				if json.Unmarshal(body, &detail) == nil {
					for _, ep := range detail.Episodes {
						if ep.ID != sourceID || ep.Token == "" {
							continue
						}
						m3u8, err := dongpiandiResolveEpisodeM3U8(ctx, client, ep.Token, true)
						if err == nil && m3u8 != "" {
							return d.prepareWebProviderMedia(ctx, providerMedia{URL: m3u8}, "真果·鉴")
						}
						break
					}
				}
			}
		}
	}
	if address == "" {
		return providerMedia{}, errors.New("真果·鉴未返回有效播放地址，请刷新章节后重试")
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address}, "真果·鉴")
}

// searchDongpiandi 用 /v1/browse/catalog 关键字搜索。
// 上游专用的 /v1/catalog/search 返回 500，因此先用目录端点模拟搜索。
func (d *Downloader) searchDongpiandi(ctx context.Context, query string) ([]Drama, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("搜索关键字不能为空")
	}
	items, _, err := d.fetchDongpiandiCatalogPage(ctx, 1, "", query)
	if err != nil {
		return nil, err
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
// 空 category 代表全部热门（不传 kind）。
func fetchDongpiandiCategories() []nativeCategory {
	return []nativeCategory{
		{ID: "", Name: "全部"},
		{ID: "short_drama", Name: "短剧"},
		{ID: "series", Name: "电视剧"},
		{ID: "movie", Name: "电影"},
		{ID: "anime", Name: "动画"},
		{ID: "variety", Name: "综艺"},
	}
}
