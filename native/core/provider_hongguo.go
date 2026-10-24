package core

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"slices"
	"sort"
	"strconv"
	"strings"
	"time"
)

const hongguoBaseURL = "https://hongguoduanju.com"

func (d *Downloader) fetchHongguoDramas(ctx context.Context) ([]Drama, error) {
	initialized := hongguoCatalogInitialized(d.hongguoCatalogSnapshot())
	dramas, appErr := d.fetchHongguoAppCatalog(ctx)
	if len(dramas) > 0 || appErr == nil && initialized {
		return dramas, appErr
	}
	if ctx.Err() != nil {
		return dramas, ctx.Err()
	}
	webDramas, webErr := d.fetchHongguoWebDramas(ctx)
	if len(webDramas) > 0 && webErr == nil {
		return webDramas, nil
	}
	return webDramas, errors.Join(appErr, webErr)
}

func (d *Downloader) fetchHongguoWebDramas(ctx context.Context) ([]Drama, error) {
	routes := []struct {
		path string
		name string
	}{
		{path: "real-drama", name: "真人剧"},
		{path: "comic-drama", name: "漫剧"},
		{path: "ai-drama", name: "AI剧"},
		{path: "comic", name: "动漫"},
	}
	type routeResult struct {
		dramas []Drama
		err    error
	}
	results := make(chan routeResult, len(routes))
	for _, route := range routes {
		route := route
		go func() {
			dramas, err := d.fetchHongguoRoute(ctx, route.path, route.name)
			results <- routeResult{dramas: dramas, err: err}
		}()
	}
	seen := map[string]bool{}
	var out []Drama
	var failures []error
	for range routes {
		result := <-results
		if result.err != nil {
			failures = append(failures, result.err)
		}
		for _, drama := range result.dramas {
			if drama.ID != "" && !seen[drama.ID] {
				seen[drama.ID] = true
				out = append(out, drama)
			}
		}
	}
	sort.SliceStable(out, func(i, j int) bool { return out[i].DisplayTitle() < out[j].DisplayTitle() })
	return out, errors.Join(failures...)
}

func (d *Downloader) fetchHongguoRoute(ctx context.Context, route, category string) ([]Drama, error) {
	pages := d.cfg.MaxPagesPerSort
	if pages < 1 {
		pages = 1
	}
	var dramas []Drama
	seen := map[string]bool{}
	for page := 1; page <= pages; page++ {
		items, totalPages, err := d.fetchHongguoCategoryPage(ctx, route+"?page="+strconv.Itoa(page), category)
		if err != nil {
			return dramas, fmt.Errorf("%s: %w", category, err)
		}
		if totalPages > pages {
			pages = totalPages
			if pages > 500 {
				pages = 500
			}
		}
		reportLibraryProgress(ctx, sourceHongguo, items, nil, false)
		added := 0
		for _, drama := range items {
			if !seen[drama.ID] {
				seen[drama.ID] = true
				dramas = append(dramas, drama)
				added++
			}
		}
		if added == 0 || len(items) < 24 {
			break
		}
	}
	return dramas, nil
}

func (d *Downloader) fetchHongguoCategoryPage(ctx context.Context, route, category string) ([]Drama, int, error) {
	body, err := d.fetchProviderText(ctx, hongguoBaseURL+"/category/"+route, hongguoBaseURL+"/")
	if err != nil {
		return nil, 0, err
	}
	data := parseRouterData(body)
	page := routerLoaderMap(data, "category_page", "category_$")
	if len(page) == 0 || page["isSuccess"] == false {
		return nil, 0, errors.New("红果分类数据不可用，可能是页面结构或访问权限变化")
	}
	items := anyList(page["recommendList"])
	out := make([]Drama, 0, len(items))
	for _, item := range items {
		if dr := hongguoDramaFromAny(item, category); dr.ID != "" {
			out = append(out, dr)
		}
	}
	pages, _ := strconv.Atoi(mapString(nestedMap(page, "pagination"), "totalPages"))
	return out, pages, nil
}

