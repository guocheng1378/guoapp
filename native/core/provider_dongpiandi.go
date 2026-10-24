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
	"net/http/cookiejar"
	"net/url"
	"regexp"
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
	// 官方线路兑换（resolve-line）要求服务端会话：游客先 POST
	// /v1/users/anonymous 建匿名账户（session cookie 落 jar），失败可重试。
	anonMu   sync.Mutex
	anonDone bool
	anonErr  error
	// 兑换并发闸门由同一 client 上的全部调用共享：详情页逐集解析会为每集
	// 各开一次 resolve，若每集再各自放大 6 个兑换请求，集数多时会瞬间打出
	// 上百个 POST。共享闸门把整部剧的兑换并发钉在 6。
	redeemOnce sync.Once
	redeemSem  chan struct{}
}

// redeemSlots 返回当前 client 的官方票据兑换闸门（懒建、全 client 共享）。
func (c *dongpiandiClient) redeemSlots() chan struct{} {
	c.redeemOnce.Do(func() { c.redeemSem = make(chan struct{}, 10) })
	return c.redeemSem
}

func newDongpiandiClient() *dongpiandiClient {
	jar, _ := cookiejar.New(nil)
	return &dongpiandiClient{
		http: &http.Client{Timeout: dongpiandiTimeout, Jar: jar},
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

// post 与 get 同构的 POST 请求（同样的签名与头），body 序列化为 JSON。
// path 可带查询串（如 /v1/playback/resolve-line?view=compact），签名按含 query
// 的完整路径计算。
func (c *dongpiandiClient) post(ctx context.Context, path string, body any) ([]byte, error) {
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	nonce := dongpiandiNonce()
	sig := dongpiandiSign("POST", path, ts, nonce)

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 序列化请求体失败: %w", err)
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, dongpiandiBaseURL()+path, strings.NewReader(string(payload)))
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 构造请求失败: %w", err)
	}
	req.Header.Set("x-ai-movie-timestamp", ts)
	req.Header.Set("x-ai-movie-nonce", nonce)
	req.Header.Set("x-ai-movie-signature", sig)
	req.Header.Set("x-ai-movie-site-host", dongpiandiSiteHost)
	req.Header.Set("Accept", "application/json")
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("User-Agent", dongpiandiClientUA)
	req.Header.Set("Origin", dongpiandiBaseURL())
	req.Header.Set("Referer", dongpiandiBaseURL()+"/")

	resp, err := c.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 请求失败: %w", err)
	}
	defer resp.Body.Close()
	data, err := io.ReadAll(io.LimitReader(resp.Body, 8*1024*1024))
	if err != nil {
		return nil, fmt.Errorf("dongpiandi: 读取响应失败: %w", err)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, fmt.Errorf("dongpiandi: HTTP %d: %s", resp.StatusCode, strings.TrimSpace(string(data)))
	}
	return data, nil
}

// ensureAnonymous 惰性建立匿名会话（POST /v1/users/anonymous）：官方线路
// resolve 返回 resolve:// 票据，第二步兑换（resolve-line）要求服务端会话，
// 未建号时兑换失败。失败不固化，下次调用重试（锁串行，最多一个在途）；
// 第三方直连线路不依赖会话，建号失败不影响它们。
func (c *dongpiandiClient) ensureAnonymous(ctx context.Context) error {
	c.anonMu.Lock()
	defer c.anonMu.Unlock()
	if c.anonDone {
		return c.anonErr
	}
	aid := make([]byte, 8)
	_, _ = rand.Read(aid)
	if _, err := c.post(ctx, "/v1/users/anonymous", map[string]string{
		"anonymous_id": "web_" + hex.EncodeToString(aid),
	}); err != nil {
		c.anonErr = err
		return c.anonErr
	}
	c.anonDone = true
	return nil
}

// dongpiandiRedeemTicketLine 兑换单条 resolve_ticket 线（官方线两步兑换的
// 第二步）：resolve 响应里官方线是 resolve://<ticket> 票据而非直链，需再
// POST /v1/playback/resolve-line?view=compact 换真实地址。兑换失败原样返回，
// 调用方按未解析线丢弃；成功后继承原线位的站点权重与选中语义。
// anonymousFailed 报告匿名会话是否已确定建不起来（已失败且未成功过）。
func (c *dongpiandiClient) anonymousFailed() bool {
	c.anonMu.Lock()
	defer c.anonMu.Unlock()
	return !c.anonDone && c.anonErr != nil
}

