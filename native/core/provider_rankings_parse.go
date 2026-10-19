package core

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

var rankingScriptTags = regexp.MustCompile(`(?is)<script\b[^>]*>`)

// rankingJSONLD / rankingSourceID 现定义在 app_cover_metadata.go（站源榜与
// 封面/详情元数据校验共用），此处不再重复声明。
var errHongguoRankingIncomplete = errors.New("红果榜单数据尚未完整返回，请稍后重试")
var errHongguoRankingFormat = errors.New("红果榜单格式或分页已变化，请稍后重试")

type hongguoRankingContent struct {
	Success bool `json:"isSuccess"`
	Rows    []struct {
		ID          string   `json:"id"`
		SeriesID    string   `json:"seriesId"`
		Rank        int      `json:"rank"`
		Title       string   `json:"title"`
		Heat        string   `json:"heatText"`
		Score       string   `json:"scoreText"`
		Tags        []string `json:"tags"`
		Description string   `json:"description"`
		EpisodeIDs  []string `json:"episodeVids"`
		Cover       any      `json:"cover"`
	} `json:"rankList"`
	Pagination struct {
		Page       int `json:"pageNum"`
		TotalPages int `json:"totalPages"`
	} `json:"pagination"`
}

func parseHongguoRanking(body string, board rankingBoard, page int) (rankingPage, error) {
	failure := errHongguoRankingFormat
	loaderKey := "rank_" + board.path + "/page"
	loader := nestedMap(parseRouterData(body), "loaderData", loaderKey)
	if len(loader) > 0 && (mapString(loader, "rankKey") != board.upstreamKey || mapString(loader, "pageNum") != strconv.Itoa(page)) {
		return rankingPage{}, failure
	}
	var content hongguoRankingContent
	if inline := nestedMap(loader, "content"); len(inline) > 0 {
		raw, err := json.Marshal(inline)
		if err != nil || json.Unmarshal(raw, &content) != nil {
			return rankingPage{}, failure
		}
	} else if merged, found := parseHongguoMergeLoader(body, loaderKey); found {
		content = merged
	} else {
		for _, tag := range rankingScriptTags.FindAllString(body, -1) {
			if extractAttr(tag, "data-fn-name") != "r" || extractAttr(tag, "data-script-src") != "modern-run-router-data-fn" {
				continue
			}
			var args []json.RawMessage
			if json.Unmarshal([]byte(extractAttr(tag, "data-fn-args")), &args) != nil || len(args) != 3 {
				continue
			}
			var route, field string
			if json.Unmarshal(args[0], &route) != nil || json.Unmarshal(args[1], &field) != nil || route != loaderKey || field != "content" {
				continue
			}
			if json.Unmarshal(args[2], &content) != nil {
				return rankingPage{}, failure
			}
			break
		}
	}
	if !content.Success || content.Rows == nil {
		return parseHongguoRankingDocument(body, board, page, loader)
	}
	if content.Pagination.Page != page || content.Pagination.TotalPages < page || content.Pagination.TotalPages > 500 {
		return rankingPage{}, failure
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(content.Rows)), TotalPages: content.Pagination.TotalPages, HasMore: page < content.Pagination.TotalPages, UpdatedText: mapString(loader, "updatedText")}
	seen := map[string]bool{}
	previous := (page - 1) * 20
	for _, row := range content.Rows {
		id := firstNonEmpty(row.SeriesID, row.ID)
		if !hongguoNumericID.MatchString(id) || row.ID != "" && row.SeriesID != "" && row.ID != row.SeriesID || strings.TrimSpace(row.Title) == "" || row.Rank <= previous || row.Rank > page*20 || seen[id] {
			return rankingPage{}, failure
		}
		seen[id], previous = true, row.Rank
		drama := Drama{ID: providerDramaID(sourceHongguo, id), Source: sourceHongguo, SourceID: id, Title: row.Title, Name: row.Title, Desc: row.Description, Intro: row.Description, Tags: row.Tags, Heat: row.Heat, Score: strings.TrimPrefix(row.Score, "评分"), ChannelName: "红果"}
		if cover := hongguoCoverAddress(coverPathFromAny(row.Cover)); cover != "" {
			drama.Cover, drama.CoverURL = cover, cover
		}
		if len(row.Tags) > 0 {
			drama.CategoryName = row.Tags[0]
		}
		if len(row.EpisodeIDs) > 0 {
			drama.TotalEpisode = len(row.EpisodeIDs)
		}
		result.Items = append(result.Items, rankingItem{Rank: row.Rank, Drama: drama, Metric: row.Heat})
	}
	if len(result.Items) == 0 && result.HasMore {
		return rankingPage{}, failure
	}
	return result, nil
}

