package maccmsapi

import (
	"context"
	"encoding/json"
	"net/url"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

type fakeHost struct {
	address string
	body    string
}

func (f *fakeHost) BaseURL(string) string { return "" }
func (f *fakeHost) Text(ctx context.Context, req provider.Request) (string, error) {
	f.address = req.Address
	return f.body, nil
}
func (f *fakeHost) JSON(ctx context.Context, req provider.Request) (map[string]any, error) {
	return nil, nil
}
func (f *fakeHost) Bytes(ctx context.Context, req provider.Request) ([]byte, error) {
	return nil, nil
}
func (f *fakeHost) MediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	return "", "", nil
}

const catalogFixture = `{"code":1,"msg":"ok","page":1,"pagecount":2,"total":3,"list":[
  {"vod_id":11,"vod_name":"剧甲","type_id":46,"type_name":"短剧","vod_pic":"p1","vod_content":"简介","vod_remarks":"已完结","vod_time":1735660800,"vod_area":"香港","vod_year":"2024","vod_score":"9.2","vod_duration":"45:12"},
  {"vod_id":12,"vod_name":"剧乙","type_id":46,"type_name":"短剧","vod_pic":"p2","vod_content":"","vod_remarks":"第3集","vod_time":0,"vod_area":"内地","vod_year":2025,"vod_score":8.5,"vod_duration":2712},
  {"vod_id":13,"vod_name":"剧丙","type_id":46,"type_name":"短剧","vod_pic":"p3","vod_content":"","vod_remarks":"更新至第16集","vod_time":"2026-10-18 18:04:37"}
]}`

func newTestSource() *Source {
	spec, ok := provider.SpecOf(provider.SourceYingshigongchang)
	if !ok {
		spec = provider.Spec{ID: provider.SourceYingshigongchang, Name: "影视工厂"}
	}
	return New(spec, "46")
}

func TestCatalogPageMapsOnlineDate(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	source := newTestSource()
	items, more, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	if !more {
		t.Fatalf("pagecount=2 时应还有下一页")
	}
	if len(items) != 3 {
		t.Fatalf("期望 3 条，得到 %d", len(items))
	}
	// 1735660800 = 2024-12-31 00:00:00 UTC（本地时区可能偏移，只校验可解析与前缀）。
	if got := items[0].OnlineDate; !strings.HasPrefix(got, "2024-") && !strings.HasPrefix(got, "2025-") {
		t.Fatalf("vod_time 应映射为日期字符串，得到 %q", got)
	}
	// vod_time=0 缺失时应留空，让 Dart 侧保持日期排序置灰语义。
	if got := items[1].OnlineDate; got != "" {
		t.Fatalf("vod_time=0 应映射为空串，得到 %q", got)
	}
	// 字符串日期格式（影视工厂等源站）：截取日期部分。
	if got := items[2].OnlineDate; got != "2026-10-18" {
		t.Fatalf("字符串 vod_time 应解析为 2026-10-18，得到 %q", got)
	}
}

func TestCatalogPageMapsFilterFields(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	source := newTestSource()
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	// 字符串形态原样透传。
	if got := items[0].Area; got != "香港" {
		t.Fatalf("字符串 vod_area 应映射为 %q，得到 %q", "香港", got)
	}
	// 数字形态（年份/评分常见）统一转十进制字符串，供 Dart 侧筛选排序。
	if got := items[1].Year; got != "2025" {
		t.Fatalf("数字 vod_year 应映射为 %q，得到 %q", "2025", got)
	}
	if got := items[1].Score; got != "8.5" {
		t.Fatalf("数字 vod_score 应映射为 %q，得到 %q", "8.5", got)
	}
	// 缺失字段保持空串，Dart 侧据此隐藏/置灰对应筛选项。
	if got := items[2].Area; got != "" {
		t.Fatalf("缺失 vod_area 应为空串，得到 %q", got)
	}
}

func TestCatalogSortedMatchesCatalogPage(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	source := newTestSource()
	base, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	for _, sort := range []string{"date", "heat", "views"} {
		sorted, more, err := source.CatalogPageSorted(context.Background(), host, 1, "", sort)
		if err != nil {
			t.Fatalf("CatalogPageSorted(%q): %v", sort, err)
		}
		if !more {
			t.Fatalf("CatalogPageSorted(%q) 应保留分页标记", sort)
		}
		if len(sorted) != len(base) {
			t.Fatalf("CatalogPageSorted(%q) 条数不一致", sort)
		}
		for i := range base {
			if sorted[i].ID != base[i].ID {
				t.Fatalf("CatalogPageSorted(%q) 顺序应与源站顺序一致", sort)
			}
		}
	}
}

