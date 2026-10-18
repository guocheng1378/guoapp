package yaguo

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"duanjuapp/native/provider"
)

const loginURL = "https://u.shytkjgs.com/user/v1/account/login"

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

func (s *Source) loginAddress(host provider.Host) string {
	base := s.base(host)
	if base != "" && base != s.spec.Base {
		return strings.TrimRight(base, "/") + "/user/v1/account/login"
	}
	return loginURL
}

func (s *Source) token(ctx context.Context, host provider.Host) (string, error) {
	return provider.CachedToken(s.spec.ID, 6*time.Hour, func(_ context.Context) (string, error) {
		payload, err := json.Marshal(map[string]any{"device": "24250683a3bdb3f118dff25ba4b1cba1a"})
		if err != nil {
			return "", err
		}
		response, err := host.JSON(context.Background(), provider.Request{
			Source:  s.spec.ID,
			Method:  http.MethodPost,
			Address: s.loginAddress(host),
			Headers: map[string]string{"platform": "1", "Content-Type": "application/json"},
			Body:    payload,
			Timeout: 15 * time.Second,
		})
		if err != nil {
			return "", fmt.Errorf("芽果登录失败：%w", err)
		}
		token := provider.FindString(provider.FindMap(response, "data"), "token")
		if token == "" {
			token = provider.FindString(response, "token")
		}
		if token == "" {
			return "", errors.New("芽果未返回有效的访问令牌")
		}
		return token, nil
	})
}

func (s *Source) request(ctx context.Context, host provider.Host, path string, query url.Values) (map[string]any, error) {
	token, err := s.token(ctx, host)
	if err != nil {
		return nil, err
	}
	base := s.base(host)
	address := base + path
	if len(query) > 0 {
		address += "?" + query.Encode()
	}
	return host.JSON(ctx, provider.Request{
		Source:  s.spec.ID,
		Address: address,
		Referer: base + "/",
		Headers: map[string]string{
			"authorization": token,
			"platform":      "1",
			"version_name":  "3.8.3.1",
		},
	})
}

