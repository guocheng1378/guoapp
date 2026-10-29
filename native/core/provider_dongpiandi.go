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
	"sync/atomic"
	"time"
)

// dongpiandiOfficialOnly 是用户偏好：只播官方线路（站点第三方直连一律不进
// 线路表）。默认关闭——官方票据只覆盖约六成的剧，默认优先 + 三方兜底才不
// 至于「点开就播不了」；开启后没有官方线的集直接报错提示。
var dongpiandiOfficialOnly atomic.Bool

func setDongpiandiOfficialOnly(value bool) { dongpiandiOfficialOnly.Store(value) }

func dongpiandiOfficialOnlyEnabled() bool { return dongpiandiOfficialOnly.Load() }

// dongpiandiKeepOfficialOnly 在「仅官方线路」开启时丢掉三方直连线。
func dongpiandiKeepOfficialOnly(lines []dongpiandiLine) []dongpiandiLine {
	if !dongpiandiOfficialOnlyEnabled() || len(lines) == 0 {
		return lines
	}
	kept := make([]dongpiandiLine, 0, len(lines))
	for _, line := range lines {
		if line.Official {
			kept = append(kept, line)
		}
	}
	return kept
}

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
	// 各开一次 resolve，若每集再各自放大多个兑换请求，集数多时会瞬间打出
	// 上百个 POST。共享闸门把整部剧的兑换并发钉在 4（真网探针：并发越高
	// 越容易撞 429「请求太频繁」，兑换失败即丢官方线）。
	redeemOnce sync.Once
	redeemSem  chan struct{}
}

// redeemSlots 返回当前 client 的官方票据兑换闸门（懒建、全 client 共享）。
func (c *dongpiandiClient) redeemSlots() chan struct{} {
	c.redeemOnce.Do(func() { c.redeemSem = make(chan struct{}, 4) })
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
	out, _ := dongpiandiRedeemTicketLineErr(ctx, client, line)
	return out
}