func TestVodActorsSplitsSeparators(t *testing.T) {
	got := vodActors(" 陆之屿 ，白桃、阿蜜/小鹿")
	if len(got) != 4 || got[0] != "陆之屿" || got[3] != "小鹿" {
		t.Fatalf("主演应按分隔符拆分并去空白: %v", got)
	}
	if got := vodActors("  "); got != nil {
		t.Fatalf("空白应返回 nil: %v", got)
	}
	if got := vodActors("甲,,乙"); len(got) != 2 {
		t.Fatalf("空段应丢弃: %v", got)
	}
}

// 「同主演推荐」依赖 vod_actor 进入 Drama.Actors（相关推荐候选链的搜索词）。
func TestCatalogPageMapsActors(t *testing.T) {
	const fixture = `{"code":1,"msg":"ok","page":1,"pagecount":1,"total":1,"list":[
	  {"vod_id":21,"vod_name":"剧丁","type_id":46,"type_name":"短剧","vod_actor":"陆之屿 ，白桃、阿蜜"}
	]}`
	host := &fakeHost{body: fixture}
	source := newTestSource()
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	if got := items[0].Actors; len(got) != 3 || got[0] != "陆之屿" || got[2] != "阿蜜" {
		t.Fatalf("vod_actor 应映射为 Drama.Actors: %v", got)
	}
}

// 短剧/长剧判定依赖单集时长穿过 CatalogPage（>600 秒=长剧，全源统一规则）。
func TestCatalogPageMapsDuration(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	source := newTestSource()
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	if got := items[0].Duration; got != float64(2712) {
		t.Fatalf(`"45:12" 应解析为 2712 秒，得到 %v`, got)
	}
	if got := items[1].Duration; got != float64(2712) {
		t.Fatalf("数字 vod_duration 应为 2712 秒，得到 %v", got)
	}
	if got := items[2].Duration; got != float64(0) {
		t.Fatalf("缺失 vod_duration 应为 0，得到 %v", got)
	}
}

func TestVodDurationSeconds(t *testing.T) {
	cases := []struct {
		raw  string
		want float64
	}{
		{`2712`, 2712},      // 数字秒
		{`"45:12"`, 2712},   // 分:秒
		{`"1:05:30"`, 3930}, // 时:分:秒
		{`null`, 0},         // 裸 null
		{`"null"`, 0},       // 字符串 null
		{`""`, 0},           // 空串
		{`"N/A"`, 0},        // 无效文本
		{`"1:2:3:4"`, 0},    // 超段数
		{`"45:xx"`, 0},      // 段内非数字
	}
	for _, tc := range cases {
		if got := vodDurationSeconds(json.RawMessage(tc.raw)); got != tc.want {
			t.Fatalf("vodDurationSeconds(%s) = %v, want %v", tc.raw, got, tc.want)
		}
	}
}

// 上游 fork 把搜索与目录统一成「带 page+query 的目录请求」。此前视频源
// Search 硬编码 pg=1，而 Dart 白名单声明这些源可分页，上拉会反复拿到第一页。
func TestSearchPageUsesKeywordAndPage(t *testing.T) {
	host := &fakeHost{body: `{"code":1,"page":2,"pagecount":3,"total":48,"list":[{"vod_id":77,"vod_name":"搜索样本"}]}`}
	items, more, err := newTestSource().SearchPage(context.Background(), host, "都市 剧", 2)
	if err != nil {
		t.Fatalf("SearchPage: %v", err)
	}
	want := "&wd=" + url.QueryEscape("都市 剧") + "&pg=2"
	if !strings.Contains(host.address, want) {
		t.Fatalf("搜索地址应携带关键词与页码，want %q in %q", want, host.address)
	}
	if !more {
		t.Fatal("pagecount=3 且当前第 2 页时应还有下一页")
	}
	if len(items) != 1 || items[0].SourceID != "77" {
		t.Fatalf("搜索结果解析异常: %+v", items)
	}
}

func TestSearchPageLastPageHasNoMoreAndEmptyIsNotError(t *testing.T) {
	host := &fakeHost{body: `{"code":0,"msg":"no data","page":3,"pagecount":3,"total":0,"list":[]}`}
	items, more, err := newTestSource().SearchPage(context.Background(), host, "冷门剧", 3)
	if err != nil {
		t.Fatalf("搜索无命中应是空态而非错误: %v", err)
	}
	if len(items) != 0 || more {
		t.Fatalf("末页应返回空且无下一页: items=%d more=%v", len(items), more)
	}
}

