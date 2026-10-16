// provider_duanju_maccms_api.go - maccms /api.php/provide/vod/ JSON 接口源
package core

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
)

// maccmsAPIPlaySource 多源分隔符与集-URL 分隔符
const (
	maccmsAPISourceSep   = "$$$" // vod_play_from / vod_play_url 里多源分隔
	maccmsAPIEpisodeSep  = "$"   // 分集分隔
	maccmsAPIPlaySep     = "#"   // 集名与 URL 分隔
)

// maccmsAPIVod maccms JSON 一条完整 vod
type maccmsAPIVod struct {
	VodID       any    `json:"vod_id"`
	VodName     string `json:"vod_name"`
	TypeID      any    `json:"type_id"`
	TypeName    string `json:"type_name"`
	VodPic      string `json:"vod_pic"`
	VodContent  string `json:"vod_content"`
	VodRemarks  string `json:"vod_remarks"`
	VodPlayFrom string `json:"vod_play_from"`
	VodPlayURL  string `json:"vod_play_url"`
}

func maccmsAPIVodIDString(v any) string {
	switch x := v.(type) {
	case float64:
		return strconv.Itoa(int(x))
	case int:
		return strconv.Itoa(x)
	case string:
		return x
	case json.Number:
		return x.String()
	default:
		return fmt.Sprintf("%v", v)
	}
}

// flexInt 接受 JSON 里的 int 或 string（某些 maccms 源不带 t= 时返回 page/limit 为 string）。
type flexInt int