func (d *Downloader) fetchHongguoChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	sourceID = strings.TrimPrefix(strings.TrimSpace(sourceID), "hg-series-v1:")
	if sourceID == "" {
		return "", nil, fmt.Errorf("empty hongguo sourceID")
	}
	entry, appErr := d.hongguoAppDetail(ctx, sourceID)
	if appErr == nil {
		return entry.Drama.DisplayTitle(), append([]Chapter(nil), entry.Chapters...), nil
	}
	if ctx.Err() != nil {
		return "", nil, ctx.Err()
	}
	title, chapters, webErr := d.fetchHongguoWebChapters(ctx, sourceID)
	if webErr == nil {
		return title, chapters, nil
	}
	return "", nil, fmt.Errorf("App 详情失败: %v；网页详情失败: %w", publicError(appErr), webErr)
}

func (d *Downloader) fetchHongguoWebChapters(ctx context.Context, sourceID string) (string, []Chapter, error) {
	data, err := d.fetchHongguoRouterPage(ctx, hongguoBaseURL+"/detail?series_id="+url.QueryEscape(sourceID), hongguoBaseURL+"/")
	if err != nil {
		return "", nil, err
	}
	page := routerLoaderMap(data, "detail_page", "detail_")
	detail, _ := page["seriesDetail"].(map[string]any)
	if len(detail) == 0 {
		return "", nil, fmt.Errorf("hongguo detail is empty")
	}
	title := firstNonEmpty(mapString(detail, "series_name", "series_title", "name"), sourceID)
	vids := anyList(detail["vid_list"])
	chapters := make([]Chapter, 0, len(vids))
	for i, v := range vids {
		vid := strings.TrimSpace(fmt.Sprint(v))
		if vid == "" || vid == "<nil>" {
			continue
		}
		if !hongguoNumericID.MatchString(vid) {
			return title, nil, errors.New("红果网页详情返回了无效的剧集 ID")
		}
		idx := i + 1
		chapters = append(chapters, Chapter{ID: providerChapterID(sourceHongguo, sourceID, vid), Source: sourceHongguo, Title: fmt.Sprintf("第%d集", idx), VideoURL: "hongguo-cenc://" + vid, CurrentEpisode: rawEpisode(idx)})
	}
	if len(chapters) == 0 {
		return title, nil, errors.New("红果详情没有返回剧集 ID")
	}
	if declared := mapString(detail, "episode_cnt"); declared != "" {
		total, convErr := strconv.Atoi(declared)
		if convErr != nil || total != len(chapters) {
			return title, nil, fmt.Errorf("红果网页详情分集数量与剧集总数不符（返回 %d 集，声明 %s）", len(chapters), declared)
		}
	}
	for index, chapter := range chapters {
		if chapter.EpisodeString(index+1) != strconv.Itoa(index+1) {
			return title, nil, errors.New("红果网页详情分集列表不连续")
		}
	}
	return title, chapters, nil
}

func parseRouterData(raw string) map[string]any {
	idx := regexp.MustCompile(`(?s)(?:window\.)?_ROUTER_DATA\s*=\s*`).FindStringIndex(raw)
	if idx == nil {
		return nil
	}
	var data map[string]any
	dec := json.NewDecoder(strings.NewReader(raw[idx[1]:]))
	dec.UseNumber()
	if err := dec.Decode(&data); err != nil {
		return nil
	}
	return data
}

// hongguoFullResolveKey 标记「必须走完整取流链」。
//
// 红果对公开剧集使用固定形态的 360p 直链（/video/public/{vid}/360p.mp4），
// 剧集 ID 就在章节里，因此解析可以零网络完成——但当这条直链不可用、需要
// 换一条真实地址时必须绕开快速通道，否则会在同一个地址上空转。
type hongguoFullResolveKey struct{}