// 搜索结果必须与目录条目同构，否则搜索态下评分/地区/年份/时长/题材
// 等筛选排序维度全部拿不到值，短剧与长剧也判不出来。
func TestSearchPageMapsFullMetadata(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	items, _, err := newTestSource().SearchPage(context.Background(), host, "剧", 1)
	if err != nil {
		t.Fatalf("SearchPage: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("期望 3 条，得到 %d", len(items))
	}
	first := items[0]
	if first.Desc != "简介" || first.CategoryName != "短剧" || first.ChannelName != "影视工厂" {
		t.Fatalf("搜索结果缺简介/分类/频道: %+v", first)
	}
	if first.Area != "香港" || first.Year != "2024" || first.Score != "9.2" {
		t.Fatalf("搜索结果缺地区/年份/评分: %+v", first)
	}
	if first.Duration != float64(2712) || first.OnlineDate == "" {
		t.Fatalf("搜索结果缺时长/上线日期: %+v", first)
	}
	if len(items[1].Actors) != 0 {
		t.Fatalf("无主演字段时应为空: %v", items[1].Actors)
	}
}

func TestSearchPageRejectsInvalidKeyword(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	source := newTestSource()
	for _, query := range []string{"", "  ", strings.Repeat("甲", 81), "甲\x00乙"} {
		if _, _, err := source.SearchPage(context.Background(), host, query, 1); err == nil {
			t.Fatalf("非法搜索词 %q 应被拒绝", query)
		}
	}
	if host.address != "" {
		t.Fatalf("非法搜索词不应发出请求，实际: %s", host.address)
	}
}

func TestSearchUsesFirstPage(t *testing.T) {
	host := &fakeHost{body: catalogFixture}
	items, err := newTestSource().Search(context.Background(), host, "剧")
	if err != nil {
		t.Fatalf("Search: %v", err)
	}
	if !strings.Contains(host.address, "pg=1") {
		t.Fatalf("单页搜索应请求第一页: %s", host.address)
	}
	if len(items) != 3 {
		t.Fatalf("期望 3 条，得到 %d", len(items))
	}
}

func TestCatalogURLIncludesCategory(t *testing.T) {
	if got := catalogURL("https://x.com", "46", 3); got != "https://x.com/api.php/provide/vod/?ac=list&t=46&pg=3" {
		t.Fatalf("catalogURL 带分类地址异常: %s", got)
	}
	if got := catalogURL("https://x.com", "", 1); got != "https://x.com/api.php/provide/vod/?ac=list&pg=1" {
		t.Fatalf("catalogURL 全部分类地址异常: %s", got)
	}
}

func TestDetailMapsOnlineDate(t *testing.T) {
	detail := `{"code":1,"msg":"ok","list":[
  {"vod_id":11,"vod_name":"剧甲","type_id":46,"type_name":"短剧","vod_pic":"p1","vod_content":"简介","vod_remarks":"已完结","vod_time":1735660800,"vod_play_from":"ffm3u8","vod_play_url":"第1集$https://a/1.m3u8#第2集$https://a/2.m3u8"}
]}`
	host := &fakeHost{body: detail}
	source := newTestSource()
	drama, chapters, err := source.Detail(context.Background(), host, "11")
	if err != nil {
		t.Fatalf("Detail: %v", err)
	}
	if drama.OnlineDate == "" {
		t.Fatalf("Detail 应映射 vod_time 为 OnlineDate")
	}
	if len(chapters) != 2 {
		t.Fatalf("期望 2 章，得到 %d", len(chapters))
	}
}

func TestDetailDecodesHTMLEntitiesInIntro(t *testing.T) {
	detail := `{"code":1,"msg":"ok","list":[
  {"vod_id":12,"vod_name":"实体样本","type_id":46,"type_name":"短剧","vod_pic":"p1","vod_content":"<p>&nbsp;, &nbsp;地点——Seabrook社区&nbsp;僵尸（zombie）&amp;续作&#39;s</p>","vod_remarks":"已完结","vod_play_from":"ffm3u8","vod_play_url":"第1集$https://a/1.m3u8"}
]}`
	host := &fakeHost{body: detail}
	source := newTestSource()
	drama, _, err := source.Detail(context.Background(), host, "12")
	if err != nil {
		t.Fatalf("Detail: %v", err)
	}
	// vod_content 里的 HTML 实体必须解码成可读文本：字面量 &nbsp; 直接进
	// 简介在播放器里就是「&nbsp;, &nbsp;」乱码（真机实拍实锤）。
	if strings.Contains(drama.Desc, "&nbsp;") || strings.Contains(drama.Desc, "&amp;") || strings.Contains(drama.Desc, "&#39;") {
		t.Fatalf("简介残留 HTML 实体: %q", drama.Desc)
	}
	if strings.ContainsRune(drama.Desc, '\u00a0') {
		t.Fatalf("简介残留不换行空格: %q", drama.Desc)
	}
	if want := ",  地点——Seabrook社区 僵尸（zombie）&续作's"; drama.Desc != want {
		t.Fatalf("简介解码结果不符: got %q want %q", drama.Desc, want)
	}
}
