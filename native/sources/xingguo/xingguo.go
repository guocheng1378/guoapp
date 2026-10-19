package xingguo

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"

	"duanjuapp/native/provider"
)

const (
	productID = "2a8c14d1-72e7-498b-af23-381028eb47c0"
	vestID    = "2be070e0-c824-4d0e-a67a-8f688890cadb"
	token     = "202509271001001446030204698626"
)

var categories = []provider.CatalogCategory{
	{ID: "1287", Name: "推荐一"},
	{ID: "1288", Name: "推荐二"},
	{ID: "1289", Name: "推荐三"},
	{ID: "1290", Name: "推荐四"},
	{ID: "1291", Name: "推荐五"},
}

type Source struct {
	spec provider.Spec
}

func New(spec provider.Spec) *Source {
	return &Source{spec: spec}
}

func (s *Source) Spec() provider.Spec { return s.spec }

func (s *Source) base(host provider.Host) string {
	if host != nil {
		if base := host.BaseURL(s.spec.ID); base != "" {
			return base
		}
	}
	return s.spec.Base
}

func resourceQuery(resourceID, page, size string) url.Values {
	return url.Values{
		"productId":  {productID},
		"vestId":     {vestID},
		"channel":    {"oppo19"},
		"osType":     {"android"},
		"version":    {"20"},
		"token":      {token},
		"resourceId": {resourceID},
		"pageNum":    {page},
		"pageSize":   {size},
	}
}

func (s *Source) dramaFromNode(node map[string]any, base string) provider.Drama {
	id := provider.FindString(node, "id", "bookId")
	if id == "" {
		return provider.Drama{}
	}
	// 星果把简介编码在 ID 中以携带到详情，此处沿用脚本约定。
	sourceKey := id
	if intro := provider.FindString(node, "introduction"); intro != "" {
		sourceKey = id + "@" + intro
	}
	heat := provider.FindInt(node, "heat")
	views := ""
	heatLabel := ""
	if heat > 0 {
		views = strconv.Itoa(heat) + "万播放"
		heatLabel = strconv.Itoa(heat)
	}
	return provider.Drama{
		ID:           provider.DramaID(s.spec.ID, sourceKey),
		Source:       s.spec.ID,
		SourceID:     sourceKey,
		Title:        provider.FindString(node, "name", "title"),
		Intro:        provider.FindString(node, "introduction", "desc"),
		Cover:        provider.Cover(base, node, "icon", "cover"),
		EpisodeCount: json.Number(strconv.Itoa(provider.FindInt(node, "chapterCount", "total"))),
		Heat:         heatLabel,
		Views:        views,
		ChannelName:  provider.SourceName(s.spec.ID),
	}
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	return categories, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.base(host)
	resourceID := strings.TrimSpace(category)
	if resourceID == "" {
		resourceID = categories[0].ID
	}
	if !provider.IsNumericID(resourceID) {
		return nil, false, errors.New("星果分类无效")
	}
	address := base + "/novel-api/app/pageModel/getResourceById?" + resourceQuery(resourceID, strconv.Itoa(page), "10").Encode()
	response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, false, err
	}
	data := provider.FindMap(response, "data")
	var items []provider.Drama
	for _, entry := range provider.FindList(data, "datalist") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := s.dramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items, len(items) >= 10, nil
}

func (s *Source) Search(ctx context.Context, host provider.Host, keyword string) ([]provider.Drama, error) {
	keyword = strings.TrimSpace(keyword)
	if keyword == "" {
		return nil, errors.New("请输入搜索关键词")
	}
	base := s.base(host)
	values := url.Values{
		"productId": {productID},
		"vestId":    {vestID},
		"channel":   {"oppo19"},
		"osType":    {"android"},
		"version":   {"20"},
		"token":     {token},
		"key":       {keyword},
		"pageNum":   {"1"},
		"pageSize":  {"20"},
	}
	address := base + "/novel-api/basedata/book/searchBook?" + values.Encode()
	response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, err
	}
	data := provider.FindMap(response, "data")
	var items []provider.Drama
	seen := map[string]bool{}
	for _, entry := range provider.FindList(data, "datalist") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		drama := s.dramaFromNode(node, base)
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		items = append(items, drama)
	}
	if len(items) == 0 {
		return nil, errors.New("星果未搜索到相关剧集")
	}
	return items, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	bookID, intro, _ := strings.Cut(sourceID, "@")
	address := base + "/novel-api/basedata/book/getChapterList?" + url.Values{
		"bookId":    {bookID},
		"productId": {productID},
		"vestId":    {vestID},
		"channel":   {"oppo19"},
		"osType":    {"android"},
		"version":   {"20"},
		"token":     {token},
	}.Encode()
	response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return provider.Drama{}, nil, err
	}
	drama := provider.Drama{
		ID:          provider.DramaID(s.spec.ID, sourceID),
		Source:      s.spec.ID,
		SourceID:    sourceID,
		Intro:       intro,
		ChannelName: provider.SourceName(s.spec.ID),
	}
	var chapters []provider.Chapter
	for index, entry := range provider.FindList(response, "data") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := episodeURL(node)
		if videoURL == "" {
			continue
		}
		number := index + 1
		if parsed := provider.FindInt(node, "chapterNum", "sort", "index"); parsed > 0 {
			number = parsed
		}
		chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number, "", videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("星果未返回可播放分集")
	}
	provider.SortChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func episodeURL(node map[string]any) string {
	if direct := provider.FindString(node, "shortPlayUrl", "playUrl", "url"); direct != "" {
		return direct
	}
	for _, listKey := range []string{"shortPlayList", "chapterShortPlayVoList"} {
		for _, entry := range provider.FindList(node, listKey) {
			child, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			if address := episodeURL(child); address != "" {
				return address
			}
		}
	}
	return ""
}
