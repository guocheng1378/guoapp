package core

import (
	"encoding/json"
	"sort"
	"testing"
	"time"
)

// 远端主页 sample：结构取自 2026-10-25 的 /v1/feed/home 真值
// （每帧相当长，这里保留与解析/排序相关的字段）。
const dongpiandiHomeSample = `{
  "object": "home.feed",
  "generated_at": "2026-10-25T02:55:30.525Z",
  "expires_at": "2026-10-25T03:05:30.525Z",
  "period": "day",
  "next_cursor": "eyJzZWN0aW9uX29mZnNldCI6OH0",
  "meta": {"total_sections": 8, "returned_sections": 8, "cards_per_section": 12, "mode": "preview"},
  "sections": [
    {"id":"feed_sec_hot_movie_nowplaying","title":"院线热映","subtitle":"影院正在热映的新片",
     "type":"collection","role":"base","priority":81,"reason":"center_cinema_snapshot:movie_nowplaying",
     "browse":{"label":"查看完整榜单","limit":20,"method":"GET","page":1,"path":"/v1/browse/catalog",
       "type":"catalog_browse_request","params":{"hot_list_key":"movie_nowplaying","include_unavailable":true,"limit":20}},
     "cards":[{"id":"av_now1","title":"生日快乐","content_kind":"movie","remarks":"高清","year":2007,
       "playback_groups":[{"id":"yjplayer","label":"网页播放器","type":"player","episode_count":1}]}]},
    {"id":"feed_sec_everyone_watching","title":"大家都在看","subtitle":"今晚打开就能接上的热播片单",
     "type":"trend","role":"primary","priority":100,"reason":"center_trending",
     "browse":{"label":"查看更多","limit":20,"method":"GET","page":1,"path":"/v1/browse/catalog",
       "type":"catalog_browse_request","params":{"limit":20,"page":1,"sort":"trending","window":"day"}},
     "cards":[{"id":"av_5dhMc","title":"嫁金钗","content_kind":"series","remarks":"更新至17集","year":2026,
       "heat_value":61075.51,"playback_count":627,
       "playback_groups":[{"id":"yjplayer","label":"网页播放器","type":"player","episode_count":31}]}]},
    {"id":"feed_sec_hot_tv_domestic","title":"国产新剧","subtitle":"最近更新的大陆剧放这里",
     "type":"collection","role":"base","priority":88,"reason":"center_hot_list:tv_domestic",
     "browse":{"label":"查看完整榜单","limit":20,"method":"GET","page":1,"path":"/v1/browse/catalog",
       "type":"catalog_browse_request","params":{"hot_list_key":"tv_domestic","limit":20}},
     "cards":[{"id":"av_dom1","title":"小城良方","content_kind":"series","remarks":"更新至10集 / 共29集","year":2026,
       "playback_groups":[{"id":"yjplayer","label":"网页播放器","type":"player","episode_count":29}]}]},
    {"id":"feed_sec_empty","title":"空板块","type":"collection","priority":50,"cards":[]},
    {"id":"feed_sec_no_title","title":"","type":"collection","priority":40,
     "cards":[{"id":"av_anon","title":"无名条目","content_kind":"series"}]}
  ]
}`

func decodeDongpiandiHome(t *testing.T) dongpiandiHomeFeed {
	t.Helper()
	var feed dongpiandiHomeFeed
	if err := json.Unmarshal([]byte(dongpiandiHomeSample), &feed); err != nil {
		t.Fatalf("样例解析失败: %v", err)
	}
	return feed
}

// 区块顺序完全由站点 priority 决定，本地不重排；空/无标题区块剔除。
func TestDongpiandiHomeSectionsPriority(t *testing.T) {
	sections := dongpiandiHomeSections(decodeDongpiandiHome(t))
	if len(sections) != 3 {
		t.Fatalf("有效区块=%d 期望 3（空板块与无标题板块应剔除）", len(sections))
	}
	want := []string{"feed_sec_everyone_watching", "feed_sec_hot_tv_domestic", "feed_sec_hot_movie_nowplaying"}
	for index, id := range want {
		if sections[index].ID != id {
			t.Fatalf("第%d块=%s 期望 %s（顺序必须按站点 priority 降序）", index+1, sections[index].ID, id)
		}
	}
	if sections[0].Priority != 100 || sections[0].Role != "primary" {
		t.Fatalf("首块 priority=%d role=%s 期望 100/primary", sections[0].Priority, sections[0].Role)
	}
}

