package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 远端主页（/v1/feed/home）取数与归一。站点把首页自己拆成若干 section，
// 每个 section 自带标题、副标题、类型、优先级与「查看更多」的取数参数——
// App 不再自己编排板块顺序，也不内置任何板块清单，站点给多少就显示多少、
// 站点改名/增删立即生效（真值 2026-10-25：8 个区块，见下方注释）。
//
// 区块真值：
//   feed_sec_everyone_watching  大家都在看  trend      priority=100  browse=sort:trending,window:day
//   feed_sec_hot_tv_korean      韩剧在追    collection priority=90   browse=hot_list_key:tv_korean
//   feed_sec_hot_tv_japanese    日剧上新    collection priority=86   browse=hot_list_key:tv_japanese
//   feed_sec_hot_tv_american    美剧续看    collection priority=76   browse=hot_list_key:tv_american
//   feed_sec_hot_tv_domestic    国产新剧    collection priority=88   browse=hot_list_key:tv_domestic
//   feed_sec_hot_movie_high_score 高分电影  collection priority=84   browse=hot_list_key:movie_high_score
//   feed_sec_hot_movie_hot      电影热播    collection priority=82   browse=hot_list_key:movie_hot
//   feed_sec_hot_movie_nowplaying 院线热映  collection priority=81   browse=hot_list_key:movie_nowplaying,include_unavailable:true

const dongpiandiHomePath = "/v1/feed/home"

// dongpiandiHomeDefaultTTL 是主页快照的默认有效期：站点每次响应都带
// expires_at（实测 generated_at→expires_at 间隔 10 分钟），解析失败时用这个值。
const dongpiandiHomeDefaultTTL = 10 * time.Minute

type dongpiandiHomeFeed struct {
	Object      string `json:"object"`
	GeneratedAt string `json:"generated_at"`
	ExpiresAt   string `json:"expires_at"`
	Period      string `json:"period"`
	NextCursor  string `json:"next_cursor"`
	Strategy    string `json:"strategy"`
	Meta        struct {
		TotalSections    int    `json:"total_sections"`
		ReturnedSections int    `json:"returned_sections"`
		CardsPerSection  int    `json:"cards_per_section"`
		Mode             string `json:"mode"`
	} `json:"meta"`
	Sections []dongpiandiHomeSection `json:"sections"`
}

// dongpiandiHomeSection 是站点下发的一个首页区块：类型、优先级、卡片与
// 「查看更多」的请求描述都在里面，App 只负责照做。
type dongpiandiHomeSection struct {
	ID       string                  `json:"id"`
	Title    string                  `json:"title"`
	Subtitle string                  `json:"subtitle"`
	Type     string                  `json:"type"`
	Role     string                  `json:"role"`
	Priority int                     `json:"priority"`
	Reason   string                  `json:"reason"`
	Cards    []dongpiandiCatalogCard `json:"cards"`
	Browse   dongpiandiBrowseRequest `json:"browse"`
}

// dongpiandiBrowseRequest 是「查看更多 / 查看完整榜单」的请求描述。
// Params 是站点给的原始参数（hot_list_key、sort、window 等），原样透传即可，
// 只有 page/limit 由本地按翻页需要覆盖。
type dongpiandiBrowseRequest struct {
	Label  string         `json:"label"`
	Limit  int            `json:"limit"`
	Method string         `json:"method"`
	Page   int            `json:"page"`
	Path   string         `json:"path"`
	Type   string         `json:"type"`
	Params map[string]any `json:"params"`
}

var dongpiandiHomeCache = struct {
	mu       sync.Mutex
	sections []dongpiandiHomeSection
	until    time.Time
}{}

// cachedDongpiandiHome 取主页区块，命中缓存（且未过期）直接用。
// force=true 时跳过缓存重新拉——下拉刷新与「板块不存在」的重试用它。
func cachedDongpiandiHome(ctx context.Context, force bool) ([]dongpiandiHomeSection, error) {
	dongpiandiHomeCache.mu.Lock()
	cached, valid := dongpiandiHomeCache.sections, time.Now().Before(dongpiandiHomeCache.until)
	dongpiandiHomeCache.mu.Unlock()
	if valid && len(cached) > 0 && !force {
		return cached, nil
	}

	client := newDongpiandiClient()
	body, err := client.get(ctx, dongpiandiHomePath, nil)
	if err != nil {
		if len(cached) > 0 {
			// 请求失败但手里还有旧快照：先把旧数据用起来，
			// 保证首页不至于空白（降级而非报错）。
			return cached, nil
		}
		return nil, err
	}
	var feed dongpiandiHomeFeed
	if err := json.Unmarshal(body, &feed); err != nil {
		return nil, fmt.Errorf("dongpiandi: 解析主页失败: %w", err)
	}
	sections := dongpiandiHomeSections(feed)
	if len(sections) == 0 {
		if len(cached) > 0 {
			return cached, nil
		}
		return nil, fmt.Errorf("dongpiandi: 主页没有可用板块")
	}

	dongpiandiHomeCache.mu.Lock()
	dongpiandiHomeCache.sections = sections
	dongpiandiHomeCache.until = dongpiandiHomeExpiry(feed.ExpiresAt)
	dongpiandiHomeCache.mu.Unlock()
	return sections, nil
}