func (f *flexInt) UnmarshalJSON(data []byte) error {
	var v interface{}
	if err := json.Unmarshal(data, &v); err != nil {
		return err
	}
	switch n := v.(type) {
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

// maccmsAPIResponse /api.php/provide/vod/?ac=list 返回结构
type maccmsAPIResponse struct {
	Code      int            `json:"code"`
	Msg       string         `json:"msg"`
	Page      flexInt        `json:"page"`
	PageCount flexInt        `json:"pagecount"`
	Total     flexInt        `json:"total"`
	List      []maccmsAPIVod `json:"list"`
}

// maccmsAPIBaseURL maccms 提供源的 API 基址（cj.lziapi.com 专门把短剧放在 type_id=46）
func maccmsAPIBaseURL(source string) string {
	switch canonicalProviderSource(source) {
	case sourceYingshigongchang:
		return "http://cj.lziapi.com"
	case source360zy:
		return "https://360zy.com"
	case sourceModu:
		return "https://caiji.moduapi.cc"
	case sourceDytt:
		return "http://caiji.dyttzyapi.com"
	case sourceNiuniu:
		return "http://api.niuniuzy.me"
	case sourceWsyzy:
		return "https://api.wsyzy.net"
	case sourceShandian:
		return "http://sdzyapi.com"
	case sourceHongniu:
		return "https://www.hongniuzy2.com"
	default:
		return ""
	}
}

// maccmsAPIDramaTypeID 返回短剧分类的 type_id
func maccmsAPIDramaTypeID(source string) string {
	switch canonicalProviderSource(source) {
	case sourceYingshigongchang:
		return "46"
	case source360zy:
		return "46" // 360zy 爽文短剧
	case sourceModu:
		return "38" // modu 短剧（还有 42=AI漫剧）
	case sourceDytt:
		return "36" // dytt 短剧
	case sourceNiuniu:
		return "54" // niuniu 爽文短剧（还有 73=擦边短剧）
	case sourceWsyzy:
		return "54" // wsyzy 爽文短剧（还有 73=擦边短剧）
	case sourceShandian:
		return "74" // shandian 擦边短剧（t=54 只有1条）
	case sourceHongniu:
		return "50" // hongniu 擦边短剧（t=30 是空的）
	default:
		return ""
	}
}

// maccmsAPICatalogPage 分类页 URL：?ac=list&t={type_id}&pg={page}
func maccmsAPICatalogPage(base, typeID string, page int) string {
	if typeID == "" {
		return fmt.Sprintf("%s/api.php/provide/vod/?ac=list&pg=%d", base, page)
	}
	return fmt.Sprintf("%s/api.php/provide/vod/?ac=list&t=%s&pg=%d", base, typeID, page)
}

func (d *Downloader) fetchMaccmsAPICategories(ctx context.Context, source string) ([]nativeCategory, error) {
	base := maccmsAPIBaseURL(source)
	if base == "" {
		return nil, errors.New("maccms-api 源未配置")
	}
	seen := map[string]string{}
	for pg := 1; pg <= 2; pg++ {
		apiURL := maccmsAPICatalogPage(base, "", pg)
		raw, err := d.fetchProviderText(ctx, apiURL, base+"/")
		if err != nil {
			break
		}
		var resp maccmsAPIResponse
		if json.Unmarshal([]byte(raw), &resp) != nil {
			break
		}
		for _, v := range resp.List {
			tid := maccmsAPIVodIDString(v.TypeID)
			if tid != "" {
				if _, dup := seen[tid]; !dup {
					seen[tid] = strings.TrimSpace(v.TypeName)
				}
			}
		}
		if pg >= int(resp.PageCount) {
			break
		}
	}
	out := make([]nativeCategory, 0, len(seen)+1)
	out = append(out, nativeCategory{ID: "", Name: "全部"})
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
		out = append(out, nativeCategory{ID: k, Name: seen[k]})
	}
	return out, nil
}

func (d *Downloader) fetchMaccmsAPICatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	base := maccmsAPIBaseURL(source)
	if base == "" {
		return nil, false, errors.New("maccms-api 源未配置")
	}
	typeID := strings.TrimSpace(category)
	apiURL := maccmsAPICatalogPage(base, typeID, page)
	raw, err := d.fetchProviderText(ctx, apiURL, base+"/")
	if err != nil {
		return nil, false, err
	}
	var resp maccmsAPIResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, false, fmt.Errorf("maccms-api 解析失败: %w", err)
	}
	if resp.Code != 1 && len(resp.List) == 0 {
		return nil, false, errors.New("maccms-api 无数据")
	}
	dramaSource := source
	channel := duanjuSourceName(source)
	out := make([]Drama, 0, len(resp.List))
	for _, v := range resp.List {
		id := maccmsAPIVodIDString(v.VodID)
		if id == "" {
			continue
		}
		out = append(out, Drama{
			ID:          providerDramaID(dramaSource, id),
			Source:      dramaSource,
			SourceID:    id,
			Title:       strings.TrimSpace(v.VodName),
			Name:        strings.TrimSpace(v.VodName),
			Desc:        truncate(strings.TrimSpace(stripHTMLTags(v.VodContent)), 500),
			Intro:       truncate(strings.TrimSpace(stripHTMLTags(v.VodContent)), 500),
			Cover:       v.VodPic,
			CoverURL:    v.VodPic,
			CategoryName: v.TypeName,
			Remark:      strings.TrimSpace(v.VodRemarks),
			ChannelName: channel,
		})
	}
	hasMore := page < int(resp.PageCount)
	return out, hasMore, nil
}

