package core

import (
	"encoding/base64"
	"testing"
)

// TestHongguoVideoModelForms 覆盖 play-info 返回 video_model 的三种形态：
// 直接对象、base64 编码 JSON 串、以及无 video_model 包裹的顶层 video_list 兜底。
func TestHongguoVideoModelForms(t *testing.T) {
	direct, err := hongguoVideoModel(map[string]any{
		"video_model": map[string]any{"video_list": []any{map[string]any{"main_url": "https://cdn.example/a.mp4"}}},
	})
	if err != nil || len(anyList(direct["video_list"])) != 1 {
		t.Fatalf("direct object form: err=%v model=%v", err, direct)
	}

	payload := `{"video_list":[{"main_url":"https://cdn.example/b.mp4"}],"video_duration":12}`
	encoded := base64.StdEncoding.EncodeToString([]byte(payload))
	decoded, err := hongguoVideoModel(map[string]any{"video_model": encoded})
	if err != nil || len(anyList(decoded["video_list"])) != 1 {
		t.Fatalf("base64 form: err=%v model=%v", err, decoded)
	}

	flat, err := hongguoVideoModel(map[string]any{
		"video_list":     []any{map[string]any{"main_url": "https://cdn.example/c.mp4"}},
		"video_duration": 34,
	})
	if err != nil || len(anyList(flat["video_list"])) != 1 {
		t.Fatalf("flat fallback form: err=%v model=%v", err, flat)
	}

	if _, err := hongguoVideoModel(map[string]any{"video_model": "not-json{}"}); err == nil {
		t.Fatal("expected error for invalid video_model")
	}
}

// TestHongguoTagCategoryValidation 确认 tag:cate_* 是红果合法分类，且畸形值被拒。
func TestHongguoTagCategoryValidation(t *testing.T) {
	if !validNativeCategory(sourceHongguo, "tag:cate_12") {
		t.Fatal("tag:cate_12 should be accepted as a hongguo category")
	}
	for _, bad := range []string{"tag:cate_", "tag:x", "tag:cate_1234567890", "tag:cate_1|2"} {
		if validNativeCategory(sourceHongguo, bad) {
			t.Fatalf("malformed tag category accepted: %q", bad)
		}
	}
}
