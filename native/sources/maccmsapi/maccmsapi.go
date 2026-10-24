package maccmsapi

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"

	"duanjuapp/native/provider"
)

const (
	sourceSep  = "$$$"
	episodeSep = "$"
	playSep    = "#"
)

type vod struct {
	VodID       any             `json:"vod_id"`
	VodName     string          `json:"vod_name"`
	TypeID      any             `json:"type_id"`
	TypeName    string          `json:"type_name"`
	VodPic      string          `json:"vod_pic"`
	VodContent  string          `json:"vod_content"`
	VodRemarks  string          `json:"vod_remarks"`
	VodTime     json.RawMessage `json:"vod_time"`
	VodArea     any             `json:"vod_area"`
	VodYear     any             `json:"vod_year"`
	VodScore    any             `json:"vod_score"`
	VodDuration json.RawMessage `json:"vod_duration"`
	VodPlayFrom string          `json:"vod_play_from"`
	VodPlayURL  string          `json:"vod_play_url"`
}

type flexInt int

func (f *flexInt) UnmarshalJSON(data []byte) error {
	var value any
	if err := json.Unmarshal(data, &value); err != nil {
		return err
	}
	switch n := value.(type) {
	case float64:
		*f = flexInt(int(n))
	case int:
		*f = flexInt(n)
	case string:
		var i int
		if _, err := fmt.Sscanf(n, "%d", &i); err == nil {
			*f = flexInt(i)
		}
	case json.Number:
		if i, err := n.Int64(); err == nil {
			*f = flexInt(int(i))
		}
	}
	return nil
}

type response struct {
	Code      int     `json:"code"`
	Msg       string  `json:"msg"`
	Page      flexInt `json:"page"`
	PageCount flexInt `json:"pagecount"`
	Total     flexInt `json:"total"`
	List      []vod   `json:"list"`
}

type Source struct {
	spec    provider.Spec
	typeID  string
	catalog func(base, typeID string, page int) string
}

func New(spec provider.Spec, typeID string) *Source {
	return &Source{spec: spec, typeID: typeID}
}

func (s *Source) Spec() provider.Spec { return s.spec }

