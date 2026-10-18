package maoguo

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"time"

	"duanjuapp/native/provider"
)

const (
	key      = "d3dGiJc651gSQ8w1"
	trackID  = "ec1280db127955061754851657967"
	readURL  = "https://api-read.qmplaylet.com"
)

var charMap = map[rune]rune{
	'+': 'P', '/': 'X', '0': 'M', '1': 'U', '2': 'l', '3': 'E', '4': 'r', '5': 'Y', '6': 'W', '7': 'b', '8': 'd', '9': 'J',
	'A': '9', 'B': 's', 'C': 'a', 'D': 'I', 'E': '0', 'F': 'o', 'G': 'y', 'H': '_', 'I': 'H', 'J': 'G', 'K': 'i', 'L': 't',
	'M': 'g', 'N': 'N', 'O': 'A', 'P': '8', 'Q': 'F', 'R': 'k', 'S': '3', 'T': 'h', 'U': 'f', 'V': 'R', 'W': 'q', 'X': 'C',
	'Y': '4', 'Z': 'p', 'a': 'm', 'b': 'B', 'c': 'O', 'd': 'u', 'e': 'c', 'f': '6', 'g': 'K', 'h': 'x', 'i': '5', 'j': 'T',
	'k': '-', 'l': '2', 'm': 'z', 'n': 'S', 'o': 'Z', 'p': '1', 'q': 'V', 'r': 'v', 's': 'j', 't': 'Q', 'u': '7', 'v': 'D',
	'w': 'w', 'x': 'n', 'y': 'L', 'z': 'e',
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

func headers() (map[string]string, error) {
	session := strconv.FormatInt(time.Now().UnixMilli(), 10)
	payload := map[string]any{
		"static_score":  "0.8",
		"uuid":          "00000000-7fc7-08dc-0000-000000000000",
		"device-id":     "20250220125449b9b8cac84c2dd3d035c9052a2572f7dd0122edde3cc42a70",
		"mac":           "",
		"sourceuid":     "aa7de295aad621a6",
		"refresh-type":  "0",
		"model":         "22021211RC",
		"wlb-imei":      "",
		"client-id":     "aa7de295aad621a6",
		"brand":         "Redmi",
		"oaid":          "",
		"oaid-no-cache": "",
		"sys-ver":       "12",
		"trusted-id":    "",
		"phone-level":   "H",
		"imei":          "",
		"wlb-uid":       "aa7de295aad621a6",
		"session-id":    session,
	}
	encoded, err := json.Marshal(payload)
	if err != nil {
		return nil, err
	}
	encodedText := base64.StdEncoding.EncodeToString(encoded)
	mapped := make([]rune, 0, len(encodedText))
	for _, char := range encodedText {
		if replacement, found := charMap[char]; found {
			mapped = append(mapped, replacement)
			continue
		}
		mapped = append(mapped, char)
	}
	qmParams := string(mapped)
	signature := provider.MD5("AUTHORIZATION=" +
		"app-version=10001" +
		"application-id=com.duoduo.read" +
		"channel=unknown" +
		"is-white=" +
		"net-env=5" +
		"platform=android" +
		"qm-params=" + qmParams +
		"reg=" + key)
	return map[string]string{
		"net-env":          "5",
		"reg":              "",
		"channel":          "unknown",
		"is-white":         "",
		"platform":         "android",
		"application-id":   "com.duoduo.read",
		"authorization":    "",
		"app-version":      "10001",
		"user-agent":       "webviewversion/0",
		"qm-params":        qmParams,
		"sign":             signature,
		"Accept":           "application/json",
		"X-Requested-With": "com.duoduo.read",
	}, nil
}

func (s *Source) dramaFromNode(node map[string]any, base string) provider.Drama {
	id := provider.FindString(node, "playlet_id", "playletId", "id")
	if id == "" {
		return provider.Drama{}
	}
	total := provider.FindInt(node, "total_episode_num", "totalEpisodeNum", "total")
	tags := provider.StringList(node["tags"])
	if len(tags) == 0 {
		tags = provider.StringList(node["tag_list"])
	}
	return provider.Drama{
		ID:           provider.DramaID(s.spec.ID, id),
		Source:       s.spec.ID,
		SourceID:     id,
		Title:        provider.PlainText(provider.FindString(node, "title", "playlet_name", "name")),
		Intro:        provider.PlainText(provider.FindString(node, "intro", "description", "desc")),
		Cover:        provider.Cover(base, node, "image_link", "imageLink", "cover", "cover_url"),
		EpisodeCount: json.Number(strconv.Itoa(total)),
		Category:     provider.CSV(tags),
		Tags:         tags,
		ChannelName:  provider.SourceName(s.spec.ID),
	}
}

func (s *Source) catalogItems(data map[string]any, base string) []provider.Drama {
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
	return items
}

func (s *Source) get(ctx context.Context, host provider.Host, address, base string) (map[string]any, error) {
	requestHeaders, err := headers()
	if err != nil {
		return nil, err
	}
	return host.JSON(ctx, provider.Request{
		Source:  s.spec.ID,
		Address: address,
		Referer: base + "/",
		Headers: requestHeaders,
	})
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	base := s.base(host)
	signature := provider.MD5("operation=1" + key)
	address := fmt.Sprintf("%s/api/v1/playlet/tag/list?operation=1&sign=%s", base, signature)
	response, err := s.get(ctx, host, address, base)
	if err != nil {
		return nil, err
	}
	var categories []provider.CatalogCategory
	for _, entry := range provider.FindList(provider.FindMap(response, "data"), "list") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		id := provider.FindString(node, "tag_id", "id")
		name := provider.FindString(node, "tag_name", "name", "title")
		if id == "" || name == "" || len([]rune(name)) > 24 {
			continue
		}
		categories = append(categories, provider.CatalogCategory{ID: id, Name: name})
	}
	return categories, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.base(host)
	tagID := strings.TrimSpace(category)
	if tagID != "" && !provider.IsNumericID(tagID) {
		tagID = "0"
	}
	if tagID == "" {
		tagID = "0"
	}
	address := ""
	if page > 1 {
		signature := provider.MD5("next_id=" + strconv.Itoa(page) + "operation=1playlet_privacy=1tag_id=" + tagID + key)
		address = fmt.Sprintf("%s/api/v1/playlet/index?tag_id=%s&playlet_privacy=1&operation=1&next_id=%d&sign=%s",
			base, tagID, page, signature)
	} else {
		signature := provider.MD5("operation=1playlet_privacy=1tag_id=" + tagID + key)
		address = fmt.Sprintf("%s/api/v1/playlet/index?tag_id=%s&playlet_privacy=1&operation=1&sign=%s", base, tagID, signature)
	}
	response, err := s.get(ctx, host, address, base)
	if err != nil {
		return nil, false, err
	}
	items := s.catalogItems(provider.FindMap(response, "data"), base)
	if page > 1 {
		return items, len(items) > 0, nil
	}
	return items, false, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	signature := provider.MD5("playlet_id=" + sourceID + key)
	address := fmt.Sprintf("%s/player/api/v1/playlet/info?playlet_id=%s&sign=%s", strings.TrimRight(readURL, "/"), url.QueryEscape(sourceID), signature)
	response, err := s.get(ctx, host, address, base)
	if err != nil {
		return provider.Drama{}, nil, err
	}
	data := provider.FindMap(response, "data")
	if data == nil {
		return provider.Drama{}, nil, errors.New("猫果未返回剧集资料")
	}
	drama := s.dramaFromNode(data, base)
	drama.ID, drama.Source, drama.SourceID = provider.DramaID(s.spec.ID, sourceID), s.spec.ID, sourceID
	var chapters []provider.Chapter
	for index, entry := range provider.FindList(data, "play_list") {
		node, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		videoURL := provider.FindString(node, "video_url", "videoUrl", "url")
		if videoURL == "" {
			continue
		}
		number := provider.FindInt(node, "sort", "episode", "index")
		if number <= 0 {
			number = index + 1
		}
		chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number,
			provider.FindString(node, "title", "name"), videoURL, "", base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("猫果未返回可播放分集")
	}
	provider.SortChapters(chapters)
	return drama, chapters, nil
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	base := s.base(host)
	signature := provider.MD5(fmt.Sprintf("extend=page=1read_preference=0track_id=%swd=%s%s", trackID, query, key))
	address := fmt.Sprintf("%s/api/v1/playlet/search?extend=&page=1&wd=%s&read_preference=0&track_id=%s&sign=%s",
		base, url.QueryEscape(query), trackID, signature)
	response, err := s.get(ctx, host, address, base)
	if err != nil {
		return nil, err
	}
	return s.catalogItems(provider.FindMap(response, "data"), base), nil
}