// maccmsAPIDetail 详情：?ac=detail&ids={vod_id}
func (d *Downloader) fetchMaccmsAPIDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	base := maccmsAPIBaseURL(source)
	if base == "" {
		return Drama{}, nil, errors.New("maccms-api 源未配置")
	}
	apiURL := fmt.Sprintf("%s/api.php/provide/vod/?ac=detail&ids=%s", base, url.QueryEscape(sourceID))
	raw, err := d.fetchProviderText(ctx, apiURL, base+"/")
	if err != nil {
		return Drama{}, nil, err
	}
	var resp maccmsAPIResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return Drama{}, nil, err
	}
	if len(resp.List) == 0 {
		return Drama{}, nil, errors.New("maccms-api detail 无数据")
	}
	v := resp.List[0]
	vodID := maccmsAPIVodIDString(v.VodID)

	// 解析分集：vod_play_from / vod_play_url 用 $$$ 分多源
	// 每个源内部：集名$URL#集名$URL#...（$ 和 # 交替分隔）
	var chapters []Chapter
	fromList := strings.Split(v.VodPlayFrom, maccmsAPISourceSep)
	urlList := strings.Split(v.VodPlayURL, maccmsAPISourceSep)

	// 构建源索引，按是否包含媒体直链排序（直链 m3u8/mp4/flv 优先于 share-ticket/HTML 线路）
	type srcIdx struct {
		pos   int
		score int
	}
	var srcOrder []srcIdx
	for i := 0; i < len(fromList) && i < len(urlList); i++ {
		firstURL := firstMediaURLInSource(urlList[i])
		score := 0
		if duanjuLooksLikeMedia(firstURL) {
			score = 10
		}
		srcOrder = append(srcOrder, srcIdx{pos: i, score: score})
	}
	sort.SliceStable(srcOrder, func(a, b int) bool {
		return srcOrder[a].score > srcOrder[b].score
	})

	for _, entry := range srcOrder {
		i := entry.pos
		// 用 $ 和 # 都当分隔符来切，得到 [集名1, URL1, 集名2, URL2, ...]
		playStr := urlList[i]
		parts := strings.FieldsFunc(playStr, func(r rune) bool {
			return r == '$' || r == '#'
		})
		// 跳过空元素
		var clean []string
		for _, p := range parts {
			if strings.TrimSpace(p) != "" {
				clean = append(clean, p)
			}
		}
		// 两两配对：[集名, URL, 集名, URL, ...]
		for j := 0; j+1 < len(clean); j += 2 {
			epName := strings.TrimSpace(clean[j])
			epURL := strings.TrimSpace(clean[j+1])
			if epURL == "" {
				continue
			}
			chapters = append(chapters, Chapter{
				ID:             providerChapterID(source, vodID, strconv.Itoa(len(chapters)+1)),
				Source:         source,
				Title:          epName,
				VideoURL:       epURL,
				Referer:        base + "/",
				CurrentEpisode: rawEpisode(len(chapters) + 1),
			})
		}
	}

	drama := Drama{
		ID:          providerDramaID(source, vodID),
		Source:      source,
		SourceID:    vodID,
		Title:       strings.TrimSpace(v.VodName),
		Name:        strings.TrimSpace(v.VodName),
		Desc:        truncate(strings.TrimSpace(stripHTMLTags(v.VodContent)), 2000),
		Intro:       truncate(strings.TrimSpace(stripHTMLTags(v.VodContent)), 2000),
		Cover:       v.VodPic,
		CoverURL:    v.VodPic,
		CategoryName: v.TypeName,
		Remark:      strings.TrimSpace(v.VodRemarks),
		ChannelName: duanjuSourceName(source),
	}
	return drama, chapters, nil
}

// searchMaccmsAPI 搜索：?ac=list&wd={keyword}
func (d *Downloader) searchMaccmsAPI(ctx context.Context, source, query string) ([]Drama, error) {
	base := maccmsAPIBaseURL(source)
	if base == "" {
		return nil, errors.New("maccms-api 源未配置")
	}
	apiURL := fmt.Sprintf("%s/api.php/provide/vod/?ac=list&wd=%s&pg=1", base, url.QueryEscape(query))
	raw, err := d.fetchProviderText(ctx, apiURL, base+"/")
	if err != nil {
		return nil, err
	}
	var resp maccmsAPIResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, err
	}
	out := make([]Drama, 0, len(resp.List))
	for _, v := range resp.List {
		id := maccmsAPIVodIDString(v.VodID)
		out = append(out, Drama{
			ID:       providerDramaID(source, id),
			Source:   source,
			SourceID: id,
			Title:    strings.TrimSpace(v.VodName),
			Cover:    v.VodPic,
		})
	}
	return out, nil
}

var stripHTMLTagsRe = regexp.MustCompile(`<[^>]+>`)

func stripHTMLTags(s string) string {
	return stripHTMLTagsRe.ReplaceAllString(s, "")
}

// firstMediaURLInSource 从一个源的 play_url 串里提取第一个 URL（跳过集名取奇数位）
func firstMediaURLInSource(playStr string) string {
	parts := strings.FieldsFunc(playStr, func(r rune) bool {
		return r == '$' || r == '#'
	})
	var idx int
	for _, p := range parts {
		if strings.TrimSpace(p) == "" {
			continue
		}
		if idx%2 == 1 {
			return strings.TrimSpace(p)
		}
		idx++
	}
	return ""
}