// dongpiandiHomeSections 过滤空区块并按站点 priority 降序排。
// 顺序完全由站点决定，本地不重排。
func dongpiandiHomeSections(feed dongpiandiHomeFeed) []dongpiandiHomeSection {
	sections := make([]dongpiandiHomeSection, 0, len(feed.Sections))
	for _, section := range feed.Sections {
		if strings.TrimSpace(section.Title) == "" || len(section.Cards) == 0 {
			continue
		}
		sections = append(sections, section)
	}
	sort.SliceStable(sections, func(i, j int) bool {
		return sections[i].Priority > sections[j].Priority
	})
	return sections
}

func dongpiandiHomeExpiry(expiresAt string) time.Time {
	if t, err := time.Parse(time.RFC3339, strings.TrimSpace(expiresAt)); err == nil {
		return t
	}
	return time.Now().Add(dongpiandiHomeDefaultTTL)
}

func findDongpiandiHomeSection(sections []dongpiandiHomeSection, id string) *dongpiandiHomeSection {
	for index := range sections {
		if sections[index].ID == id {
			return &sections[index]
		}
	}
	return nil
}

// fetchDongpiandiSectionPage 拉某个区块的完整列表：直接用站点在 browse 里
// 给的参数（hot_list_key / sort / window / include_unavailable），只按本地
// 翻页需要覆盖 page。板块 id 不在缓存里（站点改版增删了区块）时强刷一次主页。
func (d *Downloader) fetchDongpiandiSectionPage(ctx context.Context, sectionID string, page int) ([]Drama, bool, error) {
	sectionID = strings.TrimSpace(sectionID)
	if sectionID == "" {
		return nil, false, fmt.Errorf("板块标识无效")
	}
	sections, err := cachedDongpiandiHome(ctx, false)
	if err != nil {
		return nil, false, err
	}
	target := findDongpiandiHomeSection(sections, sectionID)
	if target == nil {
		// 站点区块变了：拉一次新的主页再找一次，仍找不到才报错。
		if sections, err = cachedDongpiandiHome(ctx, true); err != nil {
			return nil, false, err
		}
		if target = findDongpiandiHomeSection(sections, sectionID); target == nil {
			return nil, false, fmt.Errorf("该板块已不存在，返回后可查看新的板块")
		}
	}

	q := dongpiandiBrowseQuery(target.Browse)
	page = max(1, page)
	q.Set("page", strconv.Itoa(page))
	limit := target.Browse.Limit
	if limit <= 0 {
		limit = 20
	}
	q.Set("limit", strconv.Itoa(limit))

	path := strings.TrimSpace(target.Browse.Path)
	if !strings.HasPrefix(path, "/v1/") {
		path = "/v1/browse/catalog"
	}
	// 站点下发的 browse 都是 GET（参数走 query）；万一以后改了请求方法，
	// 宁可明确报错也不要用错误的方式发一个错的请求。
	if method := strings.ToUpper(strings.TrimSpace(target.Browse.Method)); method != "" && method != http.MethodGet {
		return nil, false, fmt.Errorf("该板块的请求方式暂不支持")
	}

	client := newDongpiandiClient()
	body, err := client.get(ctx, path, q)
	if err != nil {
		return nil, false, err
	}
	var resp dongpiandiCatalogResp
	if err := json.Unmarshal(body, &resp); err != nil {
		return nil, false, fmt.Errorf("dongpiandi: 解析板块列表失败: %w", err)
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

// dongpiandiBrowseQuery 把站点给的参数原样塞进 query（标量才能进 URL，
// 数组/对象直接丢——目前站点只下发标量）。
func dongpiandiBrowseQuery(req dongpiandiBrowseRequest) url.Values {
	q := url.Values{}
	for key, value := range req.Params {
		switch typed := value.(type) {
		case string:
			if strings.TrimSpace(typed) != "" {
				q.Set(key, typed)
			}
		case float64:
			q.Set(key, strconv.FormatFloat(typed, 'f', -1, 64))
		case bool:
			q.Set(key, strconv.FormatBool(typed))
		}
	}
	return q
}