func hongguoRequiresFullResolve(ctx context.Context) bool {
	flag, _ := ctx.Value(hongguoFullResolveKey{}).(bool)
	return flag
}

func (d *Downloader) resolveHongguoMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, seriesID, ok := splitProviderDramaID(task.DramaID)
	if !ok || source != sourceHongguo {
		return providerMedia{}, fmt.Errorf("红果章节缺少剧 ID，请刷新剧库后重新加入队列")
	}
	videoID := strings.TrimPrefix(task.Chapter.VideoURL, "hongguo-cenc://")
	if !hongguoNumericID.MatchString(videoID) || !hongguoNumericID.MatchString(seriesID) {
		return providerMedia{}, fmt.Errorf("红果章节 ID 无效，请重新获取章节")
	}
	// 红果已把公开 SEO 直链降级为 10 秒试看片段（播放页元数据仍谎报完整时长），
	// 完整播放必须走受保护的 play-info 接口拿签名全量地址。
	media, protectedErr := d.resolveHongguoProtectedMedia(ctx, seriesID, videoID)
	if protectedErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	// 兜底：App 取流 / 网页播放页 / Playback API。公开直链已失效，这些路径仅在
	// play-info 接口整体不可用时作为最后手段，不会把试看片段冒充整集。
	media, nativeErr := d.resolveHongguoAppMedia(ctx, videoID)
	if nativeErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, pageErr := d.resolveHongguoWebMedia(ctx, seriesID, videoID)
	if pageErr == nil {
		return media, nil
	}
	if err := ctx.Err(); err != nil {
		return providerMedia{}, err
	}
	media, apiErr := d.resolveHongguoPlaybackAPI(ctx, seriesID, videoID)
	if apiErr == nil {
		return media, nil
	}
	return providerMedia{}, fmt.Errorf("红果取流失败：受保护接口 %v；App %v；网页 %v；备用 %w", publicError(protectedErr), publicError(nativeErr), publicError(pageErr), apiErr)
}

// hongguoWebUserAgent 站点网页路由（详情/播放页）只放行桌面浏览器 UA，
// 核心默认的 iPhone UA 与各类移动 UA 都会被稳定 404。
const hongguoWebUserAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"

// hongguoWebMediaUserAgent 红果网页媒体（播放页公开直链）同样只放行桌面浏览器 UA，
// 默认 UA 与移动 UA 会拿到 404；其他站源媒体沿用默认 UA。
func hongguoWebMediaUserAgent(address string) string {
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil {
		return userAgent
	}
	switch strings.ToLower(parsed.Hostname()) {
	case "hongguoduanju.com", "www.hongguoduanju.com":
		return hongguoWebUserAgent
	}
	return userAgent
}

// hongguoRouterPageAttempts 站点会对网页请求随机返回 404，拉取后需重试再判定失败。
const hongguoRouterPageAttempts = 3

// fetchHongguoRouterPage 拉取红果网页并解析 _ROUTER_DATA，
// 使用浏览器 UA 并对站点随机返回的 404 做有限重试。
func (d *Downloader) fetchHongguoRouterPage(ctx context.Context, pageURL, referer string) (map[string]any, error) {
	ctx = context.WithValue(ctx, providerTextUserAgentKey{}, hongguoWebUserAgent)
	var lastErr error
	for attempt := 1; attempt <= hongguoRouterPageAttempts; attempt++ {
		if attempt > 1 {
			timer := time.NewTimer(time.Duration(attempt) * 400 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return nil, ctx.Err()
			case <-timer.C:
			}
		}
		body, err := d.fetchProviderText(ctx, pageURL, referer)
		if err == nil {
			return parseRouterData(body), nil
		}
		lastErr = err
		var backoff *requestBackoff
		if errors.As(err, &backoff) || ctx.Err() != nil {
			return nil, err
		}
	}
	return nil, lastErr
}