// dongpiandiRedeemTicketLineErr 与 dongpiandiRedeemTicketLine 同逻辑，但把
// 失败原因透出：429（站点限流）需要更长退避，其它失败按普通退避重试。
func dongpiandiRedeemTicketLineErr(ctx context.Context, client *dongpiandiClient, line dongpiandiLine) (dongpiandiLine, error) {
	ticket := strings.TrimPrefix(line.URL, "resolve://")
	if ticket == "" || ticket == line.URL {
		return line, nil
	}
	if err := client.ensureAnonymous(ctx); err != nil {
		return line, err
	}
	// view=full 比 compact 只多 ~100 字节，但会带 display_label（"1080P-官方D"）
	// 与 provider_name——清晰度就靠它。
	data, err := client.post(ctx, "/v1/playback/resolve-line?view=full", map[string]string{"ticket": ticket})
	if err != nil {
		return line, err
	}
	var ack struct {
		Line dongpiandiLine `json:"line"`
	}
	if err := json.Unmarshal(data, &ack); err != nil {
		return line, err
	}
	red := ack.Line
	if strings.HasPrefix(red.URL, "resolve://") || strings.TrimSpace(red.URL) == "" {
		return line, errors.New("真果·鉴: 兑换未返回直链")
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
	return red, nil
}

// dongpiandiThrottled 判定错误是否为站点限流（429 / 「请求太频繁」）。
func dongpiandiThrottled(err error) bool {
	if err == nil {
		return false
	}
	text := err.Error()
	return strings.Contains(text, "429") || strings.Contains(text, "太频繁") || strings.Contains(text, "too many")
}

// dongpiandiRedeemTickets 批量并发兑换票据线路（保序回填），只保留兑出真实
// 媒体直链的线路（dongpiandiDirectMediaLine 判定）。
//
// 真网探针：同一集连续解析第 5 次起就开始 429「请求太频繁」，此时官方线会
// 静默变成 0 条——用户看到的就是「官方源有时有有时没有」。所以失败要退避
// 重试，但重试次数按场景给：单集播放期可以等（2 次），详情页几十集批量
// 预兑换不能等（0 次，撞限流立刻熔断），否则累计退避会把详情页拖成分钟级
// 转圈。兑换残缺的结果由调用方决定不写缓存，播放期自然会补。
func dongpiandiRedeemTickets(ctx context.Context, client *dongpiandiClient, tickets []dongpiandiLine) []dongpiandiLine {
	return dongpiandiRedeemTicketsRetry(ctx, client, tickets, 2)
}

func dongpiandiRedeemTicketsRetry(ctx context.Context, client *dongpiandiClient, tickets []dongpiandiLine, retries int) []dongpiandiLine {
	out := make([]dongpiandiLine, len(tickets))
	sem := client.redeemSlots()
	var wg sync.WaitGroup
	for i, t := range tickets {
		wg.Add(1)
		go func(i int, t dongpiandiLine) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			var err error
			out[i], err = dongpiandiRedeemTicketLineErr(ctx, client, t)
			if dongpiandiDirectMediaLine(out[i]) || ctx.Err() != nil {
				return
			}
			// 撞限流（429）：这张票据本次解析里重试也没用（站点按分钟限流），
			// 直接放弃——但绝不能连累同剧其它集，否则一次 429 会把整部剧的
			// 官方线全清零（正是「官方源一个都没有」的观感）。
			if dongpiandiThrottled(err) {
				return
			}
			// 匿名会话建不起来时重试只会再打一次建号请求，直接放弃。
			if client.anonymousFailed() {
				return
			}
			for attempt := 0; attempt < retries; attempt++ {
				wait := time.Duration(300*(attempt+1)) * time.Millisecond
				select {
				case <-time.After(wait):
				case <-ctx.Done():
					return
				}
				out[i], err = dongpiandiRedeemTicketLineErr(ctx, client, t)
				if dongpiandiDirectMediaLine(out[i]) {
					return
				}
				if dongpiandiThrottled(err) || client.anonymousFailed() {
					return
				}
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

	// 集数取 playback_groups[].episode_count（卡片权威字段）；卡片没有播放组
	// 时回落 0——封面由 Dart 侧 episodes<=0 守卫不渲染「共 N 集」，详情页
	// 返回正规 AvailableEpisodeCount 后经 Drama.merge 自愈。playback_count
	// 是总播放量，绝不能当集数。该字段会把彩蛋/陪看算进集数，需与站点文案
	// 交叉校验，见 dongpiandiCardEpisodes。
	groupEpisodes := 0
	for _, group := range card.PlaybackGroups {
		if group.EpisodeCount > groupEpisodes {
			groupEpisodes = group.EpisodeCount
		}
	}
	epCount := dongpiandiCardEpisodes(card.ContentKind, groupEpisodes, card.Remark)
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
		// 目录卡片只有 remarks（「更新至74集」/「全20集」/「高清」），
		// 没有 update_status，靠文案推导即可让剧卡直接带上连载状态。
		ReleaseStatus: dongpiandiReleaseStatus("", false, card.Remark),
	}
}

// dongpiandiCardEpisodes 校正卡片集数：站点把彩蛋/陪看也算进
// playback_groups[].episode_count（《嫁金钗》2026-10-26 真值：35 = 19 正片 +
// 3 陪看 + 13 彩蛋），而 remarks 记的是正片进度「更新至19集」——直接信
// episode_count 就会在封面写「更新至35集」，比站点自己写的多算 16 集附加
// 内容（用户反馈「集数算上了彩蛋，网站却是对的」）。
//
// 短剧批次方向相反：20 集打包成一个播放列表，remarks 记的是批次数
// （「更新至6集」而实际 87 集），这时 episode_count 才是真集数。短剧几乎
// 只有批次形态（真网实测 14~30 倍），而附加内容只多 1~2 倍，用 2 倍分界
// 能同时容纳「一个批次只装 3~4 集」的短剧。
func dongpiandiCardEpisodes(kind string, groupEpisodes int, remark string) int {
	label := dongpiandiCalendarEpisode(remark)
	switch {
	case label <= 0:
		return groupEpisodes
	case groupEpisodes <= 0, label > groupEpisodes:
		// 播放组数据缺失/不全（如 1 条而文案说更新到 70 集）：以站点文案为准。
		return label
	case label == groupEpisodes:
		return groupEpisodes
	}
	if strings.EqualFold(strings.TrimSpace(kind), "short_drama") && groupEpisodes >= label*2 {
		return groupEpisodes // 批次打包：episode_count 是全集，文案记的是批次数
	}
	return label // 附加内容撑大：以站点文案的正片数为准
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

// dongpiandiReleaseStatus 推导连载状态：update_status / is_completed 优先，
// 进度文案兜底。站点真值（2026-10-25 探针）：
//   - 故纵：update_status=unknown、completed=false、progress="更新至74集" → 连载中
//   - 仙帝传承：completed=true、progress="更新至4集 / 共80集"（4 个批次覆盖
//     全集 80 集）→ 已完结，因此 update_status 必须先于进度文案判定
//   - 颜不由心：completed=true、progress="全20集" → 已完结
//   - 电影：completed=true、progress="高清"（画质词，不是进度）→ 已完结
//
// 缺了它，Dart 侧既不知道「连载中」，也只能把集数一律写成「共 N 集」——
// 对连载剧而言 N 是已更新集数，写成「共」等于宣称全集已放出。
// dongpiandiDisplayEpisodes 决定对外展示的集数，按形态与连载状态分流：
//   - 批次型（batch>0，短剧 20 集打包成一个 m3u8）：批次覆盖的最大集号就是
//     全集，available 只是批次数，用 total（调用方已保证 total>=batch）；
//   - 单集型且连载中：available/current 是「已更新集数」（站点原文
//     「更新至74集」），而 total 是全集——写成「更新至 N 集」时必须用已更新
//     数，否则等于宣称还没放出的集数已经能看；
//   - 其余（单集型已完结/状态未知）：用全集 total。
//
// dongpiandiEpisodeIsExtra 判定彩蛋/陪看等非正片条目。
// 首选站点自己的类型字段 episode_track（嫁金钗真值 2026-10-25：17 条正片
// 全是 "main"，3 条陪看 + 11 条彩蛋全是 "extras"）——它是数据源给的，
// 站点改命名也不会失效。
// 只有字段缺失或取值未知时才退回 key/title 形态猜测：special-easter-egg-*
// （第N集彩蛋）、part-*（陪看）、标题含「彩蛋」。这两个前缀与关键字是
// 硬编码的猜测，站点改 key 命名就会漏判，因此仅作兜底。
func dongpiandiEpisodeIsExtra(ep dongpiandiEpisode) bool {
	switch strings.ToLower(strings.TrimSpace(nativeText(ep.EpisodeTrack))) {
	case "main":
		return false
	case "extras":
		return true
	}
	key := strings.ToLower(strings.TrimSpace(ep.Key))
	return strings.HasPrefix(key, "special-") ||
		strings.HasPrefix(key, "part-") ||
		strings.Contains(ep.Title, "彩蛋")
}

// dongpiandiExtraEpisodeCount 统计非正片条目条数。
func dongpiandiExtraEpisodeCount(episodes []dongpiandiEpisode) int {
	extra := 0
	for _, ep := range episodes {
		if dongpiandiEpisodeIsExtra(ep) {
			extra++
		}
	}
	return extra
}

// dongpiandiTrimExtras 从站点全集里扣掉彩蛋/陪看。真值（嫁金钗，2026-10-25）：
// total=31 = 17 正片 + 3 陪看 + 11 彩蛋，站点把附加内容算进了
// total/episode_count——不扣就会在封面写「共31集」，而正片只更新到 17 集。
// 只在 episodes 已含全集（数组条数 >= total）时扣，避免分页剧被算少。
//
// 但不是所有站点数据都把附加内容算进 total：飞狗MOCO 第2季（2026-10-26 真值）
// total=30 已是 30 集正片，数组 31 条 = 30 正片 + 1 彩蛋，扣完变 29 集，
// 反而比正片还少。因此扣完不得低于正片条数。
func dongpiandiTrimExtras(total int, episodes []dongpiandiEpisode) int {
	extra := dongpiandiExtraEpisodeCount(episodes)
	if extra <= 0 || len(episodes) < total || total <= extra {
		return total
	}
	trimmed := total - extra
	if main := len(episodes) - extra; trimmed < main {
		trimmed = main
	}
	if trimmed > total {
		trimmed = total
	}
	return trimmed
}

func dongpiandiDisplayEpisodes(batch, total, epCount int, status string) int {
	if batch > 0 {
		return total
	}
	if status == "ongoing" && epCount > 0 {
		return epCount
	}
	return total
}

func dongpiandiReleaseStatus(status string, completed bool, progress string) string {
	switch strings.ToLower(strings.TrimSpace(status)) {
	case "completed", "finished", "over", "ended":
		return "finished"
	case "ongoing", "serializing", "updating", "airing":
		return "ongoing"
	}
	if completed {
		return "finished"
	}
	if s := releaseStatusFromRemark(progress); s == "ongoing" || s == "finished" {
		return s
	}
	return "unknown"
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
		// 兜底用正片条数（扣掉彩蛋/陪看，否则会把附加内容算成已更新集数）
		epCount = len(episodes) - dongpiandiExtraEpisodeCount(episodes)
	}
	total := detail.TotalEpisodeCount
	if total <= 0 {
		total = epCount
	}
	// 短剧把 20 集打包成一个播放列表（key=range-0001-0020，标题「第1-20集」），
	// 此时 available/current 是批次数不是集数。批次覆盖的最大集号才是真实
	// 总集数——total 缺失或偏小时用它兜底，避免封面/详情显示「共 4 集」。
	batch := dongpiandiBatchTotal(episodes)
	if batch > total {
		total = batch
	}
	total = dongpiandiTrimExtras(total, episodes)
	status := dongpiandiReleaseStatus(detail.UpdateStatus, detail.IsCompleted, detail.EpisodeProgressText)
	shown := dongpiandiDisplayEpisodes(batch, total, epCount, status)

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
		EpisodeCount:  shown,
		TotalEpisode:  shown,
		ReleaseStatus: status,
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
			// 只对首集全量兑换官方票据（其余集留给播放期按需兑换）：
			// 真网实测「一部剧几十集一起全量兑换」会被站点限流（故纵 74 集
			// 只有 12 集兑出官方线、耗时 15s），绝大多数集反而丢掉官方源，
			// 用户看到的就是「官方源一个都没有」。首集兑换保证详情页默认
			// 地址落在官方线，其它集在播放期解析（单集请求，成功率高）。
			full := i == 0
			set, _ := dongpiandiResolveLinesSet(ctx, client, ep.Token, false, full, 0)
			lines := set.Lines
			m3u8 := ""
			if len(lines) > 0 {
				m3u8 = lines[0].URL
				// 三方直连无条件缓存（长效）；官方线只在票据全兑出来时刷新，
				// 一次限流丢线不覆盖上一次的结果。此前残缺时整表都不缓存，
				// 那些集每次播放都要重新 resolve（1~3s）。
				dongpiandiCacheLines(ep.ID, lines, set.complete())
				dongpiandiCacheTickets(ep.ID, set.TicketLines)
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

	// 详情页只兑首集是为了不被站点限流拖慢；其余集的官方票据必须有人补，
	// 否则它们的缓存里只有三方直连（甚至一条都没有），线路面板永远看不到
	// 「官方源」。这里起一个低并发后台任务（详见 dongpiandiBackfillOfficialLines）。
	if len(episodes) > 1 {
		backfillCtx, cancel := context.WithTimeout(
			context.WithoutCancel(ctx),
			dongpiandiBackfillBudget,
		)
		go func() {
			defer cancel()
			// 先让路：用户经常详情页一返回就点播，播放期的 routeLines 现场
			// 兑换优先级更高，别两条链路一起抢站点限流与兑换闸门。
			select {
			case <-time.After(dongpiandiBackfillDelay):
			case <-backfillCtx.Done():
				return
			}
			d.dongpiandiBackfillOfficialLines(backfillCtx, client, detail.ID, episodes)
		}()
	}

	return drama, compact, nil
}

// 详情页后台补兑的取参：集数上限（几十集的剧只补前一段，其余集播放期按需
// 兑换）、启动延迟（让路给用户立刻点播）、单部剧总预算。
const (
	dongpiandiBackfillLimit  = 24
	dongpiandiBackfillDelay  = 2 * time.Second
	dongpiandiBackfillBudget = 90 * time.Second
	dongpiandiBackfillGap    = 400 * time.Millisecond
)

var (
	dongpiandiBackfillMu   sync.Mutex
	dongpiandiBackfillBusy = map[string]struct{}{}
)

// dongpiandiHasFreshOfficial 报告某集缓存里是否已有未过期的官方线。
func dongpiandiHasFreshOfficial(episodeID string) bool {
	lines, officialStale := dongpiandiCachedLinesState(episodeID)
	if officialStale {
		return false
	}
	for _, line := range lines {
		if line.Official {
			return true
		}
	}
	return false
}

// dongpiandiBackfillOfficialLines 低并发补兑官方票据（详情页返回后后台跑）。
//
// 为什么需要它：详情页为了不被站点限流，只对首集做全量兑换（full=true），
// 其余集 full=false——有直连线时干脆不兑票据。真网探针实测后果是「官方源
// 一会儿有一回没」：首集在 6 路并发下那几张票也常常一张都兑不出来，非首集
// 则完全没兑过。这里串行、每集之间留 gap，把成功率找回来并把结果写进
// dongpiandiLinesCache，用户点开任意一集都能直接命中官方线（≈2186 的
// 「详情页全量兑换」体验，但不拖慢详情页首屏）。
//
// 连续两集「有票据但一张都兑不出来」视为站点限流/线路整体不可用，立即收手，
// 避免把限流放大成更长时间的封禁。
func (d *Downloader) dongpiandiBackfillOfficialLines(ctx context.Context, client *dongpiandiClient, detailID string, episodes []dongpiandiEpisode) {
	if client == nil || len(episodes) == 0 {
		return
	}
	if detailID != "" {
		dongpiandiBackfillMu.Lock()
		if _, busy := dongpiandiBackfillBusy[detailID]; busy {
			dongpiandiBackfillMu.Unlock()
			return
		}
		dongpiandiBackfillBusy[detailID] = struct{}{}
		dongpiandiBackfillMu.Unlock()
		defer func() {
			dongpiandiBackfillMu.Lock()
			delete(dongpiandiBackfillBusy, detailID)
			dongpiandiBackfillMu.Unlock()
		}()
	}
	limit := len(episodes)
	if limit > dongpiandiBackfillLimit {
		limit = dongpiandiBackfillLimit
	}
	stalled := 0
	for i := 0; i < limit; i++ {
		if ctx.Err() != nil {
			return
		}
		ep := episodes[i]
		if ep.Token == "" || dongpiandiHasFreshOfficial(ep.ID) {
			continue
		}
		set, err := dongpiandiResolveLinesSet(ctx, client, ep.Token, false, true, 1)
		if len(set.Lines) > 0 {
			dongpiandiCacheLines(ep.ID, set.Lines, set.complete())
			dongpiandiCacheTickets(ep.ID, set.TicketLines)
		}
		if err != nil {
			// resolve 本身失败（网络/站点错误）：换下一集，不在这里重试。
			stalled = 0
		} else if set.Tickets > 0 && set.Redeemed == 0 {
			stalled++
			if stalled >= 2 {
				return
			}
		} else {
			stalled = 0
		}
		select {
		case <-time.After(dongpiandiBackfillGap):
		case <-ctx.Done():
			return
		}
	}
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

// dongpiandiLineSet 是一集的完整线路表解析结果。Tickets/Redeemed 用来判断
// 「站点给了票据但兑换失败」——这种残缺表绝不能写进缓存，否则 20 分钟 TTL
// 内这一集永远没有官方源（真网实测：连续请求触发 429 后官方线变 0 条）。
type dongpiandiLineSet struct {
	Lines []dongpiandiLine
	// TicketLines 是兑换前的票据线（url: resolve://<ticket>）。流代理重签时
	// 用它原地重兑一条新直链，不必再拉 catalog/详情（官方直链是 139 云盘的
	// 预签名地址，X-Amz-Expires=900，15 分钟就过期，重兑是常规路径）。
	TicketLines []dongpiandiLine
	Tickets     int
	Redeemed    int
}

// complete 票据全部兑换成功（或本来就没有票据）才算完整。
func (s dongpiandiLineSet) complete() bool {
	return s.Tickets == 0 || s.Redeemed >= s.Tickets
}

func dongpiandiResolveLinesMode(ctx context.Context, client *dongpiandiClient, epToken string, probe, full bool) ([]dongpiandiLine, error) {
	set, err := dongpiandiResolveLinesSet(ctx, client, epToken, probe, full, 2)
	return set.Lines, err
}

func dongpiandiResolveLinesSet(ctx context.Context, client *dongpiandiClient, epToken string, probe, full bool, retries int) (dongpiandiLineSet, error) {
	body, err := client.get(ctx, "/v1/playback/resolve/"+url.PathEscape(epToken), nil)
	if err != nil {
		return dongpiandiLineSet{}, err
	}
	var resp dongpiandiResolveResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return dongpiandiLineSet{}, fmt.Errorf("dongpiandi: 解析播放响应失败: %w", err)
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
	set := dongpiandiLineSet{Tickets: len(tickets)}
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
			set.TicketLines = redeem
			redeemed := dongpiandiRedeemTicketsRetry(ctx, client, redeem, retries)
			set.Tickets = len(redeem)
			set.Redeemed = len(redeemed)
			lines = append(lines, redeemed...)
		} else {
			// 快路径没兑换，票据仍在：这不算完整表，不能据此缓存。
			set.Tickets = len(tickets)
			set.Redeemed = 0
		}
	}
	sort.SliceStable(lines, func(i, j int) bool {
		return dongpiandiLineScore(lines[i]) > dongpiandiLineScore(lines[j])
	})
	// 「仅官方线路」：排序后过滤。Tickets/Redeemed 不动——兑换完整性仍按
	// 站点下发的票据数判定。健康诊断（bypass）不过滤：诊断要能看到全部线路。
	if dongpiandiOnlyActive(ctx) {
		lines = dongpiandiKeepOfficialOnly(lines)
	}
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
	set.Lines = lines
	return set, nil
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
	return providerMedia{
		URL:      line.URL,
		Label:    label,
		Official: line.Official,
		Quality:  dongpiandiLineQuality(label),
	}
}

// dongpiandiLineQuality 从线路标签里解析清晰度："1080P-官方D" → 1080。
// 站点只用标签表达清晰度，没有独立数值字段（真网探针核实：resolve-line 的
// view=full 也只多出 display_label/provider_name）。
func dongpiandiLineQuality(label string) int {
	for i := 0; i < len(label); i++ {
		if label[i] != 'p' && label[i] != 'P' {
			continue
		}
		j := i - 1
		for j >= 0 && label[j] >= '0' && label[j] <= '9' {
			j--
		}
		digits := label[j+1 : i]
		if len(digits) < 3 || len(digits) > 4 {
			continue
		}
		if value, err := strconv.Atoi(digits); err == nil && value >= 144 && value <= 4320 {
			return value
		}
	}
	return 0
}

// dongpiandiProbeCandidates 取实测候选：官方线优先全部纳入（调用方先测官方
// 组），再用权重最高的三方线补足——官方线权重可能低于三方，不能被「全局
// top N」挤掉。
func dongpiandiProbeCandidates(ctx context.Context, lines []dongpiandiLine) []dongpiandiLine {
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
	official := make([]dongpiandiLine, 0, len(scored))
	others := make([]dongpiandiLine, 0, len(scored))
	for _, l := range scored {
		if l.Official {
			// 官方线全部纳入实测候选（用户定调：官方源一条都不能少）。
			official = append(official, l)
			continue
		}
		others = append(others, l)
	}
	// 「仅官方线路」：三方不进候选，择优只测官方组（健康诊断旁路不受限）。
	if dongpiandiOnlyActive(ctx) {
		return official
	}
	// 三方只需测出最快的一条，多测几条做备选即可。
	if len(others) > 4 {
		others = others[:4]
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

// ---------- 测速结果缓存 ----------
//
// 线路择优/收敛每次起播都要实测，实测本身要 0.3~1.5s；同一集的线路地址在短时间
// 内不会变（官方直链有效期以小时计），所以把实测结论缓存住：重复起播、切集回来
// 都直接命中，既不掉帧也不重复打站点/ CDN。
const dongpiandiSpeedTTL = 10 * time.Minute

type dongpiandiSpeedEntry struct {
	res dongpiandiProbeResult
	at  time.Time
}

var (
	dongpiandiSpeedMu    sync.Mutex
	dongpiandiSpeedCache = map[string]dongpiandiSpeedEntry{}
)

func dongpiandiSpeedGet(address string) (dongpiandiProbeResult, bool) {
	dongpiandiSpeedMu.Lock()
	defer dongpiandiSpeedMu.Unlock()
	entry, ok := dongpiandiSpeedCache[address]
	if !ok || time.Since(entry.at) > dongpiandiSpeedTTL {
		return dongpiandiProbeResult{}, false
	}
	return entry.res, true
}

func dongpiandiSpeedPut(res dongpiandiProbeResult) {
	if res.url == "" || !res.ready {
		return
	}
	dongpiandiSpeedMu.Lock()
	defer dongpiandiSpeedMu.Unlock()
	if len(dongpiandiSpeedCache) >= 256 {
		now := time.Now()
		for key, entry := range dongpiandiSpeedCache {
			if now.Sub(entry.at) > dongpiandiSpeedTTL {
				delete(dongpiandiSpeedCache, key)
			}
		}
		if len(dongpiandiSpeedCache) >= 256 {
			dongpiandiSpeedCache = map[string]dongpiandiSpeedEntry{}
		}
	}
	dongpiandiSpeedCache[res.url] = dongpiandiSpeedEntry{res: res, at: time.Now()}
}

// dongpiandiProbeLineCached 命中缓存直接返回，未命中实测后回填（只缓存可达结果）。
func dongpiandiProbeLineCached(ctx context.Context, address string) dongpiandiProbeResult {
	if res, ok := dongpiandiSpeedGet(address); ok {
		return res
	}
	res := dongpiandiProbeLine(ctx, address)
	dongpiandiSpeedPut(res)
	return res
}

// dongpiandiProbeBest 选择主播放线路：先实测官方线组，任一可达即用官方线
// （用户定调「默认就进官方源」）；官方组整体不可达才降级实测三方线组。
//
// 预算按「起播等待」定：真网实测首分片（128KB）多在 300~800ms 回齐，所以
// 每组给 1.5 秒足够分出快慢；原 3s/3.5s 最坏要等 6.5 秒才起播，是「点开
// 后半天不进播放器」的主因。测不完的线路按不可达处理，全组落空回退权重序
// （官方优先），不会因为收紧预算丢官方源。
func dongpiandiProbeBest(ctx context.Context, lines []dongpiandiLine) string {
	candidates := dongpiandiProbeCandidates(ctx, lines)
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
	const groupBudget = 1500 * time.Millisecond
	if len(official) > 0 {
		if best := dongpiandiProbeGroup(ctx, official, groupBudget); best != "" {
			return best
		}
	}
	return dongpiandiProbeGroup(ctx, others, groupBudget)
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
		go func(idx int, address string) {
			outcomes <- probeOutcome{idx, dongpiandiProbeLineCached(probeCtx, address)}
		}(i, line.URL)
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

// 官方线与三方线分开存、分开过期：
//   - 官方直链是 139 云盘的预签名地址（实测 X-Amz-Expires=900），缓存不能
//     长于 15 分钟，否则后半段必然 403；
//   - 三方直连是资源站的静态 m3u8/mp4 地址，长效，一小时足够覆盖一次刷剧，
//     也让「官方兑换残缺」的集不用每次播放都重新 resolve（1~3 秒）。
type dongpiandiLineCacheEntry struct {
	official   []dongpiandiLine
	officialAt time.Time
	third      []dongpiandiLine
	thirdAt    time.Time
	// tickets 是官方票据（resolve://），重签时原地重兑用；比直链长寿得多。
	tickets   []dongpiandiLine
	ticketsAt time.Time
	// officialTriedAt 记录最近一次「为这一集去站点兑官方票」的时间。缓存里
	// 没有官方线时（详情页并发被限流、或本剧压根没有票据），播放期每次开
	// 线路面板都会想重解析；没有这个冷却就会把 1~3s 的网络等待反复加到用
	// 户头上（真网实测：站点无票的剧每次都会走完整条解析链）。
	officialTriedAt time.Time
}

const (
	// 官方直链是 139 云盘预签名地址（X-Amz-Expires=900，15 分钟）。缓存留
	// 1 分钟余量取 14 分钟：比 12 分钟少一截「补兑好了但已经过期」的窗口。
	dongpiandiOfficialLineTTL = 14 * time.Minute
	dongpiandiThirdLineTTL    = time.Hour
	dongpiandiTicketTTL       = 6 * time.Hour
)

var (
	dongpiandiLinesMu    sync.Mutex
	dongpiandiLinesCache = map[string]dongpiandiLineCacheEntry{}
)

// dongpiandiCacheLines 记录某集的线路表（key=分集 ID）。
// 三方直连无条件刷新；官方线在两种情况下刷新：票据全兑出来（officialComplete），
// 或者这一集还没有任何官方线。前者防「一次 429 把上一次兑好的官方线擦掉」，
// 后者是必须的——真网实测首集 3 张票常只兑成 1 张（另两张站点返回
// playback_line_unavailable 404），若因为「不完整」把这一条也丢掉，该集就
// 永远没有官方源（用户报的「面板里没有官方源」）。
func dongpiandiCacheLines(episodeID string, lines []dongpiandiLine, officialComplete bool) {
	if episodeID == "" || len(lines) == 0 {
		return
	}
	now := time.Now()
	var official, third []dongpiandiLine
	for _, line := range lines {
		if strings.TrimSpace(line.URL) == "" {
			continue
		}
		if line.Official {
			official = append(official, line)
		} else {
			third = append(third, line)
		}
	}
	if len(official) == 0 && len(third) == 0 {
		return
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	if len(dongpiandiLinesCache) >= 256 {
		for key, entry := range dongpiandiLinesCache {
			officialStale := len(entry.official) == 0 ||
				now.Sub(entry.officialAt) > dongpiandiOfficialLineTTL
			thirdStale := len(entry.third) == 0 ||
				now.Sub(entry.thirdAt) > dongpiandiThirdLineTTL
			if officialStale && thirdStale {
				delete(dongpiandiLinesCache, key)
			}
		}
		// 仍满则按「最久未更新」逐出。原实现整表清空，会让所有已解析的集在同一
		// 时刻失效，随后并发重走详情+兑换，形成重解析风暴（官方票据本来就稀缺）。
		for len(dongpiandiLinesCache) >= 256 {
			oldestKey, oldestAt := "", time.Time{}
			for key, entry := range dongpiandiLinesCache {
				at := dongpiandiLineTouchedAt(entry)
				if oldestKey == "" || at.Before(oldestAt) {
					oldestKey, oldestAt = key, at
				}
			}
			if oldestKey == "" {
				break
			}
			delete(dongpiandiLinesCache, oldestKey)
		}
	}
	entry := dongpiandiLinesCache[episodeID]
	if len(official) > 0 && (officialComplete || len(entry.official) == 0) {
		entry.official = official
		entry.officialAt = now
	}
	if len(third) > 0 {
		entry.third = third
		entry.thirdAt = now
	}
	dongpiandiLinesCache[episodeID] = entry
}

// dongpiandiLineTouchedAt 返回该条目最近一次被写入的时间（各时间戳取最大），
// 供缓存满额时挑选最久未更新的条目逐出。
func dongpiandiLineTouchedAt(entry dongpiandiLineCacheEntry) time.Time {
	latest := entry.officialAt
	for _, candidate := range []time.Time{entry.thirdAt, entry.ticketsAt, entry.officialTriedAt} {
		if candidate.After(latest) {
			latest = candidate
		}
	}
	return latest
}

// dongpiandiCacheTickets 记录某集的官方票据（换成直链前的 resolve:// 线），
// 供流代理重签时原地重兑。
func dongpiandiCacheTickets(episodeID string, tickets []dongpiandiLine) {
	if episodeID == "" || len(tickets) == 0 {
		return
	}
	now := time.Now()
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry := dongpiandiLinesCache[episodeID]
	entry.tickets = tickets
	entry.ticketsAt = now
	dongpiandiLinesCache[episodeID] = entry
}

// dongpiandiCachedTicket 取某集缓存的第一张官方票据（过期或不存在返回空）。
func dongpiandiCachedTicket(episodeID string) dongpiandiLine {
	if episodeID == "" {
		return dongpiandiLine{}
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry, ok := dongpiandiLinesCache[episodeID]
	if !ok || len(entry.tickets) == 0 {
		return dongpiandiLine{}
	}
	if time.Since(entry.ticketsAt) > dongpiandiTicketTTL {
		return dongpiandiLine{}
	}
	return entry.tickets[0]
}

// dongpiandiCacheOfficialLine 用重兑出来的新直链刷新缓存里的官方线
// （同 ID 覆盖，找不到就补一条并保持官方在前的顺序）。
func dongpiandiCacheOfficialLine(episodeID string, line dongpiandiLine) {
	if episodeID == "" || strings.TrimSpace(line.URL) == "" {
		return
	}
	line.Official = true
	line.Resolved = true
	now := time.Now()
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry := dongpiandiLinesCache[episodeID]
	replaced := false
	for i, old := range entry.official {
		if old.ID != "" && old.ID == line.ID {
			entry.official[i] = line
			replaced = true
			break
		}
	}
	if !replaced {
		entry.official = append([]dongpiandiLine{line}, entry.official...)
	}
	entry.officialAt = now
	dongpiandiLinesCache[episodeID] = entry
}

// dongpiandiCachedLines 取某集缓存的线路表：官方线在前、三方在后，
// 各自按自己的 TTL 过期；两部分都过期或不存在返回 nil。
func dongpiandiCachedLines(episodeID string) []dongpiandiLine {
	lines, _ := dongpiandiCachedLinesState(episodeID)
	return lines
}

// dongpiandiCachedLinesState 同 dongpiandiCachedLines，并额外报告「官方部分
// 曾经兑出来但已过期」——预签名直链 15 分钟即失效，调用方据此决定是直接
// 用缓存，还是重解析把官方线重兑回来。
func dongpiandiCachedLinesState(episodeID string) ([]dongpiandiLine, bool) {
	if episodeID == "" {
		return nil, false
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry, ok := dongpiandiLinesCache[episodeID]
	if !ok {
		return nil, false
	}
	now := time.Now()
	out := make([]dongpiandiLine, 0, len(entry.official)+len(entry.third))
	officialFresh := len(entry.official) > 0 &&
		now.Sub(entry.officialAt) <= dongpiandiOfficialLineTTL
	if officialFresh {
		out = append(out, entry.official...)
	}
	if len(entry.third) > 0 && now.Sub(entry.thirdAt) <= dongpiandiThirdLineTTL {
		out = append(out, entry.third...)
	}
	officialStale := len(entry.official) > 0 && !officialFresh
	return out, officialStale
}

// dongpiandiOfficialRetryGap 是「没兑出官方线」后重解析同一集的冷却窗。
// 站点这边相当一部分剧压根没有票据（真网探针三家剧里两家无票），不限流
// 的话每次开线路面板都要付一次 catalog+resolve+兑换的完整往返。
const dongpiandiOfficialRetryGap = 60 * time.Second

// dongpiandiMarkOfficialTried 记下这一集刚刚去站点兑过官方票。
// 先记再兑：并发进来（起播预拉 + 用户点面板）不会各跑一轮全链路。
func dongpiandiMarkOfficialTried(episodeID string) {
	if episodeID == "" {
		return
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry := dongpiandiLinesCache[episodeID]
	entry.officialTriedAt = time.Now()
	dongpiandiLinesCache[episodeID] = entry
}

// dongpiandiOfficialTryDue 报告这一集现在是否值得再去兑一次官方票。
func dongpiandiOfficialTryDue(episodeID string) bool {
	if episodeID == "" {
		return true
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry, ok := dongpiandiLinesCache[episodeID]
	if !ok || entry.officialTriedAt.IsZero() {
		return true
	}
	return time.Since(entry.officialTriedAt) > dongpiandiOfficialRetryGap
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
// officialOnlyBypassKey 标记「这次解析是站源健康诊断，不是真实播放」：
// 诊断测的是站源本身是否可达，不该被「仅官方线路」的播放偏好污染——
// 样本剧恰好没有官方线时，健康的站源会被误判成失败（用户看到的正是
// 站源管理页「未返回有效播放地址」）。
type officialOnlyBypassKey struct{}

func officialOnlyBypassed(ctx context.Context) bool {
	bypassed, _ := ctx.Value(officialOnlyBypassKey{}).(bool)
	return bypassed
}

// dongpiandiOnlyActive 报告「仅官方线路」是否对这次解析生效（健康诊断旁路）。
func dongpiandiOnlyActive(ctx context.Context) bool {
	return dongpiandiOfficialOnlyEnabled() && !officialOnlyBypassed(ctx)
}

// dongpiandiMediaFromCachedLines 用缓存尽量凑出可起播的媒体：
// a) 线路表缓存命中 → 测速择优直接起播（官方预签名过期段已被剔除）；
// b) 只有票据缓存（详情预兑留下）且允许再兑 → 直接重兑补官方线，
//
//	免掉重拉详情 + resolve token 两次站点往返。
//
// 凑不出来返回 ok=false，调用方继续走全链解析。
func (d *Downloader) dongpiandiMediaFromCachedLines(ctx context.Context, task Task, sourceID string) (providerMedia, bool) {
	lines := dongpiandiCachedLines(sourceID)
	if dongpiandiOfficialTryDue(sourceID) {
		if tickets := dongpiandiCachedTickets(sourceID); len(tickets) > 0 {
			dongpiandiMarkOfficialTried(sourceID)
			redeemed := dongpiandiRedeemTicketsRetry(ctx, newDongpiandiClient(), tickets, 1)
			if len(redeemed) > 0 {
				dongpiandiCacheLines(sourceID, redeemed, len(redeemed) == len(tickets))
				lines = append(lines, redeemed...)
			}
		}
	}
	if len(lines) == 0 {
		return providerMedia{}, false
	}
	curated := dongpiandiCurateLines(ctx, lines, 1200*time.Millisecond)
	if len(curated) == 0 {
		return providerMedia{}, false
	}
	media := dongpiandiLineMedia(curated[0])
	for _, line := range curated[1:] {
		if line.URL == "" || line.URL == media.URL {
			continue
		}
		media.Variants = append(media.Variants, dongpiandiLineMedia(line))
	}
	if media.URL == "" {
		return providerMedia{}, false
	}
	prepared, err := d.prepareWebProviderMedia(ctx, media, "真果·鉴")
	if err != nil {
		return providerMedia{}, false
	}
	return prepared, true
}

// dongpiandiCachedTickets 取某集缓存的全部官方票据（过期或不存在返回空）。
func dongpiandiCachedTickets(episodeID string) []dongpiandiLine {
	if episodeID == "" {
		return nil
	}
	dongpiandiLinesMu.Lock()
	defer dongpiandiLinesMu.Unlock()
	entry, ok := dongpiandiLinesCache[episodeID]
	if !ok || len(entry.tickets) == 0 {
		return nil
	}
	if time.Since(entry.ticketsAt) > dongpiandiTicketTTL {
		return nil
	}
	return entry.tickets
}

func (d *Downloader) resolveDongpiandiMedia(ctx context.Context, task Task) (providerMedia, error) {
	address := strings.TrimSpace(task.Chapter.VideoURL)
	// -1=没走到解析（详情/网络失败）；0=站点没下发票据；>0=下发了但没兑出来。
	ticketsSeen := -1
	// 「仅官方线路」：章节里带的地址可能是三方直连（旧缓存，或官方线残缺
	// 时详情回退的地址），这种地址不能直接播，往下重解析只取官方线。
	if address != "" && d.dongpiandiOfficialOnlyBlocksAddress(ctx, task, address) {
		address = ""
	}
	if address != "" && dongpiandiMediaAlive(ctx, address) {
		media, err := d.prepareWebProviderMedia(ctx, providerMedia{URL: address}, "真果·鉴")
		if err != nil {
			return providerMedia{}, err
		}
		// 2.4s：详情页只兑换首集票据，其余集要靠这里现场 resolve + 兑换
		// （真网单集约 1.5~2.5s，1.6s 常常刚好超时 → 线路面板没有官方源）。
		// 缓存命中时（首集）这一步几乎零成本，不会拖慢起播。
		d.dongpiandiAttachRoutes(ctx, &media, task, 2400*time.Millisecond)
		return media, nil
	}
	// 缓存优先起播（红果式：能不付全链就不付全链）。这一集解析过一次后，
	// 线路表/票据就进了 dongpiandiLinesCache——直接用缓存起播，省掉「重拉
	// 详情 + resolve token + 全量兑换」的同步往返（真机实测这条全链可拖到
	// 分钟级，是「真果·鉴看不了」的观感主因）。只用于无地址的冷起播：
	// 地址存在但已死时必须强制全链刷新（旧缓存线与死地址同源，再吃缓存
	// 只会把死线再播一遍）。凑不出来再走下面的全链。
	if address == "" {
		if _, sourceID, valid := splitProviderDramaID(task.Chapter.ID); valid {
			if prepared, ok := d.dongpiandiMediaFromCachedLines(ctx, task, sourceID); ok {
				return prepared, nil
			}
		}
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
						set, err := dongpiandiResolveLinesSet(ctx, client, ep.Token, true, true, 2)
						if err == nil {
							// 记下站点这一集下发了多少官方票据：0=站点没给票，
							// >0 但一条没兑出来=站点资源暂不可用（404）。报错
							// 文案据此区分，别让用户把站点现状当成应用故障。
							ticketsSeen = set.Tickets
							if len(set.Lines) > 0 {
								// 重解析出来的线路表同样进缓存：三方长效、官方按
								// 兑换完整性刷新，下次切回这一集不用再走网络。
								dongpiandiCacheLines(ep.ID, set.Lines, set.complete())
								dongpiandiCacheTickets(ep.ID, set.TicketLines)
								// 收敛后再取首位：官方线全部保留且排在前面，
								// 三方只留最快一条，默认主选因此落在官方线。
								lines := dongpiandiCurateLines(ctx, set.Lines, 1200*time.Millisecond)
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
						}
						break
					}
				}
			}
		}
	}
	if address == "" {
		if dongpiandiOnlyActive(ctx) {
			if ticketsSeen == 0 {
				return providerMedia{}, errors.New("真果·鉴：本剧站点未提供官方线路（可在「设置 → 真果·鉴」关闭「仅官方线路」后用第三方线路播放）")
			}
			if ticketsSeen > 0 {
				return providerMedia{}, errors.New("真果·鉴：官方线路暂时不可用（站点返回资源不可用，稍后重试，或关闭「仅官方线路」改用第三方线路）")
			}
			return providerMedia{}, errors.New("真果·鉴：本集没有可用的官方线路（可在「设置 → 真果·鉴」关闭「仅官方线路」后重试）")
		}
		return providerMedia{}, errors.New("真果·鉴未返回有效播放地址，请刷新章节后重试")
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address}, "真果·鉴")
}

// dongpiandiOfficialOnlyBlocksAddress 报告「仅官方线路」下这个地址是否必须
// 跳过：只有缓存里明确登记为三方时才拦。缓存为空（进程刚启动的冷启动续播
// 最常见）不拦——没有证据说它是三方（详情与播放解析都会先写缓存），拦下
// 只会让首播先付一次全链重解析、解析失败就直接播不了；先放行起播，官方线
// 由 attachRoutes 在等待窗内补。健康诊断（bypass）不拦。
func (d *Downloader) dongpiandiOfficialOnlyBlocksAddress(ctx context.Context, task Task, address string) bool {
	if !dongpiandiOnlyActive(ctx) {
		return false
	}
	_, sourceID, valid := splitProviderDramaID(task.Chapter.ID)
	if !valid {
		return false
	}
	cached := dongpiandiCachedLines(sourceID)
	if len(cached) == 0 {
		return false
	}
	for _, line := range cached {
		if strings.TrimSpace(line.URL) == address {
			return !line.Official
		}
	}
	return true
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
		if len(lines) > 0 {
			// 官方全留、三方只留最快一条：实测预算压到 1.2s（测速缓存命中时
			// 基本零等待），别把起播等待窗吃光。
			lines = dongpiandiCurateLines(ctx, lines, 1200*time.Millisecond)
		}
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
	// 只有「缓存里已经有官方线且没过期」才敢零等待复用。真网探针实测
	// （2026-10-25，好莱坞艺术学院）：详情页多路并发常被站点限流，多数集
	// 写进缓存的只有三方直连；此时旧逻辑照样命中缓存返回，官方源就再也不
	// 会出现——用户看到的正是「现在看不到官方源了」。
	cached, officialStale := dongpiandiCachedLinesState(sourceID)
	hasOfficial := false
	for _, line := range cached {
		if line.Official {
			hasOfficial = true
			break
		}
	}
	if len(cached) > 0 && hasOfficial && !officialStale {
		return cached
	}
	// 缺官方线（或官方直链 15 分钟过期）就该去重兑一次：单集解析的成功率
	// 远高于详情页几十集并发。冷却窗防止站点无票的剧被反复重解析。
	if dongpiandiOfficialTryDue(sourceID) {
		dongpiandiMarkOfficialTried(sourceID)
		if lines := d.dongpiandiRouteLinesFresh(ctx, task, sourceID); len(lines) > 0 {
			return lines
		}
	}
	return cached
}

// dongpiandiRenewMedia 供流代理重签回调：只重兑当前集的官方票据（一次 POST，
// 真网约 200ms），不走 catalog/详情/择优全链。官方直链是 139 云盘的预签名
// 地址（X-Amz-Expires=900），15 分钟必过期，重兑是播放中途的常规路径。
func (d *Downloader) dongpiandiRenewMedia(ctx context.Context, task Task) (providerMedia, error) {
	_, sourceID, valid := splitProviderDramaID(task.Chapter.ID)
	if !valid {
		return providerMedia{}, errors.New("真果·鉴：无法定位当前分集")
	}
	ticket := dongpiandiCachedTicket(sourceID)
	if strings.TrimSpace(ticket.URL) == "" {
		// 缓存里没有票据（首次播放 / 票据过期）：走一次常规线路解析补票。
		d.dongpiandiRouteLinesFresh(ctx, task, sourceID)
		ticket = dongpiandiCachedTicket(sourceID)
	}
	if strings.TrimSpace(ticket.URL) == "" {
		return providerMedia{}, errors.New("真果·鉴：本集没有可重兑的官方线路")
	}
	redeemed, err := dongpiandiRedeemTicketLineErr(ctx, newDongpiandiClient(), ticket)
	if err != nil {
		return providerMedia{}, err
	}
	if strings.TrimSpace(redeemed.URL) == "" || strings.HasPrefix(redeemed.URL, "resolve://") {
		return providerMedia{}, errors.New("真果·鉴：官方线路重兑失败")
	}
	dongpiandiCacheOfficialLine(sourceID, redeemed)
	return dongpiandiLineMedia(redeemed), nil
}

// dongpiandiRouteLinesFresh 重拉详情 + resolve 当前集，成功时写缓存。
func (d *Downloader) dongpiandiRouteLinesFresh(ctx context.Context, task Task, sourceID string) []dongpiandiLine {
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
		// 播放期只解析当前这一集，可以耐心重试把官方线补回来。
		set, err := dongpiandiResolveLinesSet(ctx, client, ep.Token, false, true, 2)
		if err != nil {
			return nil
		}
		// 三方直连照缓存；官方线残缺时保留上一次兑好的结果（不覆盖）。
		dongpiandiCacheLines(ep.ID, set.Lines, set.complete())
		dongpiandiCacheTickets(ep.ID, set.TicketLines)
		return set.Lines
	}
	return nil
}

// dongpiandiCurateLines 按用户定调的线路策略收敛线路表：
//   - 官方线一条不少、全部保留（完整展示，默认选中官方）；
//   - 第三方线只留实测最快的那 1 条，其余丢弃——三方线路几十条只是噪音，
//     留着反而让面板又长又乱、还容易误选到卡线；
//   - 完全没有官方线时保留最快的 3 条三方做兜底（只剩 1 条太薄）。
//
// 实测走 dongpiandiProbeGroup（内部命中测速缓存，重复起播近零成本）。
func dongpiandiCurateLines(ctx context.Context, lines []dongpiandiLine, budget time.Duration) []dongpiandiLine {
	if len(lines) == 0 {
		return lines
	}
	official := make([]dongpiandiLine, 0, len(lines))
	others := make([]dongpiandiLine, 0, len(lines))
	for _, line := range lines {
		if line.Official {
			official = append(official, line)
		} else {
			others = append(others, line)
		}
	}
	// 「仅官方线路」：三方一条都不留，省掉后面的测速预算（健康诊断旁路不受限）。
	if dongpiandiOnlyActive(ctx) {
		return official
	}
	if len(others) == 0 {
		return lines
	}
	keep := 1
	if len(official) == 0 {
		keep = 3
	}
	candidates := others
	if len(candidates) > 4 {
		candidates = candidates[:4]
	}
	best := dongpiandiProbeGroup(ctx, candidates, budget)
	kept := make([]dongpiandiLine, 0, keep)
	if best != "" {
		for _, line := range others {
			if line.URL == best {
				kept = append(kept, line)
				break
			}
		}
	}
	// 测速全挂（CDN 抖动/超时）时退回权重最高那条，不至于把三方线全砍光。
	if len(kept) == 0 {
		kept = append(kept, others[0])
	}
	if keep > 1 {
		for _, line := range others {
			if len(kept) >= keep {
				break
			}
			dup := false
			for _, picked := range kept {
				if picked.URL == line.URL {
					dup = true
					break
				}
			}
			if !dup {
				kept = append(kept, line)
			}
		}
	}
	return append(official, kept...)
}

// mergeDongpiandiRoutes 把预拉回来的线路合并进 media：主播放地址保持
// 第一位，其余线路按序去重附后（URL 相同即同线路）。
func (d *Downloader) mergeDongpiandiRoutes(media *providerMedia, lines []dongpiandiLine) {
	lines = dongpiandiKeepOfficialOnly(lines)
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
