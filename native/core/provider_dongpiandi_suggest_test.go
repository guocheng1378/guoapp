package core

// 真果·鉴站内搜索建议（/v1/suggest）测试。

import (
	"context"
	"testing"
)

func TestFetchDongpiandiSuggest(t *testing.T) {
	fixture := `{"object":"movie.suggestions","query":"总裁复仇","suggestions":[
		{"id":"s1","type":"title","intent":"play","label":"复仇后被霸道总裁宠上天","subtitle":"2024 · 短剧","prompt":"复仇后被霸道总裁宠上天",
		 "target":{"variant_id":"av_qSAOsL","title":"复仇后被霸道总裁宠上天","direct_playable":true},
		 "action":{"type":"submit_prompt","prompt":"复仇后被霸道总裁宠上天"}},
		{"id":"r1","type":"action","intent":"filter","label":"总裁复仇 电影","subtitle":"只看电影版","prompt":"总裁复仇 电影",
		 "action":{"type":"submit_prompt","prompt":"总裁复仇 电影"}},
		{"id":"s3","type":"title","intent":"play","label":"逆命绝宠","subtitle":"2026 · 短剧",
		 "target":{"variant_id":"av_M8sr1j","title":"逆命绝宠","direct_playable":false}},
		{"id":"s4","type":"title","intent":"play","label":"","subtitle":"空标签"},
		{"id":"s5","type":"title","intent":"play","label":"复仇后被霸道总裁宠上天","subtitle":"重复项"}
	]}`
	client := dongpiandiStubClient(fixture)
	d := &Downloader{}
	items, err := d.fetchDongpiandiSuggest(context.Background(), client, "总裁复仇", 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 3 {
		t.Fatalf("want 3 items (dedup+empty filtered), got %d: %+v", len(items), items)
	}
	first := items[0]
	if first.Label != "复仇后被霸道总裁宠上天" || first.Intent != "play" || first.Subtitle != "2024 · 短剧" {
		t.Fatalf("first item wrong: %+v", first)
	}
	if first.VariantID != "av_qSAOsL" || !first.DirectPlayable {
		t.Fatalf("direct play target lost: %+v", first)
	}
	if first.Prompt != "复仇后被霸道总裁宠上天" {
		t.Fatalf("prompt wrong: %+v", first)
	}
	// 筛选类建议无 target
	if items[1].Intent != "filter" || items[1].VariantID != "" || items[1].DirectPlayable {
		t.Fatalf("filter suggestion wrong: %+v", items[1])
	}
	// direct_playable=false 不标记直达
	if items[2].VariantID != "av_M8sr1j" || items[2].DirectPlayable {
		t.Fatalf("non-playable target wrong: %+v", items[2])
	}
}

func TestFetchDongpiandiSuggestLimit(t *testing.T) {
	rows := ""
	for i := 0; i < 12; i++ {
		if i > 0 {
			rows += ","
		}
		rows += `{"id":"s` + string(rune('a'+i)) + `","type":"title","intent":"play","label":"剧` + string(rune('a'+i)) + `","prompt":"p"}`
	}
	client := dongpiandiStubClient(`{"object":"movie.suggestions","suggestions":[` + rows + `]}`)
	d := &Downloader{}
	items, err := d.fetchDongpiandiSuggest(context.Background(), client, "剧", 5)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 5 {
		t.Fatalf("limit not applied: %d", len(items))
	}
}

func TestFetchDongpiandiSuggestRejects(t *testing.T) {
	d := &Downloader{}
	client := dongpiandiStubClient(`{"object":"movie.suggestions","suggestions":[]}`)
	if _, err := d.fetchDongpiandiSuggest(context.Background(), client, "   ", 8); err == nil {
		t.Fatal("empty query accepted")
	}
	items, err := d.fetchDongpiandiSuggest(context.Background(), client, "无结果", 8)
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 0 {
		t.Fatalf("want empty, got %+v", items)
	}
	// 非 JSON 响应报错
	bad := dongpiandiStubClient("<html>网关页</html>")
	if _, err := d.fetchDongpiandiSuggest(context.Background(), bad, "x", 8); err == nil {
		t.Fatal("bad payload accepted")
	}
}