func dongpiandiRedeemTicketLine(ctx context.Context, client *dongpiandiClient, line dongpiandiLine) dongpiandiLine {
	ticket := strings.TrimPrefix(line.URL, "resolve://")
	if ticket == "" || ticket == line.URL {
		return line
	}
	if err := client.ensureAnonymous(ctx); err != nil {
		return line
	}
	data, err := client.post(ctx, "/v1/playback/resolve-line?view=compact", map[string]string{"ticket": ticket})
	if err != nil {
		return line
	}
	var ack struct {
		Line dongpiandiLine `json:"line"`
	}
	if err := json.Unmarshal(data, &ack); err != nil || strings.TrimSpace(ack.Line.URL) == "" {
		return line
	}
	red := ack.Line
	if strings.HasPrefix(red.URL, "resolve://") {
		return line
	}
	red.ID = line.ID
	red.Resolved = true
	red.Official = true
	if red.Label == "" {
		red.Label = line.Label
	}
	if red.Label == "" {
		red.Label = "官方线路"
	}
	red.Selected = line.Selected
	red.PreferenceWeight = line.PreferenceWeight
	return red
}

// dongpiandiRedeemTickets 批量并发兑换票据线路（worker 上限 6，保序回填），
// 只保留兑出真实媒体直链的线路（dongpiandiDirectMediaLine 判定）。
func dongpiandiRedeemTickets(ctx context.Context, client *dongpiandiClient, tickets []dongpiandiLine) []dongpiandiLine {
	out := make([]dongpiandiLine, len(tickets))
	sem := client.redeemSlots()
	var wg sync.WaitGroup
	for i, t := range tickets {
		wg.Add(1)
		go func(i int, t dongpiandiLine) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			out[i] = dongpiandiRedeemTicketLine(ctx, client, t)
			if dongpiandiDirectMediaLine(out[i]) || ctx.Err() != nil {
				return
			}
			// 匿名会话建不起来时重试只会再打一次建号请求，直接放弃。
			if client.anonymousFailed() {
				return
			}
			// resolve-line 偶发失败会静默丢一条官方线（真网探针：同一集
			// 3 张票据串行逐张全成功，并发批量偶尔只兑出 2 张），表现为
			// 「官方源显示不全」。失败后退避重试一次把它补回来。
			select {
			case <-time.After(250 * time.Millisecond):
			case <-ctx.Done():
				return
			}
			if retried := dongpiandiRedeemTicketLine(ctx, client, t); dongpiandiDirectMediaLine(retried) {
				out[i] = retried
			}
		}(i, t)
	}
	wg.Wait()
	kept := make([]dongpiandiLine, 0, len(out))
	for _, l := range out {
		if dongpiandiDirectMediaLine(l) {
			kept = append(kept, l)
		}
	}
	return kept
}

// dongpiandiCatalogCard 对应 /v1/browse/catalog 的单条记录。
type dongpiandiCatalogCard struct {
	ID              string                    `json:"id"`
	Title           string                    `json:"title"`
	NormalizedTitle string                    `json:"normalized_title"`
	ContentKind     string                    `json:"content_kind"`
	Year            int                       `json:"year"`
	Area            string                    `json:"area"`
	Language        string                    `json:"language"`
	Genres          []string                  `json:"genres"`
	Actors          []string                  `json:"actors"`
	Directors       []string                  `json:"directors"`
	PosterURL       string                    `json:"poster_url"`
	Score           any                       `json:"score"`
	Remark          string                    `json:"remarks"`
	PlaybackEntry   any                       `json:"playback_entry"`
	PlaybackCount   int                       `json:"playback_count"`
	PlaybackGroups  []dongpiandiPlaybackGroup `json:"playback_groups"`
	HeatValue       any                       `json:"heat_value"`
}