func (s *Source) baseURL(host provider.Host) string {
	if host == nil {
		return s.spec.Base
	}
	if base := host.BaseURL(s.spec.ID); base != "" {
		return base
	}
	return s.spec.Base
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	base := s.baseURL(host)
	if base == "" {
		return nil, errors.New("maccms-api 源未配置")
	}
	seen := map[string]string{}
	for page := 1; page <= 2; page++ {
		raw, err := host.Text(ctx, provider.Request{
			Source:  s.spec.ID,
			Address: catalogURL(base, "", page),
			Referer: base + "/",
		})
		if err != nil {
			break
		}
		var decoded response
		if json.Unmarshal([]byte(raw), &decoded) != nil {
			break
		}
		for _, item := range decoded.List {
			if id := vodIDString(item.TypeID); id != "" {
				if _, dup := seen[id]; !dup {
					seen[id] = strings.TrimSpace(item.TypeName)
				}
			}
		}
		if page >= int(decoded.PageCount) {
			break
		}
	}
	out := make([]provider.CatalogCategory, 0, len(seen)+1)
	out = append(out, provider.CatalogCategory{ID: "", Name: "全部"})
	typeOrder := map[string]int{}
	for i, key := range []string{
		"12", "13", "14", "15", "16", "21", "22", "24",
		"25", "26", "27", "28", "29", "30",
		"5", "6", "7", "8", "9", "10", "11", "20",
	} {
		typeOrder[key] = i
	}
	keys := make([]string, 0, len(seen))
	for k := range seen {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		ai, oki := typeOrder[keys[i]]
		aj, okj := typeOrder[keys[j]]
		if oki && okj {
			return ai < aj
		}
		if oki {
			return true
		}
		if okj {
			return false
		}
		return strings.Compare(seen[keys[i]], seen[keys[j]]) < 0
	})
	for _, k := range keys {
		out = append(out, provider.CatalogCategory{ID: k, Name: seen[k]})
	}
	return out, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.baseURL(host)
	if base == "" {
		return nil, false, errors.New("maccms-api 源未配置")
	}
	address := catalogURL(base, strings.TrimSpace(category), page)
	raw, err := host.Text(ctx, provider.Request{
		Source:  s.spec.ID,
		Address: address,
		Referer: base + "/",
	})
	if err != nil {
		return nil, false, err
	}
	var decoded response
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, false, fmt.Errorf("maccms-api 解析失败: %w", err)
	}
	if decoded.Code != 1 && len(decoded.List) == 0 {
		return nil, false, errors.New("maccms-api 无数据")
	}
	channel := provider.SourceName(s.spec.ID)
	out := make([]provider.Drama, 0, len(decoded.List))
	for _, item := range decoded.List {
		id := vodIDString(item.VodID)
		if id == "" {
			continue
		}
		intro := provider.Truncate(strings.TrimSpace(stripHTMLTags(item.VodContent)), 500)
		// vod_remarks 为「已完结/全集/第N集」类备注，可推断完结状态；推断不出为空。
		remarks := strings.TrimSpace(item.VodRemarks)
		out = append(out, provider.Drama{
			ID:            provider.DramaID(s.spec.ID, id),
			Source:        s.spec.ID,
			SourceID:      id,
			Title:         strings.TrimSpace(item.VodName),
			Name:          strings.TrimSpace(item.VodName),
			Desc:          intro,
			Intro:         intro,
			Cover:         item.VodPic,
			CoverURL:      item.VodPic,
			CategoryName:  item.TypeName,
			Remark:        remarks,
			ReleaseStatus: provider.ReleaseStatus(remarks, 0, 0),
			OnlineDate:    vodTimeOnlineDate(item.VodTime),
			Area:          vodText(item.VodArea),
			Year:          vodText(item.VodYear),
			Score:         vodText(item.VodScore),
			Duration:      vodDurationSeconds(item.VodDuration),
			ChannelName:   channel,
		})
	}
	return out, page < int(decoded.PageCount), nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.baseURL(host)
	if base == "" {
		return provider.Drama{}, nil, errors.New("maccms-api 源未配置")
	}
	address := fmt.Sprintf("%s/api.php/provide/vod/?ac=detail&ids=%s", base, url.QueryEscape(sourceID))
	raw, err := host.Text(ctx, provider.Request{
		Source:  s.spec.ID,
		Address: address,
		Referer: base + "/",
	})
	if err != nil {
		return provider.Drama{}, nil, err
	}
	var decoded response
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return provider.Drama{}, nil, err
	}
	if len(decoded.List) == 0 {
		return provider.Drama{}, nil, errors.New("maccms-api detail 无数据")
	}
	item := decoded.List[0]
	vodID := vodIDString(item.VodID)

	fromList := strings.Split(item.VodPlayFrom, sourceSep)
	urlList := strings.Split(item.VodPlayURL, sourceSep)

	var chapters []provider.Chapter
	type maccmsPlayLine struct {
		direct bool
	}
	lines := make([]maccmsPlayLine, 0, len(urlList))
	for i := 0; i < len(fromList) && i < len(urlList); i++ {
		lines = append(lines, maccmsPlayLine{direct: provider.LooksLikeMedia(firstMediaURL(urlList[i]))})
	}
	hasDirect := false
	for _, line := range lines {
		if line.direct {
			hasDirect = true
			break
		}
	}
	for i, line := range lines {
		if hasDirect && !line.direct {
			continue
		}
		parts := strings.FieldsFunc(urlList[i], func(r rune) bool {
			return r == '$' || r == '#'
		})
		var clean []string
		for _, part := range parts {
			if strings.TrimSpace(part) != "" {
				clean = append(clean, part)
			}
		}
		for j := 0; j+1 < len(clean); j += 2 {
			episodeURL := strings.TrimSpace(clean[j+1])
			if episodeURL == "" {
				continue
			}
			chapter := provider.Chapter{
				ID:             provider.ChapterID(s.spec.ID, vodID, strconv.Itoa(len(chapters)+1)),
				Source:         s.spec.ID,
				Title:          strings.TrimSpace(clean[j]),
				Referer:        base + "/",
				CurrentEpisode: provider.RawEpisode(len(chapters) + 1),
			}
			if line.direct {
				chapter.VideoURL = episodeURL
			} else {
				chapter.PageURL = episodeURL
			}
			chapters = append(chapters, chapter)
		}
	}

	intro := provider.Truncate(strings.TrimSpace(stripHTMLTags(item.VodContent)), 2000)
	drama := provider.Drama{
		ID:           provider.DramaID(s.spec.ID, vodID),
		Source:       s.spec.ID,
		SourceID:     vodID,
		Title:        strings.TrimSpace(item.VodName),
		Name:         strings.TrimSpace(item.VodName),
		Desc:         intro,
		Intro:        intro,
		Cover:        item.VodPic,
		CoverURL:     item.VodPic,
		CategoryName: item.TypeName,
		Remark:       strings.TrimSpace(item.VodRemarks),
		OnlineDate:   vodTimeOnlineDate(item.VodTime),
		Area:         vodText(item.VodArea),
		Year:         vodText(item.VodYear),
		Score:        vodText(item.VodScore),
		Duration:     vodDurationSeconds(item.VodDuration),
		ChannelName:  provider.SourceName(s.spec.ID),
	}
	return drama, chapters, nil
}

// maccms 无热度/播放量数据（采集站 vod_hits 恒空），「上线日期」即源站 vod_time。
// 列表默认顺序就是 vod_time 降序，date 服务端排序与源站顺序天然一致；
// 热度/播放量在 Dart 侧因字段缺失被置灰，正常不可达，万一传入按源站顺序返回。
func (s *Source) CatalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]provider.Drama, bool, error) {
	return s.CatalogPage(ctx, host, page, category, "")
}

