package core

import (
	"encoding/json"
	"fmt"
	"testing"
)

// 追剧周表 sample：结构取自 2026-10-25 的 /v1/watch-calendar 真值
// （title=追剧周表，每天按 content_kind 分组，条目 id 即 variant_id）。
const dongpiandiCalendarSample = `{
  "title": "追剧周表",
  "schedule_mode": "weekday_only",
  "categories": [
    {"key":"all","label":"全部"},
    {"key":"series","label":"电视剧"},
    {"key":"anime","label":"动漫"},
    {"key":"variety","label":"综艺"},
    {"key":"movie","label":"电影"}
  ],
  "days": [
    {"date":"2026-10-21","groups":{
      "anime":{"more_url":"/v1/watch-calendar?kind=anime&weekday=3","preview":[
        {"id":"av_anon","title":"缺ID条目","content_kind":"anime"}]},
      "series":{"preview":[
        {"id":"av_jin","variant_id":"av_jin","title":"嫁金钗","content_kind":"series",
         "poster_url":"https://img/jin.webp","latest_episode_label":"更新至第14集",
         "heat_score":331.92,"forecast":{"label":"当日新增","kind":"actual","confidence":"high"}},
        {"id":"","variant_id":"","title":"无ID条目","content_kind":"series","latest_episode_label":"更新至第2集"}]}
    }},
    {"date":"2026-10-19","groups":{
      "series":{"preview":[
        {"id":"av_jin","variant_id":"av_jin","title":"嫁金钗","content_kind":"series",
         "poster_url":"https://img/jin.webp",
         "latest_episode_label":"更新至第10集","heat_score":331.92},
        {"id":"av_mei","title":"美人余","content_kind":"series","latest_episode_label":"全28集"}]},
      "variety":{"preview":[
        {"id":"av_chu","title":"现在就出发 第4季","content_kind":"variety","season_label":"第4季",
         "latest_episode_label":"更新至2026-10-19 第2期 加更"}]},
      "movie":{"preview":[
        {"id":"av_bao","title":"生化危机:爆发夜","content_kind":"movie","latest_episode_label":"资源更新"}]}
    }},
    {"date":"","groups":{"series":{"preview":[{"id":"av_x","title":"无日期","content_kind":"series"}]}}},
    {"date":"2026-10-20","groups":{}}
  ],
  "snapshot":{"generated_at":"2026-10-25T03:52:06.396Z","week_start_date":"2026-10-19"}
}`

func decodeDongpiandiCalendar(t *testing.T) dongpiandiCalendarResp {
	t.Helper()
	var resp dongpiandiCalendarResp
	if err := json.Unmarshal([]byte(dongpiandiCalendarSample), &resp); err != nil {
		t.Fatalf("样例解析失败: %v", err)
	}
	return resp
}

// 周表按日期升序、星期标签由日期推出；空天与无日期的天直接剔除。
func TestDongpiandiCalendarDaysOrder(t *testing.T) {
	days := dongpiandiCalendarDays(decodeDongpiandiCalendar(t))
	if len(days) != 2 {
		t.Fatalf("有效天=%d 期望 2（无日期的天与空天应剔除）", len(days))
	}
	if days[0].Date != "2026-10-19" || days[0].Label != "周一" {
		t.Fatalf("首天=%s/%s 期望 2026-10-19/周一", days[0].Date, days[0].Label)
	}
	if days[1].Date != "2026-10-21" || days[1].Label != "周三" {
		t.Fatalf("次日=%s/%s 期望 2026-10-21/周三", days[1].Date, days[1].Label)
	}
}