// dongpiandiPlaybackGroup 是卡片上的一个播放组（网页播放器/m3u8/API），
// episode_count 是该组的集数——封面集数的权威来源（探针实测与 remarks
// 「全N集/更新至N集」吻合）。playback_count（卡片级）是总播放量，不是集数。
type dongpiandiPlaybackGroup struct {
	ID           string `json:"id"`
	Label        string `json:"label"`
	Type         string `json:"type"`
	EpisodeCount int    `json:"episode_count"`
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

	// 集数取 playback_groups[].episode_count（探针实测与 remarks 吻合的
	// 权威字段）；卡片没有播放组时回落 0——封面由 Dart 侧 episodes<=0
	// 守卫不渲染「共 N 集」，详情页返回正规 AvailableEpisodeCount 后经
	// Drama.merge 自愈。playback_count 是总播放量，绝不能当集数。
	epCount := 0
	for _, group := range card.PlaybackGroups {
		if group.EpisodeCount > epCount {
			epCount = group.EpisodeCount
		}
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
	TokenScenario    string `json:"token_scenario"`
	Resolved         bool   `json:"resolved"`
	ResolveMode      string `json:"resolve_mode"`
	ResolveRequired  bool   `json:"resolve_required"`
	DefaultPriority  bool   `json:"default_priority"`
	Selected         bool   `json:"selected"`
	PreferenceWeight int    `json:"preference_weight"`
	// Official 标记该线路由官方票据（resolve://）兑换而来。用户定调
	// 「默认就进官方源」：官方线排序恒优先，只有在实测完全不可达时
	// 才让位给三方线路。
	Official bool `json:"-"`
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

	// 分集去重先做：集数统计与批次解析都要用去重后的列表（上游个别条目会
	// 重复投放，同 ID 只保留首个，杜绝选集重复与集数虚高）。
	episodes := make([]dongpiandiEpisode, 0, len(detail.Episodes))
	seenEpisode := map[string]bool{}
	for _, ep := range detail.Episodes {
		if ep.Token == "" || ep.ID == "" || seenEpisode[ep.ID] {
			continue
		}
		seenEpisode[ep.ID] = true
		episodes = append(episodes, ep)
	}

	epCount := detail.AvailableEpisodeCount
	if epCount <= 0 {
		epCount = detail.CurrentEpisodeCount
	}
	if epCount <= 0 {
		epCount = detail.EpisodeCount
	}
	if epCount <= 0 {
		epCount = len(episodes)
	}
	total := detail.TotalEpisodeCount
	if total <= 0 {
		total = epCount
	}
	// 短剧把 20 集打包成一个播放列表（key=range-0001-0020，标题「第1-20集」），
	// 此时 available/current 是批次数不是集数。批次覆盖的最大集号才是真实
	// 总集数——total 缺失或偏小时用它兜底，避免封面/详情显示「共 4 集」。
	if batch := dongpiandiBatchTotal(episodes); batch > total {
		total = batch
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
	chapters := make([]Chapter, len(episodes))
	var wg sync.WaitGroup
	// 6 路并发：每集要一次 resolve（+官方票据兑换），真网实测 4 路时
	// 13 集要 5.8s，提到 6 路可压到 3s 级；兑换并发由 client 共享闸门兜住。
	sem := make(chan struct{}, 6)
	for i := range episodes {
		ep := episodes[i]
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			// 全量兑换官方票据（不再「有直连就跳过」）：详情算出的地址要默认
			// 落在官方线，且整张线路表供播放器选源，缓存后播放期零等待。
			lines, _ := dongpiandiResolveLinesAll(ctx, client, ep.Token)
			m3u8 := ""
			if len(lines) > 0 {
				m3u8 = lines[0].URL
				dongpiandiCacheLines(ep.ID, lines)
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
	if l.Official {
		// 官方线恒压过任何三方线（用户定调：默认就进官方源）。
		// 30000 足以覆盖权重+selected 的组合差异，实测择优与回退都按此序。
		score += 30000
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

var dongpiandiRangePattern = regexp.MustCompile(`(\d{1,5})\s*[-~至]\s*(\d{1,5})`)

// dongpiandiBatchTotal 从批次分集的 key（range-0001-0020）或标题（第1-20集）
// 解析批次覆盖的最大集号；纯单集条目返回 0。短剧把一个 20 集批次打包成一个
// 播放列表，total_episode_count 缺失时这是唯一可信的总集数来源。
func dongpiandiBatchTotal(episodes []dongpiandiEpisode) int {
	maxNumber := 0
	for _, ep := range episodes {
		for _, text := range []string{ep.Key, ep.Title} {
			match := dongpiandiRangePattern.FindStringSubmatch(text)
			if match == nil {
				continue
			}
			start, errStart := strconv.Atoi(match[1])
			end, errEnd := strconv.Atoi(match[2])
			if errStart != nil || errEnd != nil || end < start || end > 10000 {
				continue
			}
			if end > maxNumber {
				maxNumber = end
			}
		}
	}
	return maxNumber
}

// dongpiandiResolveEpisodeM3U8 对单集调用 playback resolve 拿播放地址。
// probe=false 按站点权重直接挑线（详情页快速路径）；
// probe=true 对权重最高的若干条已解析线路并发实测（可达性 + 首分片吞吐）后择优，
// 实测无结果时回退权重挑线。真网实测站点推荐的线路可能只有 ~200KB/s 甚至 404，
// 这是"真果·鉴一卡一卡"的直接根因，所以播放前必须实测。
func dongpiandiResolveEpisodeM3U8(ctx context.Context, client *dongpiandiClient, epToken string, probe bool) (string, error) {
	lines, err := dongpiandiResolveLines(ctx, client, epToken, probe)
	if err != nil {
		return "", err
	}
	if len(lines) == 0 {
		return "", nil
	}
	return lines[0].URL, nil
}

// dongpiandiDirectMediaLine 判定一条线路是否为可直接播放的媒体直链。
// resolve:// 票据恒否；URLKind m3u8/mp4 优先，URL 扩展名兜底，http(s)
// 前缀保底——真网探针（probe3）实锤：官方票据兑换产物 URL 常无媒体后缀
// （甚至带 .image.image 图片后缀）、CDN Content-Type 误标为 image/jpeg，
// 但字节流是合法 mp4（ftyp/moov，mvhd 时长与三方直链全片一致），按后缀
// 硬判会误杀官方线，故已解析线路只要 URL 是 http(s) 即放行。
// 例外：url_kind=page 是网页播放器线（URL 指向网页而非媒体流），恒否。
func dongpiandiDirectMediaLine(line dongpiandiLine) bool {
	if line.URL == "" || strings.HasPrefix(line.URL, "resolve://") {
		return false
	}
	if line.URLKind == "m3u8" || line.URLKind == "mp4" {
		return true
	}
	if line.URLKind == "page" {
		return false
	}
	lower := strings.ToLower(line.URL)
	if strings.Contains(lower, ".m3u8") || strings.Contains(lower, ".mp4") {
		return true
	}
	return strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://")
}

// dongpiandiResolveLines 调用 playback resolve 并返回全部已解析直链线路，
// 按站点权重（官方线恒优先 → selected/weight/url_kind）降序；probe=true 时
// 把实测吞吐最优者置换到首位（全挂则保持权重序）。
//
// 官方线两步兑换：resolve 返回的官方线路是 resolve:// 票据（resolved=false），
// 需匿名会话后再 POST resolve-line 兑换直链。历史快路径（probe=false）在有
// 直连线时完全跳过兑换、无直连时只兑首张，正是「一会儿有一回没官方源」
// 「官方源显示的不全」的根因；现在生产路径一律全量兑换（full=true），
// probe 仅决定是否实测择优。
func dongpiandiResolveLines(ctx context.Context, client *dongpiandiClient, epToken string, probe bool) ([]dongpiandiLine, error) {
	return dongpiandiResolveLinesMode(ctx, client, epToken, probe, probe)
}

// dongpiandiResolveLinesAll 全量兑换官方票据但不实测：详情页逐集解析与
// 播放器线路列表都走这条，保证官方线路一条不漏、选集默认落在官方线。
func dongpiandiResolveLinesAll(ctx context.Context, client *dongpiandiClient, epToken string) ([]dongpiandiLine, error) {
	return dongpiandiResolveLinesMode(ctx, client, epToken, false, true)
}

func dongpiandiResolveLinesMode(ctx context.Context, client *dongpiandiClient, epToken string, probe, full bool) ([]dongpiandiLine, error) {
	body, err := client.get(ctx, "/v1/playback/resolve/"+url.PathEscape(epToken), nil)
	if err != nil {
		return nil, err
	}
	var resp dongpiandiResolveResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("dongpiandi: 解析播放响应失败: %w", err)
	}
	var tickets []dongpiandiLine
	lines := make([]dongpiandiLine, 0, len(resp.LineOptions))
	for _, line := range resp.LineOptions {
		if !line.Resolved || line.URL == "" {
			if strings.HasPrefix(line.URL, "resolve://") {
				tickets = append(tickets, line)
			}
			continue
		}
		if !dongpiandiDirectMediaLine(line) {
			continue
		}
		lines = append(lines, line)
	}
	if len(tickets) > 0 {
		redeem := tickets
		if !full {
			if len(lines) > 0 {
				redeem = nil
			} else if len(redeem) > 1 {
				redeem = redeem[:1]
			}
		}
		if len(redeem) > 0 {
			lines = append(lines, dongpiandiRedeemTickets(ctx, client, redeem)...)
		}
	}
	sort.SliceStable(lines, func(i, j int) bool {
		return dongpiandiLineScore(lines[i]) > dongpiandiLineScore(lines[j])
	})
	if probe {
		if best := dongpiandiProbeBest(ctx, lines); best != "" {
			for i, line := range lines {
				if line.URL == best {
					bestLine := lines[i]
					copy(lines[1:i+1], lines[0:i])
					lines[0] = bestLine
					break
				}
			}
		}
	}
	return lines, nil
}

// dongpiandiLineMedia 把一条线路转换为播放媒体（Label 供播放器线路按钮显示）。
func dongpiandiLineMedia(line dongpiandiLine) providerMedia {
	label := strings.TrimSpace(line.Label)
	if label == "" {
		label = strings.TrimSpace(line.ProviderName)
	}
	if label == "" {
		label = strings.TrimSpace(line.PlayFrom)
	}
	return providerMedia{URL: line.URL, Label: label, Official: line.Official}
}

// dongpiandiProbeCandidates 取实测候选：官方线优先全部纳入（调用方先测官方
// 组），再用权重最高的三方线补足——官方线权重可能低于三方，不能被「全局
// top N」挤掉。
func dongpiandiProbeCandidates(lines []dongpiandiLine) []dongpiandiLine {
	scored := make([]dongpiandiLine, 0, len(lines))
	for _, l := range lines {
		if !l.Resolved || !dongpiandiDirectMediaLine(l) {
			continue
		}
		scored = append(scored, l)
	}
	sort.SliceStable(scored, func(i, j int) bool {
		return dongpiandiLineScore(scored[i]) > dongpiandiLineScore(scored[j])
	})
	official := make([]dongpiandiLine, 0, 4)
	others := make([]dongpiandiLine, 0, 4)
	for _, l := range scored {
		if l.Official {
			if len(official) < 4 {
				official = append(official, l)
			}
			continue
		}
		others = append(others, l)
	}
	if limit := 4 - len(official); limit <= 0 {
		others = nil
	} else if len(others) > limit {
		others = others[:limit]
	}
	return append(official, others...)
}

type dongpiandiProbeResult struct {
	url      string
	ready    bool
	ttfb     time.Duration
	segBytes int64
	segDur   time.Duration
}

// dongpiandiProbeBest 选择主播放线路：先实测官方线组，任一可达即用官方线
// （用户定调「默认就进官方源」）；官方组整体不可达才降级实测三方线组。
// 两组各自有预算，官方组 3 秒、三方组 3.5 秒，最坏 6.5 秒。
func dongpiandiProbeBest(ctx context.Context, lines []dongpiandiLine) string {
	candidates := dongpiandiProbeCandidates(lines)
	if len(candidates) == 0 {
		return ""
	}
	official := make([]dongpiandiLine, 0, len(candidates))
	others := make([]dongpiandiLine, 0, len(candidates))
	for _, line := range candidates {
		if line.Official {
			official = append(official, line)
		} else {
			others = append(others, line)
		}
	}
	if len(official) > 0 {
		if best := dongpiandiProbeGroup(ctx, official, 3*time.Second); best != "" {
			return best
		}
	}
	return dongpiandiProbeGroup(ctx, others, 3500*time.Millisecond)
}

// dongpiandiProbeGroup 并发实测一组候选（到点收已完成者）：首分片吞吐最高且
// >=64KB 者胜；无分片数据时取 m3u8 响应最快者；全部失败返回空串。
// 结果经带缓冲 channel 收集（缓冲=len(candidates)，写方永不阻塞）：探针
// goroutine 只写 channel，主流程只读 channel 并按候选下标填进定长槽位切片
// （每个下标只被一个 goroutine 写入一次，填槽无竞争）——超时收口后未完成的
// 探针随 probeCtx 取消自行退出，残余写入落在缓冲里被 GC，读写全程有同步、
// 无竞争。择优按候选下标序（=权重降序）迭代：平局时先位者作基线，确定性
// 与旧串行实现一致，不随 goroutine 到达顺序漂移。
func dongpiandiProbeGroup(ctx context.Context, candidates []dongpiandiLine, budget time.Duration) string {
	if len(candidates) == 0 {
		return ""
	}
	probeCtx, cancel := context.WithTimeout(ctx, budget)
	defer cancel()
	type probeOutcome struct {
		idx int
		res dongpiandiProbeResult
	}
	outcomes := make(chan probeOutcome, len(candidates))
	for i, line := range candidates {
		go func(idx int, address string) { outcomes <- probeOutcome{idx, dongpiandiProbeLine(probeCtx, address)} }(i, line.URL)
	}
	results := make([]dongpiandiProbeResult, len(candidates))
	collected := 0
collect:
	for {
		select {
		case o := <-outcomes:
			results[o.idx] = o.res
			collected++
			if collected == len(candidates) {
				break collect
			}
		case <-probeCtx.Done():
			// 到点收口：把此刻已在缓冲里的完成者一并捞走（之后在途者作废）。
			for {
				select {
				case o := <-outcomes:
					results[o.idx] = o.res
					collected++
				default:
					break collect
				}
			}
		}
	}
	var best dongpiandiProbeResult
	have := false
	for _, r := range results {
		if !r.ready {
			continue
		}
		if !have {
			best, have = r, true
			continue
		}
		bSeg := best.segBytes >= 64*1024
		cSeg := r.segBytes >= 64*1024
		switch {
		case cSeg && !bSeg:
			best = r
		case cSeg == bSeg && cSeg:
			if r.segDur > 0 && (best.segDur <= 0 || float64(r.segBytes)*float64(best.segDur) > float64(best.segBytes)*float64(r.segDur)) {
				best = r
			}
		case !cSeg && !bSeg && r.ttfb < best.ttfb:
			best = r
		}
	}
	if !have {
		return ""
	}
	return best.url
}

// dongpiandiProbeLine 实测单条线路：拉 m3u8 主单（可达性）+ 下载首个分片前 256KB 计吞吐；
// URL 无媒体后缀时若字节流是合法 mp4（ftyp/moov 魔数）则按 mp4 实测。
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
	if err != nil {
		return res
	}
	if strings.Contains(string(body), "#EXTM3U") {
		res.ready = true
		seg := dongpiandiFirstSegment(address, string(body))
		if seg == "" {
			return res
		}
		total, dur := dongpiandiProbeMediaSpeed(ctx, seg, 0)
		res.segBytes, res.segDur = total, dur
		return res
	}
	// 官方票据兑换产物常无媒体后缀（甚至 .image.image）且被 CDN 误标 image/jpeg，
	// 但字节流是正片 mp4（probe3 实测 mvhd 时长与三方直链全片一致），按魔数实测吞吐。
	if dongpiandiLooksLikeMP4(body) {
		total, dur, _ := dongpiandiFetchSpeedCapture(ctx, address, 256*1024)
		if total > 0 {
			res.ready = true
			res.segBytes, res.segDur = total, dur
		}
	}
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

// dongpiandiMediaAlive 轻量验证播放地址当前可用
// （m3u8 内容校验 / mp4 Range 2xx / 无后缀 mp4 按字节流魔数判定）。
func dongpiandiMediaAlive(ctx context.Context, address string) bool {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if strings.Contains(strings.ToLower(address), ".mp4") {
		total, _, _ := dongpiandiFetchSpeedCapture(ctx, address, 16*1024)
		return total > 0
	}
	body, err := dongpiandiFetchLimited(ctx, address, 16*1024)
	if err != nil {
		return false
	}
	if strings.Contains(string(body), "#EXTM3U") {
		return true
	}
	return dongpiandiLooksLikeMP4(body)
}

// dongpiandiLooksLikeMP4 判断响应头字节是否为合法 mp4 容器（ftyp/moov box 魔数）。
// 官方兑换产物 URL 常无媒体后缀且 Content-Type 被误标，只能看字节流。
func dongpiandiLooksLikeMP4(head []byte) bool {
	if len(head) > 512 {
		head = head[:512]
	}
	s := string(head)
	return strings.Contains(s, "ftyp") || strings.Contains(s, "moov")
}

// ---------- 播放期线路缓存 ----------
//
// 详情页逐集解析时已拿到每集完整线路表（含官方兑换线），缓存后在播放期直接
// 复用：既让线路面板（选源）立刻就有全部官方线，又不依赖
// dongpiandiAttachRoutes 的短等待窗——先前只等 1 秒，超时即线路表为空，
// 播放器 routeCount<2 时连选源入口都不出现。

type dongpiandiLineCacheEntry struct {
	lines []dongpiandiLine
	at    time.Time
}

const dongpiandiLineCacheTTL = 20 * time.Minute

var (
	dongpiandiLinesMu    sync.Mutex
	dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
)

// dongpiandiCacheLines 记录某集的完整线路表（key=分集 ID）。
func dongpiandiCacheLines(episodeID string, lines []dongpiandiLine) {
	if episodeID == "" || len(lines) == 0 {
		return
	}
	now := time.Now()
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	if len(dongpiandiLinesCache) >= 256 {
		for key, entry := range dongpiandiLinesCache {
			if now.Sub(entry.at) > dongpiandiLineCacheTTL {
				delete(dongpiandiLinesCache, key)
			}
		}
		if len(dongpiandiLinesCache) >= 256 {
			dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
		}
	}
	dongpiandiLinesCache[episodeID] = dongpiandiLineCacheEntry{lines: lines, at: now}
}

// dongpiandiCachedLines 取某集缓存的线路表（过期或不存在返回 nil）。
func dongpiandiCachedLines(episodeID string) []dongpiandiLine {
	if episodeID == "" {
		return nil
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry, ok := dongpiandiLinesCache[episodeID]
	if !ok || time.Since(entry.at) > dongpiandiLineCacheTTL {
		return nil
	}
	return entry.lines
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

// resolveDongpiandiMedia 播放期解析：
//  1. 现有地址存活 → 直接播放，同时并发预拉线路全表（1s 等待窗，超时不
//     阻塞起播）——「能播但卡」时播放器也有切线入口；
//  2. 地址失效 → 重拉详情找分集 token → resolve 拿全部线路，实测吞吐
//     最优者主选、其余作为 Variants 供播放器切换；
//  3. 全部失败回退原地址走通用路径，由上层报标准错误。
//
// 返回的 Referer 置空：实测资源站 CDN 不校验 Referer，且不带时吞吐明显更高。
func (d *Downloader) resolveDongpiandiMedia(ctx context.Context, task Task) (providerMedia, error) {
	address := strings.TrimSpace(task.Chapter.VideoURL)
	if address != "" && dongpiandiMediaAlive(ctx, address) {
		media, err := d.prepareWebProviderMedia(ctx, providerMedia{URL: address}, "真果·鉴")
		if err != nil {
			return providerMedia{}, err
		}
		// 1.6s：线路表通常已随详情解析缓存命中（近零成本），未命中时给
		// catalog+resolve 留出余量，避免线路面板空白。
		d.dongpiandiAttachRoutes(ctx, &media, task, 1600*time.Millisecond)
		return media, nil
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
						lines, err := dongpiandiResolveLines(ctx, client, ep.Token, true)
						if err == nil && len(lines) > 0 {
							media := dongpiandiLineMedia(lines[0])
							for _, line := range lines[1:] {
								if line.URL == media.URL {
									continue
								}
								media.Variants = append(media.Variants, dongpiandiLineMedia(line))
							}
							if prepared, prepErr := d.prepareWebProviderMedia(ctx, media, "真果·鉴"); prepErr == nil {
								return prepared, nil
							}
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

// dongpiandiAttachRoutes 并发预拉线路全表并合并进 media（最多等待 wait）。
// 预拉失败/超时/单线路都静默：起播不阻塞，用户仍可点线路按钮触发
// fallback 链在原生侧重新解析。
func (d *Downloader) dongpiandiAttachRoutes(ctx context.Context, media *providerMedia, task Task, wait time.Duration) {
	type result struct {
		lines []dongpiandiLine
	}
	done := make(chan result, 1)
	go func() {
		defer func() { _ = recover() }()
		lines := d.dongpiandiRouteLines(ctx, task)
		select {
		case done <- result{lines: lines}:
		default:
		}
	}()
	select {
	case res := <-done:
		d.mergeDongpiandiRoutes(media, res.lines)
	case <-time.After(wait):
	case <-ctx.Done():
	}
}

// dongpiandiRouteLines 从播放任务反推分集 token 并拉取全部线路
// （不实测，仅按站点权重排序——切换列表用）。
func (d *Downloader) dongpiandiRouteLines(ctx context.Context, task Task) []dongpiandiLine {
	_, sourceID, valid := splitProviderDramaID(task.Chapter.ID)
	if !valid {
		return nil
	}
	// 详情页已经解析过这一集的完整线路表时直接复用：播放期零等待，
	// 官方线一条不少（先前这里要重新拉 catalog + resolve，1 秒等待窗
	// 经常超时，线路面板因此消失）。
	if lines := dongpiandiCachedLines(sourceID); len(lines) > 0 {
		return lines
	}
	detailID := dongpiandiDetailIDFromPageURL(strings.TrimSpace(task.Chapter.PageURL))
	if detailID == "" {
		return nil
	}
	client := newDongpiandiClient()
	body, err := client.get(ctx, "/v1/catalog/"+url.PathEscape(detailID), nil)
	if err != nil {
		return nil
	}
	var detail dongpiandiDetail
	if json.Unmarshal(body, &detail) != nil {
		return nil
	}
	for _, ep := range detail.Episodes {
		if ep.ID != sourceID || ep.Token == "" {
			continue
		}
		lines, err := dongpiandiResolveLinesAll(ctx, client, ep.Token)
		if err != nil {
			return nil
		}
		dongpiandiCacheLines(ep.ID, lines)
		return lines
	}
	return nil
}

// mergeDongpiandiRoutes 把预拉回来的线路合并进 media：主播放地址保持
// 第一位，其余线路按序去重附后（URL 相同即同线路）。
func (d *Downloader) mergeDongpiandiRoutes(media *providerMedia, lines []dongpiandiLine) {
	if media == nil || len(lines) == 0 {
		return
	}
	seen := map[string]bool{media.URL: true}
	for _, existing := range media.Variants {
		seen[existing.URL] = true
	}
	if media.Label == "" {
		if label := dongpiandiLineMedia(lines[0]).Label; label != "" {
			media.Label = label
		}
	}
	for _, line := range lines {
		if line.URL == "" || seen[line.URL] {
			// 主播放地址本身就是官方线时，把官方标记补回主媒体，否则线路
			// 面板会把它算成第三方（官方源个数少一条、排序也落后）。
			if line.Official && line.URL == media.URL {
				media.Official = true
			}
			continue
		}
		seen[line.URL] = true
		media.Variants = append(media.Variants, dongpiandiLineMedia(line))
	}
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

// nativeSuggestion 是站内搜索建议（真果·鉴 /v1/suggest）。
// intent=play 且 directPlayable 的建议可直接起播（variantId 即剧目 ID），
// 其余建议点选后按 prompt/label 走普通搜索。
type nativeSuggestion struct {
	Label          string `json:"label"`
	Subtitle       string `json:"subtitle"`
	Intent         string `json:"intent"`
	VariantID      string `json:"variantId"`
	DirectPlayable bool   `json:"directPlayable"`
	Prompt         string `json:"prompt"`
}

type dongpiandiSuggestTarget struct {
	VariantID      string `json:"variant_id"`
	Title          string `json:"title"`
	DirectPlayable bool   `json:"direct_playable"`
}

type dongpiandiSuggestRow struct {
	Label    string                   `json:"label"`
	Subtitle string                   `json:"subtitle"`
	Intent   string                   `json:"intent"`
	Prompt   string                   `json:"prompt"`
	Target   *dongpiandiSuggestTarget `json:"target"`
	Action   struct {
		Type   string `json:"type"`
		Prompt string `json:"prompt"`
	} `json:"action"`
}

type dongpiandiSuggestResp struct {
	Object      string                 `json:"object"`
	Query       string                 `json:"query"`
	Suggestions []dongpiandiSuggestRow `json:"suggestions"`
}

// fetchDongpiandiSuggest 拉取真果·鉴站内搜索建议（/v1/suggest）。
// 返回按站点打分排序的前 limit 条；过滤空 label 与重复项。
func (d *Downloader) fetchDongpiandiSuggest(ctx context.Context, client *dongpiandiClient, query string, limit int) ([]nativeSuggestion, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, errors.New("搜索关键字不能为空")
	}
	if limit <= 0 || limit > 20 {
		limit = 8
	}
	params := url.Values{}
	params.Set("q", query)
	params.Set("limit", strconv.Itoa(limit))
	body, err := client.get(ctx, "/v1/suggest", params)
	if err != nil {
		return nil, err
	}
	var resp dongpiandiSuggestResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, fmt.Errorf("dongpiandi: 解析搜索建议失败: %w", err)
	}
	items := make([]nativeSuggestion, 0, len(resp.Suggestions))
	seen := map[string]bool{}
	for _, row := range resp.Suggestions {
		label := strings.TrimSpace(row.Label)
		if label == "" || len([]rune(label)) > 96 || seen[label] {
			continue
		}
		seen[label] = true
		item := nativeSuggestion{
			Label:    label,
			Subtitle: strings.TrimSpace(row.Subtitle),
			Intent:   strings.TrimSpace(row.Intent),
			Prompt:   strings.TrimSpace(row.Prompt),
		}
		if item.Prompt == "" {
			item.Prompt = strings.TrimSpace(row.Action.Prompt)
		}
		if row.Target != nil {
			item.VariantID = strings.TrimSpace(row.Target.VariantID)
			item.DirectPlayable = row.Target.DirectPlayable && item.VariantID != ""
		}
		items = append(items, item)
		if len(items) == limit {
			break
		}
	}
	return items, nil
}
