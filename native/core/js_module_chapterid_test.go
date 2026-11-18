package core

import (
	"strings"
	"testing"

	"github.com/dop251/goja"
)

// TestHostChapterIdUniquePerEpisode 是「在线模块只有 1 集」的回归护栏：
// host.chapterId 曾只取第一参数（站点 ID），同一剧所有分集 id 相同，
// 经模块 uniqueChapters 按 id 去重后塌缩成 1 集（黄果 AI / 黄果视频 实锤）。
// 修复后格式须为 模块ID:站点ID:分集key，空 key 留尾冒号供 startsWith 前缀反查。
func TestHostChapterIdUniquePerEpisode(t *testing.T) {
	vm := goja.New()
	rt := &jsModuleRuntime{vm: vm, manifest: JSModuleManifest{ID: "huangguoai"}}
	if err := vm.Set("host", rt.hostObject()); err != nil {
		t.Fatal(err)
	}
	eval := func(expr string) string {
		value, err := vm.RunString(expr)
		if err != nil {
			t.Fatalf("eval %s: %v", expr, err)
		}
		return value.String()
	}

	ep1 := eval(`host.chapterId("12", "auto-1")`)
	ep2 := eval(`host.chapterId("12", "ep-2")`)
	prefix := eval(`host.chapterId("12", "")`)

	if ep1 == ep2 {
		t.Fatalf("不同分集 id 不得相同：%q == %q", ep1, ep2)
	}
	if want := "huangguoai:12:auto-1"; ep1 != want {
		t.Fatalf("分集 id 格式错：got %q want %q", ep1, want)
	}
	if want := "huangguoai:12:ep-2"; ep2 != want {
		t.Fatalf("分集 id 格式错：got %q want %q", ep2, want)
	}
	if want := "huangguoai:12:"; prefix != want {
		t.Fatalf("空 key 前缀错：got %q want %q", prefix, want)
	}
	if !strings.HasPrefix(ep1, prefix) || !strings.HasPrefix(ep2, prefix) {
		t.Fatalf("分集 id 必须以空 key 前缀开头：prefix=%q ep1=%q ep2=%q", prefix, ep1, ep2)
	}
}
