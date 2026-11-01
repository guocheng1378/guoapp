package provider

import (
	"encoding/json"
	"html"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

// sanitizeHTMLTags 匹配任何 HTML 标签，用于剥掉简介里的 <p>/<br> 等片段。
var sanitizeHTMLTags = regexp.MustCompile(`<[^>]+>`)

// SanitizeText 清洗简介/演员/标签等文本：剥 HTML 标签 + 解 HTML 实体
// （&nbsp;/&amp;/&#39; 等）+ 不换行空格 U+00A0 归一 + 折叠多余空白。
// 各源简介偶带站点 HTML 片段或直接塞实体，不清洗会在播放器里显示成
// 「&nbsp;, &nbsp;」之类的乱码（真机实拍多源复现，含黄果类）。
func SanitizeText(s string) string {
	if s == "" {
		return s
	}
	s = sanitizeHTMLTags.ReplaceAllString(s, "")
	s = html.UnescapeString(s)
	s = strings.ReplaceAll(s, "\u00a0", " ")
	s = strings.Join(strings.Fields(s), " ")
	return s
}

type SortMetadataState struct {
	VIPChecked   bool      `json:"vipChecked,omitempty"`
	Version      int       `json:"version"`
	CheckedAt    time.Time `json:"checkedAt"`
	Pending      bool      `json:"pending,omitempty"`
	CoverChecked bool      `json:"coverChecked,omitempty"`
}

type CatalogCategory struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type Drama struct {
	VIP               *bool              `json:"vip,omitempty"`
	ID                string             `json:"id"`
	Source            string             `json:"source,omitempty"`
	SourceID          string             `json:"sourceId,omitempty"`
	Title             string             `json:"title"`
	Name              string             `json:"name"`
	Desc              string             `json:"desc"`
	Intro             string             `json:"intro"`
	Cover             any                `json:"cover"`
	CoverURL          any                `json:"coverUrl"`
	CoverURLSnake     any                `json:"cover_url"`
	Image             any                `json:"image"`
	ImageURL          any                `json:"imageUrl"`
	ImageURLSnake     any                `json:"image_url"`
	Img               any                `json:"img"`
	Pic               any                `json:"pic"`
	Picture           any                `json:"picture"`
	Poster            any                `json:"poster"`
	Thumb             any                `json:"thumb"`
	Thumbnail         any                `json:"thumbnail"`
	TotalEpisode      any                `json:"totalEpisode"`
	TotalEpisodeSnake any                `json:"total_episode"`
	ChapterCount      any                `json:"chapterCount"`
	ChapterCountSnake any                `json:"chapter_count"`
	EpisodeCount      any                `json:"episodeCount"`
	EpisodeCountSnake any                `json:"episode_count"`
	Total             any                `json:"total"`
	Episodes          any                `json:"episodes"`
	Duration          any                `json:"duration"`
	ChannelName       string             `json:"channelName"`
	Category          string             `json:"category"`
	CategoryName      string             `json:"categoryName"`
	CategoryNameSnake string             `json:"category_name"`
	TypeName          string             `json:"typeName"`
	TypeNameSnake     string             `json:"type_name"`
	SortName          string             `json:"sortName"`
	SortNameSnake     string             `json:"sort_name"`
	Remark            string             `json:"remark,omitempty"`
	Score             string             `json:"score,omitempty"`
	Views             string             `json:"views,omitempty"`
	Heat              string             `json:"heat,omitempty"`
	OnlineDate        string             `json:"onlineDate,omitempty"`
	Area              string             `json:"area,omitempty"`
	Year              string             `json:"year,omitempty"`
	Tags              []string           `json:"tags,omitempty"`
	Actors            []string           `json:"actors,omitempty"`
	ReleaseStatus     string             `json:"releaseStatus,omitempty"`
	SortMetadata      *SortMetadataState `json:"sortMetadata,omitempty"`
}

// UnmarshalJSON 兼容 actors 字段的两种形态：
// 旧接口返回字符串数组（["张三","李四"]），站点升级后部分源改为对象数组
// （[{"name":"张三","id":"..."}]）。对象数组只取名字字段，避免整个 listResponse
// 因无法把对象解析进 []string 而整体失败（表现为「json: cannot unmarshal object into ...actors.0」）。
func (d *Drama) UnmarshalJSON(data []byte) error {
	type alias Drama
	aux := &struct {
		Actors json.RawMessage `json:"actors"`
		*alias
	}{alias: (*alias)(d)}
	if err := json.Unmarshal(data, aux); err != nil {
		return err
	}
	if len(aux.Actors) > 0 && strings.TrimSpace(string(aux.Actors)) != "null" {
		var strs []string
		if err := json.Unmarshal(aux.Actors, &strs); err == nil {
			d.Actors = strs
		} else {
			var objs []map[string]any
			if err := json.Unmarshal(aux.Actors, &objs); err == nil {
				for _, o := range objs {
					if name, ok := firstStringField(o, "name", "actor", "actorName", "nickName", "nickname", "title"); ok && name != "" {
						d.Actors = append(d.Actors, name)
					}
				}
			}
		}
	}
	return nil
}

func firstStringField(m map[string]any, keys ...string) (string, bool) {
	for _, k := range keys {
		if v, ok := m[k]; ok {
			if s, ok := v.(string); ok && s != "" {
				return s, true
			}
		}
	}
	// 兜底：已知 key 都未命中时，取对象里第一个非空字符串值（最坏情况落到 id 之类，
	// 但保证不空、不崩——总比整条目录因解析失败而消失好）。
	for _, v := range m {
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func (d Drama) DisplayTitle() string {
	if strings.TrimSpace(d.Title) != "" {
		return d.Title
	}
	if strings.TrimSpace(d.Name) != "" {
		return d.Name
	}
	return "短剧"
}

type Chapter struct {
	VIP            bool            `json:"vip,omitempty"`
	ID             string          `json:"id"`
	Source         string          `json:"source,omitempty"`
	Title          string          `json:"title"`
	VideoURL       string          `json:"videoUrl"`
	CurrentEpisode json.RawMessage `json:"currentEpisode"`
	MediaSize      int64           `json:"mediaSize"`
	PageURL        string          `json:"pageUrl,omitempty"`
	Referer        string          `json:"referer,omitempty"`
	// Vertical：红果详情接口下发的分集横竖屏标记（nil=未提供）。
	// 竖屏短剧判定优先取官方标记，缺失时回退客户端时长启发式。
	Vertical *bool `json:"vertical,omitempty"`
}

func (c Chapter) EpisodeString(fallback int) string {
	if len(c.CurrentEpisode) > 0 && string(c.CurrentEpisode) != "null" {
		var s string
		if err := json.Unmarshal(c.CurrentEpisode, &s); err == nil && strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
		var n int
		if err := json.Unmarshal(c.CurrentEpisode, &n); err == nil && n > 0 {
			return strconv.Itoa(n)
		}
		var f float64
		if err := json.Unmarshal(c.CurrentEpisode, &f); err == nil && f > 0 {
			return strconv.Itoa(int(f))
		}
	}
	return strconv.Itoa(fallback)
}

func NewChapter(source, sourceID string, number int, title, videoURL, pageURL, referer string) Chapter {
	if number <= 0 {
		number = 1
	}
	if strings.TrimSpace(title) == "" {
		title = "第" + strconv.Itoa(number) + "集"
	}
	return Chapter{
		ID:             ChapterID(source, sourceID, strconv.Itoa(number)),
		Source:         source,
		Title:          Truncate(title, 256),
		VideoURL:       videoURL,
		PageURL:        pageURL,
		Referer:        referer,
		CurrentEpisode: RawEpisode(number),
	}
}

func SortChapters(chapters []Chapter) {
	sort.SliceStable(chapters, func(i, j int) bool {
		left, _ := strconv.Atoi(chapters[i].EpisodeString(i + 1))
		right, _ := strconv.Atoi(chapters[j].EpisodeString(j + 1))
		return left < right
	})
}

type Task struct {
	DramaID         string  `json:"dramaId"`
	DramaTitle      string  `json:"dramaTitle"`
	Chapter         Chapter `json:"chapter"`
	Index           int     `json:"index"`
	Total           int     `json:"total"`
	OutPath         string  `json:"outPath"`
	ReleaseStatus   string  `json:"releaseStatus,omitempty"`
	DownloadQuality int     `json:"downloadQuality,omitempty"`
}
