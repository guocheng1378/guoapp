package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
)

// 黄果 AI 站点 2026-11 起把分类/详情/分集/播放地址/榜单都放在自己的接口里，
// 网页只剩一层带混淆脚本的壳。所有接口统一经 /api/edge/request 转发：
//
//	POST {"method":"GET","path":"/api/videos/12","body":"","content_type":""}
//	→ {"status":1,"msg":"","data":{...}}
//
// 这样只需一个入口域名（镜像可轮换），不再解析网页，也不再依赖
// epPlaySrcs 只下发前两集地址的惰性加载（上游 a93d452 的做法）。
// 目录/详情/搜索/榜单是 GET；按集播放地址是 POST .../episodes/{ep}/playback，
// 信封的 body/content_type 必须留空，服务端会自行构造请求体。

const huangguoAISearchPageSize = 20

func (d *Downloader) huangguoAIAPI(ctx context.Context, path string, out any) error {
	return d.huangguoAIAPICall(ctx, http.MethodGet, path, out)
}

// huangguoAIAPICall 把 method/path 包成 edge 信封转发。
// 播放地址接口是 POST，但 edge 转发要求 body/content_type 保持空串——
// 服务端会自行构造请求体，传 "{}" 会被判「请求无法处理」(400)。
func (d *Downloader) huangguoAIAPICall(ctx context.Context, method, path string, out any) error {
	envelope, err := json.Marshal(map[string]string{
		"method": method, "path": path, "body": "", "content_type": "",
	})
	if err != nil {
		return err
	}
	base := d.providerBaseURL(sourceHuangguoAI)
	body, err := d.fetchProviderRequest(ctx, base+"/api/edge/request", base+"/", envelope)
	if err != nil {
		return err
	}
	var reply struct {
		Status int             `json:"status"`
		Msg    string          `json:"msg"`
		Data   json.RawMessage `json:"data"`
	}
	if err := json.Unmarshal([]byte(body), &reply); err != nil {
		return fmt.Errorf("黄果接口返回格式无效：%w", err)
	}
	if reply.Status != 1 {
		return fmt.Errorf("黄果接口返回失败：%s", firstNonEmpty(reply.Msg, "未知错误"))
	}
	if err := json.Unmarshal(reply.Data, out); err != nil {
		return fmt.Errorf("黄果接口数据格式已变化：%w", err)
	}
	return nil
}

// fetchHuangguoAIAPIDetail 读 /api/videos/{id}，episodes 数组即完整分集表。
// 分集 ID 沿用旧网页解析版的纯数字 key，已有追剧/下载记录不会失效。
func (d *Downloader) fetchHuangguoAIAPIDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	sourceID = strings.Trim(strings.TrimSpace(sourceID), "/")
	sourceID = strings.TrimPrefix(sourceID, "detail/")
	sourceID = strings.TrimPrefix(sourceID, "d/")
	if !rankingSourceID.MatchString(sourceID) {
		return Drama{}, nil, errors.New("无效的黄果剧集 ID")
	}
	var detail map[string]any
	if err := d.huangguoAIAPI(ctx, "/api/videos/"+url.PathEscape(sourceID), &detail); err != nil {
		return Drama{}, nil, err
	}
	base := d.providerBaseURL(sourceHuangguoAI)
	drama, ok := dramaFromAIMap(detail, base+"/", "")
	if !ok || drama.SourceID != sourceID {
		return Drama{}, nil, errors.New("黄果详情与请求剧集不符")
	}
	rows, _ := detail["episodes"].([]any)
	var chapters []Chapter
	for _, value := range rows {
		row, _ := value.(map[string]any)
		episode, err := strconv.Atoi(mapString(row, "ep_num"))
		if err != nil || episode < 1 {
			continue
		}
		chapters = append(chapters, huangguoAIChapter(base, sourceID, episode, mapString(row, "title")))
	}
	if len(rows) == 0 {
		chapters = append(chapters, huangguoAIChapter(base, sourceID, 1, drama.DisplayTitle()))
	}
	sortProviderChapters(chapters)
	return drama, uniqueChapters(chapters), nil
}

func huangguoAIChapter(base, sourceID string, episode int, title string) Chapter {
	pageURL := base + "/video/" + sourceID + "/"
	if episode > 1 {
		pageURL += "ep-" + strconv.Itoa(episode) + "/"
	}
	return Chapter{
		ID:             providerChapterID(sourceHuangguoAI, sourceID, strconv.Itoa(episode)),
		Source:         sourceHuangguoAI,
		Title:          firstNonEmpty(title, fmt.Sprintf("第%d集", episode)),
		PageURL:        pageURL,
		Referer:        base + "/",
		CurrentEpisode: rawEpisode(episode),
	}
}