func (d *Downloader) resolveHongguoWebMedia(ctx context.Context, seriesID, videoID string) (providerMedia, error) {
	base := d.providerBaseURL(sourceHongguo)
	pageURL := base + "/player/" + url.PathEscape(seriesID) + "/" + url.PathEscape(videoID)
	data, err := d.fetchHongguoRouterPage(ctx, pageURL, base+"/")
	if err != nil {
		return providerMedia{}, err
	}
	page := routerLoaderMap(data, "player_", "player_page")
	// 新版播放页：公开剧集的播放信息收敛在 publicVideoSeo，取流走站点 SEO 直链。
	if seo, _ := page["publicVideoSeo"].(map[string]any); len(seo) > 0 {
		return d.hongguoPublicSEOMedia(ctx, base, seo, seriesID, videoID)
	}
	// 旧版播放页：video_player_info 内直接给出播放地址。
	if mapString(page, "vid") != videoID || mapString(page, "series_id") != seriesID {
		return providerMedia{}, fmt.Errorf("红果未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限")
	}
	info, _ := page["video_player_info"].(map[string]any)
	addresses := hongguoMediaAddresses(info)
	if len(addresses) == 0 {
		return providerMedia{}, fmt.Errorf("红果该集未提供公开播放地址，可能需要登录或 App 授权；不会将试看集冒充该集下载")
	}
	duration, _ := strconv.ParseFloat(mapString(info, "duration"), 64)
	media := providerMedia{URL: addresses[0], Referer: base + "/", Duration: time.Duration(duration * float64(time.Second))}
	for _, address := range addresses {
		variant := media
		variant.URL, variant.Variants = address, nil
		media.Variants = append(media.Variants, variant)
	}
	return media, nil
}

// hongguoPublicSEOMedia 解析新版播放页的公开播放信息。
// 站点播放器对 available 的剧集原使用 /video/public/{vid}/360p.mp4 直链，但已被
// 降级为 10 秒试看片段；真实全量地址改由受保护的 play-info 接口给出，这里只做
// 剧集匹配与可用性校验，再把取流交给 resolveHongguoProtectedMedia。
func (d *Downloader) hongguoPublicSEOMedia(ctx context.Context, base string, seo map[string]any, seriesID, videoID string) (providerMedia, error) {
	if mapString(seo, "seriesId") != seriesID || mapString(seo, "itemId") != videoID {
		return providerMedia{}, fmt.Errorf("红果网页未返回所请求的剧集，可能仅允许网页试看；请在站点确认该集的访问权限")
	}
	if !hongguoSEOAvailable(seo) {
		return providerMedia{}, fmt.Errorf("红果该集未开放公开播放，可能需要登录或 App 授权；不会将试看集冒充该集下载")
	}
	// 公开 SEO 直链已降级为 10 秒试看片段，真实地址改由受保护 play-info 接口给出。
	return d.resolveHongguoProtectedMedia(ctx, seriesID, videoID)
}

// hongguoPublicVideoPath 站点播放器曾用于公开剧集的 SEO 直链路径（固定 360p）。
//
// 该直链现已被站点降级为 10 秒试看片段（播放页元数据仍谎报完整时长），不再用于
// 取流；保留此函数仅作路径构造参考，完整地址改由 resolveHongguoProtectedMedia 取得。
func hongguoPublicVideoPath(videoID string) string {
	if !hongguoNumericID.MatchString(videoID) {
		return ""
	}
	return "/video/public/" + videoID + "/360p.mp4"
}

// hongguoProtectedPlayInfoPath 红果受保护播放信息接口路径。站点把完整剧集地址收敛
// 到这里，公开 SEO 直链已降级为 10 秒试看片段。
const hongguoProtectedPlayInfoPath = "/api/video/protected/play-info"

