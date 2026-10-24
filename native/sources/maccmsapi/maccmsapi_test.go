package maccmsapi

import (
	"context"
	"encoding/json"
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