// fetchHuangguoAIPlayURL 按集号取播放地址。
//
// 2026-11 站点把签名地址迁到了 POST /api/videos/{id}/episodes/{ep}/playback
// 的 data.streams.main：旧的 GET /api/videos/{id}/play?ep=N 仍返回 200，
// 但 video_url 恒为空字符串，继续读它必然报「未返回有效播放地址」，
// 表现就是整个黄果 AI 源「能看列表、点开没画面」。
func (d *Downloader) fetchHuangguoAIPlayURL(ctx context.Context, sourceID string, episode int) (string, error) {
	if !rankingSourceID.MatchString(sourceID) || episode < 1 {
		return "", errors.New("黄果集数无效")
	}
	base := d.providerBaseURL(sourceHuangguoAI) + "/"
	path := fmt.Sprintf("/api/videos/%s/episodes/%d/playback", url.PathEscape(sourceID), episode)
	var playback struct {
		Streams struct {
			Main string `json:"main"`
		} `json:"streams"`
		VideoURL string `json:"video_url"`
	}
	primaryErr := d.huangguoAIAPICall(ctx, http.MethodPost, path, &playback)
	if primaryErr == nil {
		if address := firstNonEmpty(playback.Streams.Main, playback.VideoURL); address != "" {
			return normalizeProviderMediaURL(base, address), nil
		}
	}
	// 站点回滚到旧接口格式时的兜底：GET play 再次下发 video_url。
	var legacy struct {
		VideoURL string `json:"video_url"`
	}
	legacyPath := fmt.Sprintf("/api/videos/%s/play?ep=%d&page_texts=0", url.PathEscape(sourceID), episode)
	if err := d.huangguoAIAPI(ctx, legacyPath, &legacy); err == nil && legacy.VideoURL != "" {
		return normalizeProviderMediaURL(base, legacy.VideoURL), nil
	}
	if primaryErr != nil {
		return "", primaryErr
	}
	return "", errors.New("黄果未返回有效播放地址")
}

func (d *Downloader) searchHuangguoAI(ctx context.Context, page int, query string) ([]Drama, bool, error) {
	query = strings.TrimSpace(query)
	if query == "" || len(query) > 256 {
		return nil, false, errors.New("黄果搜索关键词无效")
	}
	var result struct {
		Items      json.RawMessage `json:"items"`
		Pagination struct {
			Pages int `json:"pages"`
		} `json:"pagination"`
	}
	path := "/api/search?" + url.Values{
		"q": {query}, "page": {strconv.Itoa(page)}, "size": {strconv.Itoa(huangguoAISearchPageSize)},
	}.Encode()
	if err := d.huangguoAIAPI(ctx, path, &result); err != nil {
		return nil, false, err
	}
	items := parseHuangguoAIJSONCards(result.Items, d.providerBaseURL(sourceHuangguoAI)+"/", "")
	return items, page < result.Pagination.Pages, nil
}

// huangguoRankingAPIPath 把本地榜单 board.path 映射到站点 /api/ranks/{type}。
// 真网 2026-11-08 实测：hot/recommend/potential 有效，ranks/hot 与分类名会 404。
func huangguoRankingAPIPath(boardPath string) string {
	switch boardPath {
	case "ranks/hot":
		return "hot"
	case "ai-duanju":
		return "recommend"
	case "ai-manju":
		return "potential"
	default:
		return strings.Trim(boardPath, "/")
	}
}

// parseHuangguoAIAPIRanking 解析 /api/ranks/{type} 的 items。
func parseHuangguoAIAPIRanking(rows []map[string]any, pageURL string) (rankingPage, error) {
	failure := errors.New("黄果未返回有效榜单")
	if len(rows) == 0 || len(rows) > 100 {
		return rankingPage{}, failure
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(rows)), TotalPages: 1}
	seen := map[string]bool{}
	for index, row := range rows {
		// 只在 id 缺失时用 video_id 补位：榜单里 id 有值而 video_id 缺失时，
		// 直接赋值会用 nil 把正确的 id 抹掉。
		if mapString(row, "id") == "" && mapString(row, "video_id") != "" {
			row["id"] = row["video_id"]
		}
		drama, ok := dramaFromAIMap(row, pageURL, mapString(row, "cate_name"))
		if !ok || !rankingSourceID.MatchString(drama.SourceID) || seen[drama.SourceID] {
			return rankingPage{}, failure
		}
		seen[drama.SourceID] = true
		rank, err := strconv.Atoi(mapString(row, "rank"))
		if err != nil || rank < 1 {
			rank = index + 1
		}
		result.Items = append(result.Items, rankingItem{Rank: rank, Drama: drama, Metric: huangguoRankingMetric(row)})
	}
	return result, nil
}

func huangguoRankingMetric(row map[string]any) string {
	label := mapString(row, "metric_label")
	value, err := strconv.ParseFloat(mapString(row, "metric_value"), 64)
	if label == "" || err != nil {
		return ""
	}
	if value >= 10000 {
		return label + " " + strconv.FormatFloat(value/10000, 'f', 1, 64) + "万"
	}
	return label + " " + strconv.FormatFloat(value, 'f', -1, 64)
}