// vodTimeOnlineDate 把 maccms vod_time 解析为 2006-01-02。源站两种格式并存：
// unix 秒（数字）或 "2006-01-02 15:04:05" 字符串。非法值返回空串，
// 让 Dart 侧日期排序保持置灰而不是全量假日期。
func vodTimeOnlineDate(raw json.RawMessage) string {
	s := strings.TrimSpace(strings.Trim(string(raw), `"`))
	if s == "" || s == "null" {
		return ""
	}
	if secs, err := strconv.ParseInt(s, 10, 64); err == nil {
		// 小于 1e9 的时间戳（1973 前后）视为无效，避免 4 位年份被误当秒。
		if secs <= 0 || secs < 1000000000 {
			return ""
		}
		return time.Unix(secs, 0).Format("2006-01-02")
	}
	if len(s) >= 10 {
		if _, err := time.Parse("2006-01-02", s[:10]); err == nil {
			return s[:10]
		}
	}
	return ""
}

// vodDurationSeconds 把 maccms vod_duration 解析为秒。采集站常见三种形态：
// 数字秒（2712）、"45:12"（分:秒）、"1:05:30"（时:分:秒）；无法识别返回 0，
// 让 Dart 侧短剧/长剧判定走兜底规则而不是拿到假时长。
func vodDurationSeconds(raw json.RawMessage) float64 {
	s := strings.TrimSpace(strings.Trim(string(raw), `"`))
	if s == "" || s == "null" {
		return 0
	}
	if secs, err := strconv.ParseFloat(s, 64); err == nil {
		return secs
	}
	parts := strings.Split(s, ":")
	if len(parts) < 2 || len(parts) > 3 {
		return 0
	}
	total := 0.0
	for _, part := range parts {
		value, err := strconv.ParseFloat(strings.TrimSpace(part), 64)
		if err != nil || value < 0 {
			return 0
		}
		total = total*60 + value
	}
	return total
}

// vodText 把 vod_area/vod_year/vod_score 等松散类型字段统一为字符串。
// 采集站同一字段字符串与数字并存（年份/评分常见数字），零值返回空串。
func vodText(value any) string {
	switch typed := value.(type) {
	case string:
		return strings.TrimSpace(typed)
	case float64:
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case json.Number:
		return strings.TrimSpace(typed.String())
	}
	return ""
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	base := s.baseURL(host)
	if base == "" {
		return nil, errors.New("maccms-api 源未配置")
	}
	address := fmt.Sprintf("%s/api.php/provide/vod/?ac=list&wd=%s&pg=1", base, url.QueryEscape(query))
	raw, err := host.Text(ctx, provider.Request{
		Source:  s.spec.ID,
		Address: address,
		Referer: base + "/",
	})
	if err != nil {
		return nil, err
	}
	var decoded response
	if err := json.Unmarshal([]byte(raw), &decoded); err != nil {
		return nil, err
	}
	out := make([]provider.Drama, 0, len(decoded.List))
	for _, item := range decoded.List {
		id := vodIDString(item.VodID)
		remarks := strings.TrimSpace(item.VodRemarks)
		out = append(out, provider.Drama{
			ID:            provider.DramaID(s.spec.ID, id),
			Source:        s.spec.ID,
			SourceID:      id,
			Title:         strings.TrimSpace(item.VodName),
			Cover:         item.VodPic,
			Remark:        remarks,
			ReleaseStatus: provider.ReleaseStatus(remarks, 0, 0),
		})
	}
	return out, nil
}

func catalogURL(base, typeID string, page int) string {
	if typeID == "" {
		return fmt.Sprintf("%s/api.php/provide/vod/?ac=list&pg=%d", base, page)
	}
	return fmt.Sprintf("%s/api.php/provide/vod/?ac=list&t=%s&pg=%d", base, typeID, page)
}

func vodIDString(value any) string {
	switch typed := value.(type) {
	case float64:
		return strconv.Itoa(int(typed))
	case int:
		return strconv.Itoa(typed)
	case string:
		return typed
	case json.Number:
		return typed.String()
	default:
		return fmt.Sprintf("%v", value)
	}
}

var stripTags = regexp.MustCompile(`<[^>]+>`)

func stripHTMLTags(s string) string {
	return stripTags.ReplaceAllString(s, "")
}

func firstMediaURL(play string) string {
	parts := strings.FieldsFunc(play, func(r rune) bool {
		return r == '$' || r == '#'
	})
	var index int
	for _, part := range parts {
		if strings.TrimSpace(part) == "" {
			continue
		}
		if index%2 == 1 {
			return strings.TrimSpace(part)
		}
		index++
	}
	return ""
}
