package core

import (
	"context"
	"encoding/json"
	"fmt"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 追剧周表（/v1/watch-calendar）取数与归一——App 内的「本周追剧」。
// 站点真值（2026-10-25 探针）：title=「追剧周表」，days 固定 7 天
//（week_start_date 起，周一→周日），每天按 content_kind 分组
//（series/anime/variety/movie，各 6 条 preview，more_url 可翻到 20 条），
// 条目 id 就是 variant_id，与目录卡片同构——/v1/catalog/{id} 直接可进详情，
// 因此周表条目是能点开播放的真条目，不是展示用的海报墙。

const dongpiandiCalendarPath = "/v1/watch-calendar"

// dongpiandiCalendarDefaultTTL 是周表的默认缓存时长：站点一天只重算几次
// （snapshot.generated_at 实测约 40 分钟一次），拉不到时间就用 30 分钟。
const dongpiandiCalendarDefaultTTL = 30 * time.Minute

type dongpiandiCalendarResp struct {
	Title      string `json:"title"`
	Categories []struct {
		Key   string `json:"key"`
		Label string `json:"label"`
	} `json:"categories"`
	Days []struct {
		Date   string                             `json:"date"`
		Groups map[string]dongpiandiCalendarGroup `json:"groups"`
	} `json:"days"`
	Snapshot struct {
		GeneratedAt   string `json:"generated_at"`
		WeekStartDate string `json:"week_start_date"`
	} `json:"snapshot"`
}

type dongpiandiCalendarGroup struct {
	MoreURL string                   `json:"more_url"`
	Preview []dongpiandiCalendarItem `json:"preview"`
}

type dongpiandiCalendarItem struct {
	ID                 string `json:"id"`
	VariantID          string `json:"variant_id"`
	Title              string `json:"title"`
	PosterURL          string `json:"poster_url"`
	LatestEpisodeLabel string `json:"latest_episode_label"`
	SeasonLabel        string `json:"season_label"`
	ContentKind        string `json:"content_kind"`
	AvailableAt        string `json:"available_at"`
	HeatScore          any    `json:"heat_score"`
	Year               any    `json:"year"`
	Forecast           struct {
		Label      string `json:"label"`
		Kind       string `json:"kind"`
		Confidence string `json:"confidence"`
		Predicted  bool   `json:"predicted"`
		TargetDate string `json:"target_date"`
	} `json:"forecast"`
}

// dongpiandiCalendarDay 是归一后的一天：日期 + 星期标签 + 当天更新的条目
// （条目已按站点给出的热度顺序排好，本地不重排）。
type dongpiandiCalendarDay struct {
	Date  string
	Label string
	Items []Drama
}

var dongpiandiCalendarCache = struct {
	mu    sync.Mutex
	days  []dongpiandiCalendarDay
	until time.Time
}{}

// cachedDongpiandiCalendar 取追剧周表，未过期直接用缓存；force 时重拉
// （下拉刷新）。请求失败但有旧数据就降级用旧的——周表是锦上添花，
// 拉不到不该让「我的追剧」报错。
func cachedDongpiandiCalendar(ctx context.Context, force bool) ([]dongpiandiCalendarDay, error) {
	dongpiandiCalendarCache.mu.Lock()
	cached, valid := dongpiandiCalendarCache.days, time.Now().Before(dongpiandiCalendarCache.until)
	dongpiandiCalendarCache.mu.Unlock()
	if valid && len(cached) > 0 && !force {
		return cached, nil
	}

	client := newDongpiandiClient()
	body, err := client.get(ctx, dongpiandiCalendarPath, nil)
	if err != nil {
		if len(cached) > 0 {
			return cached, nil
		}
		return nil, err
	}
	var resp dongpiandiCalendarResp
	if err := json.Unmarshal(body, &resp); err != nil {
		if len(cached) > 0 {
			return cached, nil
		}
		return nil, fmt.Errorf("dongpiandi: 解析追剧周表失败: %w", err)
	}
	days := dongpiandiCalendarDays(resp)
	if len(days) == 0 {
		if len(cached) > 0 {
			return cached, nil
		}
		return nil, fmt.Errorf("dongpiandi: 追剧周表没有可用条目")
	}

	dongpiandiCalendarCache.mu.Lock()
	dongpiandiCalendarCache.days = days
	dongpiandiCalendarCache.until = dongpiandiCalendarExpiry(resp.Snapshot.GeneratedAt)
	dongpiandiCalendarCache.mu.Unlock()
	return days, nil
}

func dongpiandiCalendarExpiry(generatedAt string) time.Time {
	if t, err := time.Parse(time.RFC3339, strings.TrimSpace(generatedAt)); err == nil {
		// 站点一天重算几次，生成时间 + 30 分钟足够新鲜。
		return t.Add(dongpiandiCalendarDefaultTTL)
	}
	return time.Now().Add(dongpiandiCalendarDefaultTTL)
}

// dongpiandiCalendarDays 按日期升序整理周表：同一天内的多个分类组按
// 站点顺序拼接，标题/ID 缺失的条目直接丢。
func dongpiandiCalendarDays(resp dongpiandiCalendarResp) []dongpiandiCalendarDay {
	kindLabels := map[string]string{}
	kindOrder := map[string]int{}
	for index, category := range resp.Categories {
		if category.Key == "" {
			continue
		}
		kindLabels[category.Key] = category.Label
		kindOrder[category.Key] = index
	}

	days := make([]dongpiandiCalendarDay, 0, len(resp.Days))
	for _, day := range resp.Days {
		date := strings.TrimSpace(day.Date)
		if date == "" {
			continue
		}
		// map 遍历顺序不稳定：按站点 categories 的顺序排（电视剧→动漫→
		// 综艺→电影），未知分类排最后，保证每次渲染顺序一致。
		groupKeys := make([]string, 0, len(day.Groups))
		for key := range day.Groups {
			groupKeys = append(groupKeys, key)
		}
		sort.Slice(groupKeys, func(i, j int) bool {
			left, leftKnown := kindOrder[groupKeys[i]]
			right, rightKnown := kindOrder[groupKeys[j]]
			if leftKnown != rightKnown {
				return leftKnown
			}
			if left != right {
				return left < right
			}
			return groupKeys[i] < groupKeys[j]
		})

		items := make([]Drama, 0, len(day.Groups)*6)
		seen := map[string]bool{}
		for _, key := range groupKeys {
			for _, item := range day.Groups[key].Preview {
				id := strings.TrimSpace(item.ID)
				if id == "" {
					id = strings.TrimSpace(item.VariantID)
				}
				if id == "" || strings.TrimSpace(item.Title) == "" || seen[id] {
					continue
				}
				seen[id] = true
				items = append(items, dongpiandiDramaFromCalendarItem(item, kindLabels[key]))
			}
		}
		if len(items) == 0 {
			continue
		}
		days = append(days, dongpiandiCalendarDay{
			Date:  date,
			Label: dongpiandiWeekdayLabel(date),
			Items: items,
		})
	}
	sort.SliceStable(days, func(i, j int) bool { return days[i].Date < days[j].Date })
	return days
}

var dongpiandiCalendarDayLayout = "2006-01-02"

func dongpiandiWeekdayLabel(date string) string {
	parsed, err := time.Parse(dongpiandiCalendarDayLayout, strings.TrimSpace(date))
	if err != nil {
		return ""
	}
	switch parsed.Weekday() {
	case time.Monday:
		return "周一"
	case time.Tuesday:
		return "周二"
	case time.Wednesday:
		return "周三"
	case time.Thursday:
		return "周四"
	case time.Friday:
		return "周五"
	case time.Saturday:
		return "周六"
	default:
		return "周日"
	}
}

// dongpiandiCalendarEpisode 从进度文案里取集/期数：只认「第N集/第N期」
// 与「全N集/更新至N集」这些明确形态——综艺的「更新至2026-10-19 第2期
// 加更」靠「第N期」命中，不会误取日期里的年份。
func dongpiandiCalendarEpisode(label string) int {
	for _, pattern := range []*regexp.Regexp{
		regexp.MustCompile(`第\s*(\d{1,4})\s*[集期]`),
		regexp.MustCompile(`(?:全|更新至)\s*(\d{1,4})\s*集`),
	} {
		if match := pattern.FindStringSubmatch(label); match != nil {
			if n, err := strconv.Atoi(match[1]); err == nil && n > 0 {
				return n
			}
		}
	}
	return 0
}

// dongpiandiDramaFromCalendarItem 把周表条目转成剧目：ID 用站点给的
// variant id（与目录卡片同构，详情页与播放链路照常工作）。
func dongpiandiDramaFromCalendarItem(item dongpiandiCalendarItem, kindLabel string) Drama {
	if kindLabel == "" {
		kindLabel = dongpiandiKindLabel(item.ContentKind)
	}
	progress := strings.TrimSpace(item.LatestEpisodeLabel)

	tags := make([]string, 0, 4)
	seen := map[string]bool{}
	add := func(value string) {
		value = strings.TrimSpace(value)
		if value == "" || seen[value] || len([]rune(value)) > 48 {
			return
		}
		seen[value] = true
		tags = append(tags, value)
	}
	add(kindLabel)
	add(item.SeasonLabel)
	if item.Forecast.Label != "" {
		add(item.Forecast.Label)
	}
	add(progress)

	id := strings.TrimSpace(item.ID)
	if id == "" {
		id = strings.TrimSpace(item.VariantID)
	}
	title := truncate(strings.TrimSpace(item.Title), 256)
	poster := strings.TrimSpace(item.PosterURL)
	// 注意：ID 必须带源前缀（与目录卡片一致），否则 Dart 侧认不出所属
	// 站源，点开会报「当前版本不包含此站源」；SourceID 留裸 variant id，
	// 详情请求 /v1/catalog/{id} 用它。
	drama := Drama{
		ID:            providerDramaID(sourceDongpiandi, id),
		Source:        sourceDongpiandi,
		SourceID:      id,
		Title:         title,
		Name:          title,
		Cover:         poster,
		CoverURL:      poster,
		Image:         poster,
		Pic:           poster,
		Poster:        poster,
		Category:      kindLabel,
		CategoryName:  kindLabel,
		ChannelName:   "真果·鉴",
		Remark:        progress,
		Heat:          dongpiandiHeat(item.HeatScore),
		Tags:          tags,
		ReleaseStatus: dongpiandiReleaseStatus("", false, progress),
	}
	if episodes := dongpiandiCalendarEpisode(progress); episodes > 0 {
		drama.EpisodeCount = json.Number(strconv.Itoa(episodes))
		drama.TotalEpisode = drama.EpisodeCount
	}
	return drama
}
