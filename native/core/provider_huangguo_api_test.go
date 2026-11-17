package core

import (
	"context"
	"encoding/json"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"golang.org/x/net/html"
)

type huangguoEdgeEnvelope struct {
	Method      string `json:"method"`
	Path        string `json:"path"`
	Body        string `json:"body"`
	ContentType string `json:"content_type"`
}

// parseHuangguoEdgeEnvelope 从 POST /api/edge/request 的 JSON 信封里取出
// 转发方法与真实接口地址，供所有「站点接口」类夹具复用；任何绕过 edge
// 的请求都会被判失败。播放地址接口是 POST（目录/详情/搜索是 GET）。
func parseHuangguoEdgeEnvelope(t *testing.T, request *http.Request) (huangguoEdgeEnvelope, *url.URL) {
	t.Helper()
	var envelope huangguoEdgeEnvelope
	if request.Method != http.MethodPost || request.URL.Path != "/api/edge/request" ||
		json.NewDecoder(request.Body).Decode(&envelope) != nil ||
		(envelope.Method != http.MethodGet && envelope.Method != http.MethodPost) {
		t.Errorf("request bypassed the edge envelope: %s %s", request.Method, request.URL)
		return envelope, &url.URL{}
	}
	// edge 转发 POST 时服务端自行构造请求体，非空 body 会直接 400。
	if envelope.Method == http.MethodPost && (envelope.Body != "" || envelope.ContentType != "") {
		t.Errorf("POST edge envelope must keep body/content_type empty: %+v", envelope)
	}
	target, err := url.Parse(envelope.Path)
	if err != nil {
		t.Errorf("invalid envelope path %q", envelope.Path)
		return envelope, &url.URL{}
	}
	return envelope, target
}

func huangguoEdgeTarget(t *testing.T, request *http.Request) *url.URL {
	_, target := parseHuangguoEdgeEnvelope(t, request)
	return target
}

func huangguoEdgeReply(data any) string {
	body, _ := json.Marshal(map[string]any{"status": 1, "msg": "", "data": data})
	return string(body)
}

// huangguoHealthEdgeResponse 给站源健康检测夹具提供目录/详情/播放三段接口应答。
func huangguoHealthEdgeResponse(t *testing.T, request *http.Request) (*http.Response, bool) {
	if request.URL.Path != "/api/edge/request" {
		return nil, false
	}
	target := huangguoEdgeTarget(t, request)
	card := map[string]any{
		"id": "fixture", "title": "合成检测剧", "description": "合成简介",
		"cover": "https://example.test/cover", "episode_count": 1,
	}
	switch {
	case strings.HasPrefix(target.Path, "/api/videos/category/"):
		return sourceFixtureResponse(request, 200, huangguoEdgeReply([]any{card})), true
	case strings.HasSuffix(target.Path, "/playback"):
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
			"streams": map[string]any{"main": "https://media.example.test/master.m3u8"},
		})), true
	case strings.HasPrefix(target.Path, "/api/videos/"):
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
			"id": "fixture", "title": "合成检测剧", "description": "合成简介",
			"episodes": []any{map[string]any{"ep_num": 1, "title": "第1集"}},
		})), true
	}
	return sourceFixtureResponse(request, 200, `{"status":0,"msg":"unexpected edge path"}`), true
}

// edgeFixtureDownloader 把站源根地址指向一个不被 hostIndex 识别的假域，
// 这样 providerURLCandidates 只产生一个候选，夹具不会收到镜像轮换请求。
func edgeFixtureDownloader(t *testing.T, transport sourceFixtureTransport) *Downloader {
	t.Helper()
	d := sourceFixtureDownloader(t, transport)
	d.cfg.HuangguoAIURL = "https://huangguoai.test"
	return d
}

