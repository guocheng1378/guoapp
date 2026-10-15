// provider_duanju_maccms_api.go - maccms /api.php/provide/vod/ JSON 接口源
package core

import (
	"regexp"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
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

// maccmsAPIResponse /api.php/provide/vod/?ac=list 返回结构
type maccmsAPIResponse struct {
	Code      int            `json:"code"`
	Msg       string         `json:"msg"`
	Page      int            `json:"page"`
	PageCount int            `json:"pagecount"`
	Total     int            `json:"total"`
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

func (d *Downloader) fetchMaccmsAPICatalogPage(ctx context.Context, source string, page int, category string) ([]Drama, bool, error) {
	base := maccmsAPIBaseURL(source)
	if base == "" {
		return nil, false, errors.New("maccms-api 源未配置")
	}
	typeID := strings.TrimSpace(category)
	if typeID == "" {
		typeID = maccmsAPIDramaTypeID(source)
	}
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
	hasMore := page < resp.PageCount
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
	for i := range fromList {
		if i >= len(urlList) {
			break
		}
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