func (s *Source) dramaFromNode(node map[string]any, base string) provider.Drama {
	theater := provider.FindMap(node, "theater")
	if theater == nil {
		theater = node
	}
	id := provider.FindString(theater, "id", "theater_id", "theater_parent_id")
	if id == "" {
		return provider.Drama{}
	}
	total := provider.FindInt(theater, "total", "total_num", "current_num")
	return provider.Drama{
		ID:           provider.DramaID(s.spec.ID, id),
		Source:       s.spec.ID,
		SourceID:     id,
		Title:        provider.FindString(theater, "title", "name"),
		Intro:        provider.FindString(theater, "descrip", "introduction", "desc"),
		Cover:        provider.Cover(base, theater, "cover_url", "son_cover_url", "cover"),
		EpisodeCount: json.Number(strconv.Itoa(total)),
		Category:     provider.CSV(provider.StringList(theater["tags"])),
		ChannelName:  provider.SourceName(s.spec.ID),
	}
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	response, err := s.request(ctx, host, "/cloud/v2/theater/classes", nil)
	if err != nil {
		return nil, err
	}
	var categories []provider.CatalogCategory
	seen := map[string]bool{}
	appendClass := func(entries []any) {
		for _, entry := range entries {
			node, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			id := provider.FindString(node, "id")
			name := provider.FindString(node, "class_name", "name")
			if id == "" || name == "" || seen[id] || len([]rune(name)) > 24 {
				continue
			}
			seen[id] = true
			categories = append(categories, provider.CatalogCategory{ID: id, Name: name})
		}
	}
	for _, group := range provider.FindList(response, "data") {
		mapped, ok := group.(map[string]any)
		if !ok {
			continue
		}
		appendClass(provider.FindList(mapped, "alg_class"))
	}
	if len(categories) == 0 {
		return nil, errors.New("芽果未返回有效分类")
	}
	return categories, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.base(host)
	classID := strings.TrimSpace(category)
	if classID == "9" {
		response, err := s.request(ctx, host, "/cloud/v1/first_level_ranking/detail", url.Values{"id": {"1"}})
		if err != nil {
			return nil, false, err
		}
		var items []provider.Drama
		for _, entry := range provider.FindList(provider.FindMap(response, "data"), "list") {
			node, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			if drama := s.dramaFromNode(node, base); drama.ID != "" {
				items = append(items, drama)
			}
		}
		return items, false, nil
	}
	if classID != "" && !provider.IsNumericID(classID) {
		classID = ""
	}
	response, err := s.request(ctx, host, "/cloud/v2/theater/home_page", url.Values{
		"theater_class_id": {classID},
		"type":             {"1"},
		"class2_ids":       {"0"},
		"page_num":         {strconv.Itoa(page)},
		"page_size":        {"24"},
	})
	if err != nil {
		return nil, false, err
	}
	data := provider.FindMap(response, "data")
	var items []provider.Drama
	for _, entry := range provider.FindList(data, "list") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := s.dramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	total := provider.FindInt(data, "total")
	hasMore := !provider.FindBool(data, "is_end") && len(items) > 0 && total > page*len(items)
	return items, hasMore, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	response, err := s.request(ctx, host, "/v2/theater_parent/detail", url.Values{"theater_parent_id": {sourceID}})
	if err != nil {
		return provider.Drama{}, nil, err
	}
	data := provider.FindMap(response, "data")
	if data == nil {
		return provider.Drama{}, nil, errors.New("芽果未返回剧集资料")
	}
	drama := provider.Drama{
		ID:           provider.DramaID(s.spec.ID, sourceID),
		Source:       s.spec.ID,
		SourceID:     sourceID,
		Title:        provider.FindString(data, "title", "share_title"),
		Intro:        provider.FindString(data, "descrip", "introduction", "share_title"),
		Cover:        provider.Cover(base, data, "cover_url", "share_cover"),
		EpisodeCount: json.Number(strconv.Itoa(provider.FindInt(data, "total"))),
		ReleaseStatus: provider.ReleaseStatus(
			strconv.Itoa(provider.FindInt(data, "is_over")),
			provider.FindInt(data, "total"), provider.FindInt(data, "current_num"),
		),
		ChannelName: provider.SourceName(s.spec.ID),
	}
	if drama.ReleaseStatus == "" && provider.FindInt(data, "is_over") == 2 {
		drama.ReleaseStatus = "finished"
	}
	var chapters []provider.Chapter
	for index, entry := range provider.FindList(data, "theaters") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := provider.FindString(node, "son_video_url", "video_url")
		if videoURL == "" {
			continue
		}
		number := provider.FindInt(node, "num", "sort")
		if number <= 0 {
			number = index + 1
		}
		title := provider.FindString(node, "son_title", "title")
		chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number, title, videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("芽果未返回可播放分集")
	}
	provider.SortChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	token, err := s.token(ctx, host)
	if err != nil {
		return nil, err
	}
	base := s.base(host)
	payload, err := json.Marshal(map[string]any{"text": query})
	if err != nil {
		return nil, err
	}
	response, err := host.JSON(ctx, provider.Request{
		Source:  s.spec.ID,
		Method:  http.MethodPost,
		Address: base + "/v3/search",
		Referer: base + "/",
		Headers: map[string]string{
			"authorization": token,
			"platform":      "1",
			"version_name":  "3.8.3.1",
			"Content-Type":  "application/json",
		},
		Body: payload,
	})
	if err != nil {
		return nil, err
	}
	rows := provider.FindList(provider.FindMap(response, "data"), "list")
	if rows == nil {
		rows = provider.FindList(provider.FindMap(provider.FindMap(response, "data"), "theater"), "search_data")
	}
	var items []provider.Drama
	for _, entry := range rows {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		if drama := s.dramaFromNode(node, base); drama.ID != "" {
			items = append(items, drama)
		}
	}
	return items, nil
}
