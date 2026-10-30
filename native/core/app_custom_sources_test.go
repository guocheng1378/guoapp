package core

import (
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

func customSourceEntry(id, name, url string) map[string]any {
	return map[string]any{
		"id":   id,
		"name": name,
		"url":  url,
	}
}

func clearCustomSources() {
	_, _ = applyCustomSources([]any{})
}

func TestApplyCustomSourcesRegistersAndUnregisters(t *testing.T) {
	t.Cleanup(clearCustomSources)
	ids, err := applyCustomSources([]any{
		customSourceEntry("custom-aaaa1111", "测试源A", "https://a.example.com"),
		customSourceEntry("custom-bbbb2222", "测试源B", "http://b.example.com/"),
	})
	if err != nil {
		t.Fatalf("注册自定义源失败: %v", err)
	}
	if len(ids) != 2 {
		t.Fatalf("applied ids = %v, want 2 entries", ids)
	}
	spec, found := provider.SpecOf("custom-aaaa1111")
	if !found {
		t.Fatal("custom-aaaa1111 must be registered after apply")
	}
	if spec.Name != "测试源A" {
		t.Fatalf("spec name = %q, want 测试源A", spec.Name)
	}
	if spec.Base != "https://a.example.com" {
		t.Fatalf("spec base = %q, want trailing slash trimmed", spec.Base)
	}
	if spec.Category != provider.CategoryShortDrama {
		t.Fatalf("default category = %q, want shortDrama", spec.Category)
	}
	if spec.Family != provider.FamilyDuanju {
		t.Fatalf("custom family = %q, want duanju", spec.Family)
	}
	if spec.RequiresAllSources {
		t.Fatal("custom sources must skip the all-sources gate")
	}
	if !provider.Available("custom-aaaa1111") {
		t.Fatal("custom source must be available regardless of variant")
	}
	if !provider.KnownSource("custom-bbbb2222") {
		t.Fatal("custom-bbbb2222 must be registered")
	}
	if _, isCataloguer := provider.Get("custom-aaaa1111"); !isCataloguer {
		t.Fatal("registered custom source must be retrievable")
	}

	// 同 ID 重发 = 更新（名称/地址覆盖），不产生重复。
	if _, err := applyCustomSources([]any{
		customSourceEntry("custom-aaaa1111", "测试源A改", "https://a2.example.com"),
	}); err != nil {
		t.Fatalf("re-apply failed: %v", err)
	}
	spec, _ = provider.SpecOf("custom-aaaa1111")
	if spec.Name != "测试源A改" || spec.Base != "https://a2.example.com" {
		t.Fatalf("re-apply must overwrite spec, got %+v", spec)
	}
	if provider.KnownSource("custom-bbbb2222") {
		t.Fatal("source dropped from the list must be unregistered")
	}

	// 空列表 = 清空全部自定义源。
	if _, err := applyCustomSources([]any{}); err != nil {
		t.Fatalf("clear failed: %v", err)
	}
	if provider.KnownSource("custom-aaaa1111") {
		t.Fatal("empty list must unregister every custom source")
	}
}

func TestApplyCustomSourcesRejectsInvalidEntries(t *testing.T) {
	t.Cleanup(clearCustomSources)
	cases := []struct {
		label string
		list  []any
	}{
		{"URL 非法", []any{customSourceEntry("custom-aaaa1111", "测试源", "ftp://x.example.com")}},
		{"URL 缺 host", []any{customSourceEntry("custom-aaaa1111", "测试源", "https://")}},
		{"ID 非 custom 前缀", []any{customSourceEntry("hongguo", "冒充红果", "https://a.example.com")}},
		{"ID 模式非法", []any{customSourceEntry("custom-大写AB", "测试源", "https://a.example.com")}},
		{"ID 过短", []any{customSourceEntry("custom-a1", "测试源", "https://a.example.com")}},
		{"名称为空", []any{customSourceEntry("custom-aaaa1111", "   ", "https://a.example.com")}},
		{"名称过长", []any{customSourceEntry("custom-aaaa1111", strings.Repeat("名", 33), "https://a.example.com")}},
		{"分类非法", []any{map[string]any{
			"id": "custom-aaaa1111", "name": "测试源", "url": "https://a.example.com", "category": "movie",
		}}},
		{"typeId 非法", []any{map[string]any{
			"id": "custom-aaaa1111", "name": "测试源", "url": "https://a.example.com", "typeId": "1;drop",
		}}},
		{"ID 重复", []any{
			customSourceEntry("custom-aaaa1111", "A", "https://a.example.com"),
			customSourceEntry("custom-aaaa1111", "B", "https://b.example.com"),
		}},
		{"条目不是对象", []any{"custom-aaaa1111"}},
	}
	for _, tc := range cases {
		if _, err := applyCustomSources(tc.list); err == nil {
			t.Fatalf("%s: must be rejected", tc.label)
		}
	}
	// 超上限（17 条）整体拒绝。
	oversize := make([]any, 0, customSourceLimit+1)
	for i := 0; i <= customSourceLimit; i++ {
		oversize = append(oversize, customSourceEntry(
			"custom-"+string(rune('a'+i%26))+string(rune('a'+i/26))+"aa1", "源", "https://a.example.com"))
	}
	if _, err := applyCustomSources(oversize); err == nil {
		t.Fatal("over-limit list must be rejected")
	}
	// 整段语义：一条非法 → 连前面合法的也不生效。
	if _, err := applyCustomSources([]any{
		customSourceEntry("custom-cccc3333", "合法源", "https://c.example.com"),
		customSourceEntry("custom-bad url", "非法 ID", "https://d.example.com"),
	}); err == nil {
		t.Fatal("one invalid entry must fail the whole batch")
	}
	if provider.KnownSource("custom-cccc3333") {
		t.Fatal("whole-batch semantics: valid entry must not be registered when a sibling is invalid")
	}
}

func TestApplyCustomSourcesExplicitCategoryAndTypeID(t *testing.T) {
	t.Cleanup(clearCustomSources)
	if _, err := applyCustomSources([]any{map[string]any{
		"id":       "custom-dddd4444",
		"name":     "视频自定义源",
		"url":      "https://v.example.com",
		"category": "video",
		"typeId":   "42",
	}}); err != nil {
		t.Fatalf("register with explicit fields failed: %v", err)
	}
	spec, found := provider.SpecOf("custom-dddd4444")
	if !found {
		t.Fatal("custom-dddd4444 must be registered")
	}
	if spec.Category != provider.CategoryVideo {
		t.Fatalf("category = %q, want video", spec.Category)
	}
	if _, isCataloguer := provider.Get("custom-dddd4444"); !isCataloguer {
		t.Fatal("custom source must expose the cataloguer capability")
	}
}
