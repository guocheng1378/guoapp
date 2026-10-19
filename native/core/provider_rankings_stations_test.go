package core

// 站源榜解析测试（自旧 provider_rankings_test.go 迁移：仅保留站源榜部分；
// 缓存/并发/陈旧兜底已由 provider_rankings_douban_test.go 覆盖，测试传输
// 助手在 ranking_test_helpers_test.go）。

import (
	"encoding/json"
	"html"
	"strings"
	"testing"
)

func rankingFixture(board rankingBoard, page int, rows []map[string]any) string {
	key := "rank_" + board.path + "/page"
	loader, _ := json.Marshal(map[string]any{"loaderData": map[string]any{key: map[string]any{"rankKey": board.upstreamKey, "pageNum": page, "updatedText": "9月13日已更新", "content": map[string]any{}}}})
	args, _ := json.Marshal([]any{key, "content", map[string]any{"isSuccess": true, "rankList": rows, "pagination": map[string]int{"pageNum": page, "totalPages": 2}}})
	return "<script>window._ROUTER_DATA=" + string(loader) + "</script><script data-script-src='modern-run-router-data-fn' data-fn-name='r' data-fn-args='" + html.EscapeString(string(args)) + "'></script>"
}

func rankingRows(page int) []map[string]any {
	return []map[string]any{
		{"id": "7681903520873729048", "seriesId": "7681903520873729048", "rank": (page-1)*20 + 1, "title": "甲 & <乙> \"丙\"", "heatText": "1.2亿热度", "episodeVids": []string{"1111111111111111111", "2222222222222222222"}},
		{"id": "7680883072278989849", "seriesId": "7680883072278989849", "rank": (page-1)*20 + 3, "title": "另一部", "heatText": "9000万热度"},
	}
}