func TestHuangguoAIDetailAndPlaybackUseEdgeAPI(t *testing.T) {
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		envelope, target := parseHuangguoEdgeEnvelope(t, request)
		switch target.Path {
		case "/api/videos/12":
			return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
				"id": 12, "title": "合成剧", "description": "合成简介", "cover": "/covers/12.jpg",
				"episodes": []any{
					map[string]any{"ep_num": 2, "title": "第2集"},
					map[string]any{"ep_num": 1, "title": ""},
				},
			})), nil
		case "/api/videos/12/episodes/2/playback":
			if envelope.Method != http.MethodPost {
				t.Errorf("playback must be a POST edge envelope, got %s", envelope.Method)
			}
			return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
				"streams": map[string]any{"main": "https://media.example.test/12/2.mp4?auth_key=synthetic"},
			})), nil
		}
		return sourceFixtureResponse(request, 200, `{"status":0,"msg":"合成剧集不存在"}`), nil
	})
	drama, chapters, err := d.fetchHuangguoAIDetail(context.Background(), "12")
	if err != nil || drama.ID != "huangguoai:12" || drama.Title != "合成剧" || drama.Desc != "合成简介" {
		t.Fatal("detail metadata was not read from the API", err, drama)
	}
	// 分集 ID 沿用旧网页解析版的纯数字 key，追剧/下载记录不失效。
	if len(chapters) != 2 || chapters[0].ID != "huangguoai:12:1" || chapters[1].ID != "huangguoai:12:2" {
		t.Fatal("chapter identities changed", chapters)
	}
	media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: drama.ID, Chapter: chapters[1], Index: 2})
	if err != nil || media.URL != "https://media.example.test/12/2.mp4?auth_key=synthetic" {
		t.Fatal("playback did not use the play API", err, media.URL)
	}
	if _, _, err := d.fetchHuangguoAIDetail(context.Background(), "13"); err == nil || !strings.Contains(err.Error(), "合成剧集不存在") {
		t.Fatal("upstream failure message was discarded", err)
	}
}

// 站点若把播放接口回滚成旧的 GET /play（video_url 非空），仍要能出地址：
// 新版接口整批失效时不能让整源直接变成「无法观看」。
func TestHuangguoAIPlaybackFallsBackToLegacyPlay(t *testing.T) {
	var sawPlayback bool
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		envelope, target := parseHuangguoEdgeEnvelope(t, request)
		switch target.Path {
		case "/api/videos/12/episodes/2/playback":
			if envelope.Method != http.MethodPost {
				t.Errorf("playback must be a POST edge envelope, got %s", envelope.Method)
			}
			sawPlayback = true
			return sourceFixtureResponse(request, 200, `{"status":0,"msg":"播放接口暂不可用"}`), nil
		case "/api/videos/12/play":
			if target.Query().Get("ep") != "2" {
				t.Errorf("legacy fallback requested the wrong episode: %s", target)
			}
			return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
				"video_url": "https://media.example.test/legacy/2.m3u8",
			})), nil
		}
		return sourceFixtureResponse(request, 200, `{"status":0,"msg":"unexpected edge path"}`), nil
	})
	address, err := d.fetchHuangguoAIPlayURL(context.Background(), "12", 2)
	if err != nil || address != "https://media.example.test/legacy/2.m3u8" || !sawPlayback {
		t.Fatal("legacy play fallback failed", err, address, sawPlayback)
	}
}