// 站点给多少就显示多少：新增/删除区块后数量随之变化，本地没有写死数量。
func TestDongpiandiHomeSectionCountFollowsSite(t *testing.T) {
	feed := decodeDongpiandiHome(t)
	if got := len(dongpiandiHomeSections(feed)); got != 3 {
		t.Fatalf("本次=%d 期望 3", got)
	}
	// 站点再发一个区块：App 侧应多出一块（按 priority 插到 88 与 81 之间）。
	extra := dongpiandiHomeSection{
		ID:       "feed_sec_hot_tv_korean",
		Title:    "韩剧在追",
		Subtitle: "从新集开始追也不费劲",
		Type:     "collection",
		Role:     "base",
		Priority: 90,
		Cards:    []dongpiandiCatalogCard{{ID: "av_kr1", Title: "现在不是出轨的问题"}},
		Browse: dongpiandiBrowseRequest{
			Label: "查看完整榜单", Method: "GET", Path: "/v1/browse/catalog", Limit: 20,
			Params: map[string]any{"hot_list_key": "tv_korean", "limit": 20},
		},
	}
	feed.Sections = append(feed.Sections, extra)
	sections := dongpiandiHomeSections(feed)
	if len(sections) != 4 {
		t.Fatalf("新增区块后=%d 期望 4", len(sections))
	}
	if sections[1].ID != extra.ID {
		t.Fatalf("第2块=%s 期望 %s（priority=90 应排在 88 前）", sections[1].ID, extra.ID)
	}
	// 删掉后回落 3
	kept := feed.Sections[:len(feed.Sections)-1]
	feed.Sections = kept
	if got := len(dongpiandiHomeSections(feed)); got != 3 {
		t.Fatalf("删除区块后=%d 期望 3", got)
	}
}

// 「查看更多」的取数参数必须原样透传（含布尔 include_unavailable），
// 只覆盖 page/limit。
func TestDongpiandiBrowseQueryPassthrough(t *testing.T) {
	sections := dongpiandiHomeSections(decodeDongpiandiHome(t))
	cases := []struct {
		id    string
		want  map[string]string
		limit int
	}{
		{"feed_sec_hot_tv_domestic", map[string]string{"hot_list_key": "tv_domestic", "limit": "20"}, 20},
		{"feed_sec_hot_movie_nowplaying", map[string]string{"hot_list_key": "movie_nowplaying", "include_unavailable": "true", "limit": "20"}, 20},
		{"feed_sec_everyone_watching", map[string]string{"sort": "trending", "window": "day", "limit": "20", "page": "1"}, 20},
	}
	for _, c := range cases {
		t.Run(c.id, func(t *testing.T) {
			section := findDongpiandiHomeSection(sections, c.id)
			if section == nil {
				t.Fatalf("找不到区块 %s", c.id)
			}
			if section.Browse.Limit != c.limit {
				t.Fatalf("limit=%d 期望 %d", section.Browse.Limit, c.limit)
			}
			q := dongpiandiBrowseQuery(section.Browse)
			got := map[string]string{}
			for key := range q {
				got[key] = q.Get(key)
			}
			for key, want := range c.want {
				if got[key] != want {
					t.Fatalf("参数 %s=%q 期望 %q（全量=%v）", key, got[key], want, got)
				}
			}
		})
	}
}

// 站点没给 expires_at（或缺字段）时用默认 10 分钟，不能永久缓存。
func TestDongpiandiHomeExpiry(t *testing.T) {
	if _, err := time.Parse(time.RFC3339, "2026-10-25T03:05:30.525Z"); err != nil {
		t.Fatalf("时间戳格式假设不成立: %v", err)
	}
	parsed := dongpiandiHomeExpiry("2026-10-25T03:05:30.525Z")
	if parsed.IsZero() || parsed.Year() != 2026 {
		t.Fatalf("解析站点过期时间失败: %v", parsed)
	}
	if fallback := dongpiandiHomeExpiry(""); time.Until(fallback) > dongpiandiHomeDefaultTTL+time.Minute {
		t.Fatalf("缺省兜底=%v 应约等于 %v", time.Until(fallback), dongpiandiHomeDefaultTTL)
	}
}

// 板块列表为空也不应崩：上面的 filter 保证 UI 侧不会拿到空壳板块。
func TestDongpiandiHomeSectionsAllEmpty(t *testing.T) {
	empty := dongpiandiHomeFeed{}
	if got := len(dongpiandiHomeSections(empty)); got != 0 {
		t.Fatalf("空主页=%d 期望 0", got)
	}
	// 排序稳定性：同 priority 时保持站点原顺序
	tie := dongpiandiHomeFeed{Sections: []dongpiandiHomeSection{
		{ID: "a", Title: "A", Priority: 10, Cards: []dongpiandiCatalogCard{{Title: "1"}}},
		{ID: "b", Title: "B", Priority: 10, Cards: []dongpiandiCatalogCard{{Title: "2"}}},
	}}
	got := dongpiandiHomeSections(tie)
	if len(got) != 2 || got[0].ID != "a" || got[1].ID != "b" {
		t.Fatalf("同优先级应保持站点原序，实际=%v", []string{got[0].ID, got[1].ID})
	}
	ids := make([]string, 0, len(got))
	for _, s := range got {
		ids = append(ids, s.ID)
	}
	if !sort.StringsAreSorted(ids) {
		t.Logf("（信息）同序不需要字典序，实际=%v", ids)
	}
}