// resolveHongguoProtectedMedia 经受保护的 play-info 接口取回完整签名地址。
//
// 该接口对公开剧集返回全量 mp4（而非 SEO 直链的 10 秒试看）。站点偶发随机 404，
// 这里做有限重试，与网页/直链预热行为保持一致。
func (d *Downloader) resolveHongguoProtectedMedia(ctx context.Context, seriesID, videoID string) (providerMedia, error) {
	if !hongguoNumericID.MatchString(seriesID) || !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, fmt.Errorf("红果播放请求缺少有效的剧集 ID")
	}
	base := d.providerBaseURL(sourceHongguo)
	payload, err := json.Marshal(map[string]string{
		"series_id":  seriesID,
		"item_id":    videoID,
		"definition": "720p",
	})
	if err != nil {
		return providerMedia{}, err
	}
	var lastErr error
	for attempt := 1; attempt <= hongguoRouterPageAttempts; attempt++ {
		if attempt > 1 {
			timer := time.NewTimer(time.Duration(attempt) * 400 * time.Millisecond)
			select {
			case <-ctx.Done():
				timer.Stop()
				return providerMedia{}, ctx.Err()
			case <-timer.C:
			}
		}
		request, err := http.NewRequestWithContext(ctx, http.MethodPost,
			base+hongguoProtectedPlayInfoPath+"?aid=8662", bytes.NewReader(payload))
		if err != nil {
			return providerMedia{}, err
		}
		request.Header.Set("User-Agent", hongguoWebUserAgent)
		request.Header.Set("Content-Type", "application/json")
		request.Header.Set("Accept", "application/json")
		response, err := d.client.Do(request)
		if err != nil {
			lastErr = err
			continue
		}
		body, readErr := io.ReadAll(response.Body)
		response.Body.Close()
		if readErr != nil {
			lastErr = readErr
			continue
		}
		if response.StatusCode != http.StatusOK {
			lastErr = fmt.Errorf("红果受保护播放接口返回 HTTP %d", response.StatusCode)
			if response.StatusCode == http.StatusNotFound || response.StatusCode >= 500 {
				continue
			}
			return providerMedia{}, lastErr
		}
		media, parseErr := parseHongguoProtectedPlayInfo(body)
		if parseErr != nil {
			lastErr = parseErr
			continue
		}
		return media, nil
	}
	if lastErr == nil {
		lastErr = errors.New("红果受保护播放接口未返回可用地址")
	}
	return providerMedia{}, lastErr
}

// parseHongguoProtectedPlayInfo 解析受保护播放信息接口响应，提取完整媒体地址。
func parseHongguoProtectedPlayInfo(body []byte) (providerMedia, error) {
	var envelope struct {
		LegacyPlayInfo struct {
			MainURL  string  `json:"main_url"`
			Height   string  `json:"height"`
			Duration float64 `json:"duration"`
		} `json:"legacy_play_info"`
	}
	decoder := json.NewDecoder(bytes.NewReader(body))
	decoder.UseNumber()
	if err := decoder.Decode(&envelope); err != nil {
		return providerMedia{}, errors.New("红果受保护播放接口返回了无效数据")
	}
	address := strings.TrimSpace(envelope.LegacyPlayInfo.MainURL)
	if address == "" || len(address) > 8192 || !isProviderHTTPMediaURL(address) {
		return providerMedia{}, errors.New("红果受保护播放接口返回的媒体地址无效")
	}
	quality, _ := strconv.Atoi(hongguoQualityNumber.FindString(envelope.LegacyPlayInfo.Height))
	media := providerMedia{
		URL:      address,
		Quality:  quality,
		Duration: time.Duration(envelope.LegacyPlayInfo.Duration * float64(time.Second)),
	}
	media.Variants = []providerMedia{media}
	return media, nil
}

func hongguoSEOAvailable(seo map[string]any) bool {
	if flag, ok := seo["available"].(bool); ok {
		return flag
	}
	switch strings.ToLower(strings.TrimSpace(mapString(seo, "available"))) {
	case "true", "1":
		return true
	}
	return false
}

