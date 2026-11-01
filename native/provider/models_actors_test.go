package provider

import (
	"encoding/json"
	"testing"
)

// 站点把 actors 从字符串数组升级为对象数组后，listResponse 整体不该再崩。
func TestDramaActorsObjectArray(t *testing.T) {
	raw := `{
		"id": "abc",
		"title": "测试剧",
		"actors": [
			{"name": "张三", "id": "1"},
			{"actorName": "李四"},
			{"nickname": "王五"}
		]
	}`
	var d Drama
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatalf("object actors 解析失败: %v", err)
	}
	want := []string{"张三", "李四", "王五"}
	if len(d.Actors) != len(want) {
		t.Fatalf("object actors 解析数量不符: got %v", d.Actors)
	}
	for i := range want {
		if d.Actors[i] != want[i] {
			t.Fatalf("object actors[%d]=%q, want %q (full=%v)", i, d.Actors[i], want[i], d.Actors)
		}
	}
}

// 旧形态字符串数组必须保持原样。
func TestDramaActorsStringArray(t *testing.T) {
	raw := `{"id":"x","title":"t","actors":["张三","李四"]}`
	var d Drama
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatalf("string actors 解析失败: %v", err)
	}
	if len(d.Actors) != 2 || d.Actors[0] != "张三" || d.Actors[1] != "李四" {
		t.Fatalf("string actors 形态被破坏: %v", d.Actors)
	}
}

// 缺省 / null actors 不应报错。
func TestDramaActorsAbsent(t *testing.T) {
	raw := `{"id":"x","title":"t"}`
	var d Drama
	if err := json.Unmarshal([]byte(raw), &d); err != nil {
		t.Fatalf("无 actors 解析失败: %v", err)
	}
	if len(d.Actors) != 0 {
		t.Fatalf("无 actors 应为空: %v", d.Actors)
	}
}