func TestHongguoRankingStreamAndValidation(t *testing.T) {
	board, _ := findRankingBoard("hongguo-hot")
	result, err := parseHongguoRanking(rankingFixture(board, 2, rankingRows(2)), board, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 || result.Items[0].Rank != 21 || result.Items[1].Rank != 23 || result.HasMore || result.Items[0].Drama.Title != "甲 & <乙> \"丙\"" {
		t.Fatalf("streamed data lost its rank, title or pagination: %+v", result)
	}
	if result.Items[0].Drama.Views != "" || result.Items[0].Drama.Heat != "1.2亿热度" || result.Items[0].Drama.Cover != nil {
		t.Fatal("heat must stay separate from views, and ranking metadata must have no images")
	}
	for _, test := range []struct {
		name   string
		change func([]map[string]any)
	}{
		{"duplicate ID", func(rows []map[string]any) { rows[1]["id"], rows[1]["seriesId"] = rows[0]["id"], rows[0]["seriesId"] }},
		{"duplicate rank", func(rows []map[string]any) { rows[1]["rank"] = 1 }},
		{"wrong page ranks", func(rows []map[string]any) { rows[0]["rank"] = 21 }},
		{"mismatched ID", func(rows []map[string]any) { rows[0]["id"] = "7777777777777777777" }},
		{"missing title", func(rows []map[string]any) { rows[0]["title"] = "" }},
	} {
		t.Run(test.name, func(t *testing.T) {
			rows := rankingRows(1)
			test.change(rows)
			if _, err := parseHongguoRanking(rankingFixture(board, 1, rows), board, 1); err == nil {
				t.Fatal("accepted invalid upstream ranks")
			}
		})
	}
	other, _ := findRankingBoard("hongguo-ai")
	if _, err := parseHongguoRanking(rankingFixture(other, 1, rankingRows(1)), board, 1); err == nil {
		t.Fatal("accepted a different board")
	}
	if _, err := parseHongguoRanking(rankingFixture(board, 1, rankingRows(1)), board, 2); err == nil {
		t.Fatal("accepted a repeated first page")
	}
	if _, err := parseHongguoRanking(rankingFixture(board, 1, []map[string]any{}), board, 1); err == nil {
		t.Fatal("empty page with hasMore must be treated as a failure")
	}
}

func TestHuangdouRankingPreservesOrderAndMetrics(t *testing.T) {
	rows := []any{
		map[string]any{"id": "rp_first", "name": "低热度先返回", "hot_rate": "20", "click": "100"},
		map[string]any{"id": "second", "name": "高热度后返回", "hot_rate": "1000", "click": "2"},
	}
	result, err := parseHuangdouRanking(map[string]any{"data": map[string]any{"list": rows}}, 2)
	if err != nil {
		t.Fatal(err)
	}
	if len(result.Items) != 2 || result.Items[0].Rank != 21 || result.Items[0].Drama.ID != "huangdou:first" || result.Items[0].Drama.Heat != "20" || result.Items[0].Drama.Views != "100次播放" || result.HasMore {
		t.Fatalf("wrong rank or source metric: %+v", result)
	}
	if _, err := parseHuangdouRanking(map[string]any{"error": "not a list"}, 1); err == nil {
		t.Fatal("an upstream error cannot become an empty successful board")
	}
	result, err = parseHuangdouRanking(map[string]any{"list": []any{}}, 1)
	if err != nil || len(result.Items) != 0 || result.HasMore {
		t.Fatal("explicitly empty lists must be supported")
	}
}

func TestHuangguoRankingStructuredData(t *testing.T) {
	board, _ := findRankingBoard("huangguo-potential")
	// 站点已将 rankings 迁移到分类页 /ai-manju/ 的结构化数据
	body := `<script type="application/ld+json">{"@graph":[{"@type":"BreadcrumbList","itemListElement":[]},{"@type":"ItemList","@id":"https://huangguoai.com/ai-manju/#itemlist","itemListElement":[{"position":1,"name":"A & B","url":"https://huangguoai.com/video/12/"},{"position":3,"name":"第二条","url":"https://huangguoai.com/video/34/"}]}]}</script>`
	result, err := parseHuangguoRanking(body, board)
	if err != nil || len(result.Items) != 2 || result.Items[1].Rank != 3 || result.Items[0].Drama.ID != "huangguoai:12" || result.HasMore {
		t.Fatalf("could not preserve structured site ranks: %+v %v", result, err)
	}
	// 热榜 board path = rebuo-duanju，body @id 里没有它 → 应该拒绝
	other, _ := findRankingBoard("huangguo-hot")
	if _, err := parseHuangguoRanking(body, other); err == nil {
		t.Fatal("accepted a different chart's structured data")
	}
	if _, err := parseHuangguoRanking(strings.ReplaceAll(body, "/video/34/", "/video/12/"), board); err == nil {
		t.Fatal("accepted duplicate IDs")
	}
}

func TestRankingBoardsCoverFourCategories(t *testing.T) {
	// 豆瓣 12 榜 + 站源 22 榜都在册；短剧/视频/黄果三分类各有归属于自己的榜。
	if len(rankingBoards) != 34 {
		t.Fatalf("expected 34 boards, got %d", len(rankingBoards))
	}
	doubanBoards, stationBoards := 0, 0
	for _, board := range rankingBoards {
		if board.Source == sourceDouban {
			doubanBoards++
		} else {
			stationBoards++
		}
	}
	if doubanBoards != 12 || stationBoards != 22 {
		t.Fatalf("expected 12 douban + 22 station boards, got %d + %d", doubanBoards, stationBoards)
	}
	for _, id := range []string{
		"douban-top250", "hongguo-hot", "huangdou-all", "huangguo-hot",
		"huangju-hot", "yeguo-recommend", "dongpiandi-hot", "yingshigongchang-new",
	} {
		if _, ok := findRankingBoard(id); !ok {
			t.Fatalf("board %s missing from registry", id)
		}
	}
	// json 标签回归：Go→Dart 走小写键，缺标签会让 Dart 全读到空值。
	for _, board := range rankingBoards {
		if board.ID == "" || board.Source == "" || board.Name == "" {
			t.Fatalf("board with empty identity: %+v", board)
		}
	}
}