// 条目归一：分类名用站点 categories 的 label，ID 取 variant id（与目录
// 卡片同构，详情页 /v1/catalog/{id} 可直接命中），无 ID 的条目丢弃。
func TestDongpiandiCalendarItemsNormalized(t *testing.T) {
	days := dongpiandiCalendarDays(decodeDongpiandiCalendar(t))
	first := days[0]
	if len(first.Items) != 4 {
		t.Fatalf("首天条目=%d 期望 4（无 ID 条目应剔除）", len(first.Items))
	}
	jin := first.Items[0]
	// ID 要带源前缀（Dart 靠它认站源，裸 id 会被当成「不包含此站源」），
	// SourceID 留裸 variant id 供 /v1/catalog/{id} 请求。
	if jin.ID != providerDramaID(sourceDongpiandi, "av_jin") ||
		jin.SourceID != "av_jin" ||
		jin.Source != sourceDongpiandi ||
		jin.Title != "嫁金钗" {
		t.Fatalf("条目 id=%s sourceId=%s source=%s title=%s 期望带前缀的 av_jin/真果·鉴",
			jin.ID, jin.SourceID, jin.Source, jin.Title)
	}
	if jin.Category != "电视剧" {
		t.Fatalf("分类=%q 期望站点 label「电视剧」", jin.Category)
	}
	if jin.Remark != "更新至第10集" || fmt.Sprint(jin.EpisodeCount) != "10" {
		t.Fatalf("进度=%q 集数=%v 期望「更新至第10集」/10", jin.Remark, jin.EpisodeCount)
	}
	if jin.ReleaseStatus != "ongoing" {
		t.Fatalf("状态=%q 期望 ongoing（更新至=连载）", jin.ReleaseStatus)
	}
	if jin.Cover != "https://img/jin.webp" {
		t.Fatalf("封面=%v 期望站点 poster_url", jin.Cover)
	}

	finished := first.Items[1]
	if fmt.Sprint(finished.EpisodeCount) != "28" || finished.ReleaseStatus != "finished" {
		t.Fatalf("完结条目 集数=%v 状态=%q 期望 28/finished", finished.EpisodeCount, finished.ReleaseStatus)
	}
	// 综艺：进度文案里带日期，「第N期」才是集数，不能误取年份 2026。
	variety := first.Items[2]
	if fmt.Sprint(variety.EpisodeCount) != "2" {
		t.Fatalf("综艺集数=%v 期望 2（取「第2期」，不是年份）", variety.EpisodeCount)
	}
	if len(variety.Tags) == 0 || variety.Tags[0] != "综艺" {
		t.Fatalf("综艺标签=%v 期望首位「综艺」", variety.Tags)
	}
	// 电影「资源更新」没有集数：留空而不是编一个。
	if movie := first.Items[3]; movie.EpisodeCount != nil {
		t.Fatalf("电影集数=%v 期望空（「资源更新」不含集数）", movie.EpisodeCount)
	}
}

// 站点给多少天就显示多少天（不写死 7 天），同一天多分类时顺序稳定。
func TestDongpiandiCalendarCountFollowsSite(t *testing.T) {
	resp := decodeDongpiandiCalendar(t)
	if got := len(dongpiandiCalendarDays(resp)); got != 2 {
		t.Fatalf("本次=%d 期望 2", got)
	}
	resp.Days = append(resp.Days, struct {
		Date   string                             `json:"date"`
		Groups map[string]dongpiandiCalendarGroup `json:"groups"`
	}{
		Date: "2026-10-22",
		Groups: map[string]dongpiandiCalendarGroup{
			"series": {Preview: []dongpiandiCalendarItem{
				{ID: "av_new", Title: "新剧", ContentKind: "series", LatestEpisodeLabel: "更新至第1集"},
			}},
		},
	})
	days := dongpiandiCalendarDays(resp)
	if len(days) != 3 {
		t.Fatalf("新增一天后=%d 期望 3", len(days))
	}
	if days[2].Date != "2026-10-22" || days[2].Items[0].SourceID != "av_new" {
		t.Fatalf("新增天=%s/%v 期望 2026-10-22/av_new", days[2].Date, days[2].Items)
	}
}

// 集数解析只认明确形态：日期里的年份、电影的「资源更新」都不能被当成集数。
func TestDongpiandiCalendarEpisode(t *testing.T) {
	cases := []struct {
		label string
		want  int
	}{
		{"更新至第17集", 17},
		{"全28集", 28},
		{"更新至2026-10-19 第2期 加更", 2},
		{"更新至20261019集结篇", 0},
		{"资源更新", 0},
		{"", 0},
	}
	for _, item := range cases {
		if got := dongpiandiCalendarEpisode(item.label); got != item.want {
			t.Fatalf("文案%q 集数=%d 期望 %d", item.label, got, item.want)
		}
	}
}

func TestDongpiandiWeekdayLabel(t *testing.T) {
	cases := map[string]string{
		"2026-10-19": "周一",
		"2026-10-20": "周二",
		"2026-10-25": "周日",
		"":           "",
		"不是日期":       "",
	}
	for date, want := range cases {
		if got := dongpiandiWeekdayLabel(date); got != want {
			t.Fatalf("%s -> %q 期望 %q", date, got, want)
		}
	}
}