func TestHuangguoAISearchAndRankingUseEdgeAPI(t *testing.T) {
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		target := huangguoEdgeTarget(t, request)
		switch target.Path {
		case "/api/search":
			page, _ := strconv.Atoi(target.Query().Get("page"))
			return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
				"items":      []any{map[string]any{"id": 50 + page, "title": "合成结果" + strconv.Itoa(page)}},
				"pagination": map[string]any{"pages": 2},
			})), nil
		case "/api/ranks/hot":
			return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
				"items": []any{map[string]any{
					"video_id": 2833, "title": "榜首剧", "cover": "https://example.test/p.jpg",
					"cate_name": "AI成人短剧", "rank": 1, "metric_label": "热力指数", "metric_value": 32601694,
				}},
			})), nil
		}
		return sourceFixtureResponse(request, 200, `{"status":0,"msg":"unexpected path"}`), nil
	})
	items, more, err := d.searchHuangguoAI(context.Background(), 1, "合成 关键词")
	if err != nil || len(items) != 1 || items[0].ID != "huangguoai:51" || !more {
		t.Fatal("site search pagination failed", err, items, more)
	}
	items, more, err = d.searchHuangguoAI(context.Background(), 2, "合成 关键词")
	if err != nil || len(items) != 1 || items[0].ID != "huangguoai:52" || more {
		t.Fatal("search ignored the site total", err, items, more)
	}
	var ranking struct {
		Items []map[string]any `json:"items"`
	}
	if err := d.huangguoAIAPI(context.Background(), "/api/ranks/hot", &ranking); err != nil {
		t.Fatal(err)
	}
	page, err := parseHuangguoAIAPIRanking(ranking.Items, "https://huangguoai.test/")
	if err != nil || len(page.Items) != 1 || page.Items[0].Drama.ID != "huangguoai:2833" || !strings.Contains(page.Items[0].Metric, "万") {
		t.Fatal("ranking was not parsed from the API", err, page)
	}
	if huangguoRankingAPIPath("ranks/hot") != "hot" || huangguoRankingAPIPath("ai-duanju") != "recommend" || huangguoRankingAPIPath("ai-manju") != "potential" {
		t.Fatal("ranking board path mapping changed")
	}
}

func TestHeitaoRouteAndPlayerConfig(t *testing.T) {
	base := "https://heitaodj.com/index.php/vod/show.html"
	for _, test := range []struct {
		href   string
		action string
		id     string
		page   string
	}{
		{"/index.php/vod/type/id/1.html", "type", "1", ""},
		{"/index.php/vod/detail/id/1150.html", "detail", "1150", ""},
		{"https://heitaodj.com/index.php/vod/show/id/1/page/2.html", "show", "1", "2"},
	} {
		action, values, ok := heitaoRouteParameters(base, test.href)
		if !ok || action != test.action || values["id"] != test.id || values["page"] != test.page {
			t.Fatalf("route %s parsed as %s %v (ok=%v)", test.href, action, values, ok)
		}
	}
	if _, _, ok := heitaoRouteParameters(base, "https://evil.test/index.php/vod/detail/id/1.html"); ok {
		t.Fatal("cross-site link accepted")
	}
	if !validHeitaoCategory("17") || validHeitaoCategory("../etc") {
		t.Fatal("category validation regressed")
	}

	config := `<script>var player_aaaa={"encrypt":0,"url":"https:\/\/play.example.test\/a\/index.m3u8"};</script>`
	entry, err := heitaoReadPlayerConfig(config)
	if err != nil || entry.URL != "https://play.example.test/a/index.m3u8" {
		t.Fatal("player config not parsed", err, entry)
	}
	if _, err := heitaoReadPlayerConfig(`<div id="heitao-age-gate"></div>`); err == nil {
		t.Fatal("age gate was accepted as player config")
	}
	if _, _, ok := heitaoPlayerID("/index.php/vod/player/id/1148/nid/3/sid/1.html"); !ok {
		t.Fatal("player route not recognized")
	}
	if address, err := heitaoDecryptMediaURL("https%3A%2F%2Fplay.example.test%2Fa.m3u8", 1); err != nil || address != "https://play.example.test/a.m3u8" {
		t.Fatal("media URL not decoded", err, address)
	}

	markup := `<a class="thumb" href="/index.php/vod/detail/id/1150.html" title="黑桃剧"><img src="/cover.jpg"/><span class="label">8集</span></a>`
	document, err := html.Parse(strings.NewReader(markup))
	if err != nil {
		t.Fatal(err)
	}
	cards := parseHeitaoCards(document, base)
	if len(cards) != 1 || cards[0].Source != sourceHeitao || cards[0].ID != "heitao:1150" || cards[0].EpisodeCount != 8 {
		t.Fatal("heitao card parsing failed", cards)
	}
}