func hongguoDramaFromAny(v any, category string) Drama {
	m, ok := v.(map[string]any)
	if !ok {
		return Drama{}
	}
	vd, _ := m["video_data"].(map[string]any)
	if len(vd) == 0 {
		vd = m
	}
	sourceID := firstNonEmpty(mapString(vd, "series_id_str", "series_id"), mapString(m, "series_id_str", "series_id"), mapString(vd, "keyword"), mapString(m, "keyword"))
	if !hongguoNumericID.MatchString(sourceID) {
		return Drama{}
	}
	title := firstNonEmpty(mapString(vd, "series_title", "series_name", "title"), mapString(m, "series_name", "name"), sourceID)
	cover := firstNonEmpty(mapString(vd, "series_cover", "cover"), mapString(m, "series_cover"))
	intro := firstNonEmpty(mapString(vd, "series_intro", "video_desc"), mapString(m, "series_intro"))
	count := firstNonEmpty(mapString(vd, "episode_cnt"), mapString(m, "episode_cnt"))
	remark := firstNonEmpty(mapString(vd, "episode_right_text"), mapString(m, "episode_right_text"))
	releaseStatus := releaseStatusFromRemark(remark)
	if mapString(vd, "series_status") == "1" {
		releaseStatus = "finished"
	} else if mapString(vd, "series_status") == "0" {
		releaseStatus = "ongoing"
	}
	if remark == "" && count != "" {
		remark = "共" + count + "集"
	}
	tags := mapStringSlice(vd, "tags")
	for _, value := range anyList(vd["category_list"]) {
		item, _ := value.(map[string]any)
		if name := mapString(item, "name"); name != "" && !slices.Contains(tags, name) {
			tags = append(tags, name)
		}
	}
	var categories []struct {
		Name string `json:"name"`
	}
	if json.Unmarshal([]byte(mapString(vd, "category_schema")), &categories) == nil {
		for _, item := range categories {
			if item.Name != "" && !slices.Contains(tags, item.Name) {
				tags = append(tags, item.Name)
			}
		}
	}
	genre := mapString(vd, "category_name", "categoryName", "category")
	if genre == "" && len(tags) > 0 {
		genre = tags[0]
	}
	return Drama{ID: providerDramaID(sourceHongguo, sourceID), Source: sourceHongguo, SourceID: sourceID, Title: title, Name: title, Desc: intro, Intro: intro, Cover: cover, CoverURL: cover, CategoryName: firstNonEmpty(genre, category), ChannelName: "红果", Remark: remark, TotalEpisode: count, EpisodeCount: count, Tags: tags, ReleaseStatus: releaseStatus, Score: mapString(vd, "score"), Views: mapString(vd, "series_play_cnt", "play_cnt"), Heat: hongguoHeat(vd), OnlineDate: hongguoOnlineDate(vd, time.Now())}
}

func nestedMap(v any, keys ...string) map[string]any {
	cur, _ := v.(map[string]any)
	for _, key := range keys {
		if cur == nil {
			return nil
		}
		cur, _ = cur[key].(map[string]any)
	}
	return cur
}

func routerLoaderMap(data map[string]any, names ...string) map[string]any {
	loader, _ := data["loaderData"].(map[string]any)
	for _, name := range names {
		if page, _ := loader[name].(map[string]any); len(page) > 0 {
			return page
		}
	}
	for key, value := range loader {
		for _, name := range names {
			if strings.TrimSuffix(name, "$") != "" && strings.HasPrefix(key, strings.TrimSuffix(name, "$")) {
				if page, _ := value.(map[string]any); len(page) > 0 {
					return page
				}
			}
		}
	}
	return nil
}

func anyList(v any) []any {
	switch x := v.(type) {
	case []any:
		return x
	case map[string]any:
		for _, key := range []string{"list", "items", "data"} {
			if out := anyList(x[key]); len(out) > 0 {
				return out
			}
		}
	}
	return nil
}
