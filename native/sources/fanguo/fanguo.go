package fanguo

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"

	"duanjuapp/native/provider"
)

var categories = []provider.CatalogCategory{
	{ID: "都市", Name: "都市"},
	{ID: "甜宠", Name: "甜宠"},
	{ID: "逆袭", Name: "逆袭"},
	{ID: "战神", Name: "战神"},
	{ID: "古装", Name: "古装"},
	{ID: "穿越", Name: "穿越"},
	{ID: "萌宝", Name: "萌宝"},
}

const defaultKeyword = "都市"

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

func (s *Source) dramaFromNode(node map[string]any, base string) provider.Drama {
	id := provider.FindString(node, "duanjuId", "duanju_id", "id")
	if id == "" {
		return provider.Drama{}
	}
	source := provider.FindString(node, "source")
	sourceKey := id
	if source != "" {
		sourceKey = id + "#" + source
	}
	tags := provider.StringList(node["categories"])
	return provider.Drama{
		ID:           provider.DramaID(s.spec.ID, sourceKey),
		Source:       s.spec.ID,
		SourceID:     sourceKey,
		Title:        provider.FindString(node, "title", "name"),
		Intro:        provider.FindString(node, "description", "desc", "intro"),
		Cover:        provider.Cover(base, node, "coverImageUrl", "cover_image_url", "cover"),
		EpisodeCount: json.Number(strconv.Itoa(provider.FindInt(node, "total", "totalEpisodeNum"))),
		Category:     provider.CSV(tags),
		Tags:         tags,
		ChannelName:  provider.SourceName(s.spec.ID),
	}
}

func (s *Source) searchList(ctx context.Context, host provider.Host, base, keyword string) ([]provider.Drama, error) {
	address := base + "/xifan/search/getSearchList?" + url.Values{
		"reqType":            {"search"},
		"offset":             {"0"},
		"keyword":            {keyword},
		"quickEngineVersion": {"-1"},
		"scene":              {""},
	}.Encode()
	response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, err
	}
	var items []provider.Drama
	seen := map[string]bool{}
	for _, block := range provider.FindList(provider.FindMap(response, "result"), "elements") {
		mapped, ok := block.(map[string]any)
		if !ok {
			continue
		}
		for _, entry := range provider.FindList(mapped, "contents") {
			content, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			drama := s.dramaFromNode(provider.FindMap(content, "duanjuVo"), base)
			if drama.ID == "" || seen[drama.ID] {
				continue
			}
			seen[drama.ID] = true
			items = append(items, drama)
		}
	}
	return items, nil
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	return categories, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	if page > 1 {
		return nil, false, nil
	}
	base := s.base(host)
	keyword := strings.TrimSpace(category)
	if keyword == "" {
		keyword = defaultKeyword
	}
	items, err := s.searchList(ctx, host, base, keyword)
	if err != nil {
		return nil, false, err
	}
	return items, false, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	duanjuID, source := sourceID, ""
	if id, rest, found := strings.Cut(sourceID, "#"); found {
		duanjuID, source = id, rest
	}
	address := base + "/xifan/drama/getDuanjuInfo?" + url.Values{
		"duanjuId": {duanjuID},
		"source":   {source},
	}.Encode()
	response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return provider.Drama{}, nil, err
	}
	data := provider.FindMap(response, "result")
	if data == nil {
		return provider.Drama{}, nil, errors.New("饭果未返回剧集资料")
	}
	drama := provider.Drama{
		ID:          provider.DramaID(s.spec.ID, sourceID),
		Source:      s.spec.ID,
		SourceID:    sourceID,
		Title:       provider.FindString(data, "title", "name"),
		Intro:       provider.FindString(data, "description", "desc", "intro"),
		Cover:       provider.Cover(base, data, "coverImageUrl", "cover_image_url", "cover"),
		Category:    provider.CSV(provider.StringList(data["categories"])),
		Tags:        provider.StringList(data["categories"]),
		ChannelName: provider.SourceName(s.spec.ID),
		ReleaseStatus: provider.ReleaseStatus(
			provider.FindString(data, "updateStatus"),
			provider.FindInt(data, "total"), provider.FindInt(data, "current"),
		),
	}
	var chapters []provider.Chapter
	for index, entry := range provider.FindList(data, "episodeList") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := provider.FindString(node, "playUrl", "play_url", "videoUrl")
		if videoURL == "" {
			continue
		}
		number := provider.FindInt(node, "index", "episode", "sort")
		if number <= 0 {
			number = index + 1
		}
		chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number,
			provider.FindString(node, "title", "name"), videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("饭果未返回可播放分集")
	}
	provider.SortChapters(chapters)
	return drama, chapters, nil
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	base := s.base(host)
	return s.searchList(ctx, host, base, query)
}