func parseHuangdouRanking(decoded any, page int) (rankingPage, error) {
	data := huangdouDataMap(decoded)
	rows, valid := data["list"].([]any)
	if !valid {
		return rankingPage{}, errors.New("黄豆未返回有效榜单")
	}
	if len(rows) > 20 {
		return rankingPage{}, errors.New("黄豆榜单分页格式已变化")
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(rows)), HasMore: len(rows) == 20}
	seen := map[string]bool{}
	for index, value := range rows {
		row, valid := value.(map[string]any)
		id := strings.TrimPrefix(firstNonEmpty(mapString(row, "id"), mapString(row, "drama_id")), "rp_")
		title := mapString(row, "name", "title", "t")
		if !valid || !rankingSourceID.MatchString(id) || strings.TrimSpace(title) == "" || seen[id] {
			return rankingPage{}, errors.New("黄豆榜单包含无效或重复条目")
		}
		seen[id] = true
		drama := huangdouDramaFromMap(row)
		drama.ID, drama.Source, drama.SourceID = providerDramaID(sourceHuangdou, id), sourceHuangdou, id
		metric := ""
		if drama.Heat != "" {
			metric = drama.Heat + "热度"
		}

		result.Items = append(result.Items, rankingItem{Rank: (page-1)*20 + index + 1, Drama: drama, Metric: metric})
	}
	return result, nil
}

func parseHuangguoRanking(body string, board rankingBoard) (rankingPage, error) {
	failure := errors.New("黄果未返回有效榜单，可能是页面结构变化")
	for _, match := range rankingJSONLD.FindAllStringSubmatch(body, -1) {
		var schema struct {
			Graph []struct {
				Type  string `json:"@type"`
				ID    string `json:"@id"`
				Items []struct {
					Position int    `json:"position"`
					Name     string `json:"name"`
					URL      string `json:"url"`
				} `json:"itemListElement"`
			} `json:"@graph"`
		}
		if json.Unmarshal([]byte(match[1]), &schema) != nil {
			continue
		}
		// 统计 ItemList 数量，判断 body 是否"单榜"
		itemListCount := 0
		for _, g := range schema.Graph {
			if g.Type == "ItemList" {
				itemListCount++
			}
		}
		for _, graph := range schema.Graph {
			if graph.Type != "ItemList" {
				continue
			}
			// 路径匹配校验（站点可能改 ranking URL）：
			// 1. 严格匹配 /ranks/{board.path}/#itemlist
			// 2. 包含 board.path
			// 3. board.path 为空（无绑定）
			// 4. body 只有一个 ItemList 且 URL 里含 board.path 的关键片段
			pathMatch := strings.HasSuffix(graph.ID, "/ranks/"+board.path+"/#itemlist") ||
				strings.Contains(graph.ID, "/ranks/"+board.path+"/") ||
				strings.Contains(graph.ID, "/genre/"+board.path+"/") ||
				board.path == "" ||
				(itemListCount == 1 && strings.Contains(graph.ID, board.path))
			if !pathMatch {
				continue
			}
			if len(graph.Items) == 0 || len(graph.Items) > 100 {
				return rankingPage{}, failure
			}
			result := rankingPage{Items: make([]rankingItem, 0, len(graph.Items)), TotalPages: 1}
			seen, previous := map[string]bool{}, 0
			for _, item := range graph.Items {
				parsed, err := url.Parse(item.URL)
				if err != nil || (!strings.HasPrefix(parsed.Path, "/detail/") && !strings.HasPrefix(parsed.Path, "/video/")) {
					return rankingPage{}, failure
				}
				path := strings.TrimPrefix(parsed.Path, "/detail/")
				path = strings.TrimPrefix(path, "/video/")
				id := strings.TrimSuffix(path, "/")
				if !rankingSourceID.MatchString(id) || strings.TrimSpace(item.Name) == "" || item.Position <= previous || seen[id] {
					return rankingPage{}, failure
				}
				seen[id], previous = true, item.Position
				drama := Drama{ID: providerDramaID(sourceHuangguoAI, id), Source: sourceHuangguoAI, SourceID: id, Title: item.Name, Name: item.Name}
				for _, card := range parseHuangguoAIDramaCards(body, item.URL, "") {
					if card.ID == drama.ID {
						drama = card
						break
					}
				}
				result.Items = append(result.Items, rankingItem{Rank: item.Position, Drama: drama})
			}
			return result, nil
		}
	}
	return rankingPage{}, fmt.Errorf("%s: %w", board.Name, failure)
}
