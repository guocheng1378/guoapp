package core

import (
	"context"
	"net/http"
	"strings"
	"sync"
	"testing"
)

// TestHuangguoAICategoryMapMatchesSite 钉住目录映射表：站点早已下线
// 「黄果吃瓜」，且分类名不带「成人」字样。写错的映射会让菜单里出现
// 点了必然 404 的分组，或让 chip 名与卡片分类名对不上。
func TestHuangguoAICategoryMapMatchesSite(t *testing.T) {
	want := map[string]string{
		"ai-duanju":   "AI 短剧",
		"ai-manju":    "AI 漫剧",
		"ai-huanlian": "AI 换脸",
		"ai-mogai":    "AI 魔改",
	}
	if len(nativeAICategories) != len(want) {
		t.Fatalf("category map size drifted: %d", len(nativeAICategories))
	}
	for _, entry := range nativeAICategories {
		if want[entry.ID] != entry.Name {
			t.Fatalf("category %q has name %q, want %q", entry.ID, entry.Name, want[entry.ID])
		}
		if !validNativeCategory(sourceHuangguoAI, entry.ID) {
			t.Fatalf("category %q rejected by whitelist", entry.ID)
		}
	}
	if validNativeCategory(sourceHuangguoAI, "chigua") {
		t.Fatal("retired chigua category is still accepted")
	}
}

var huangguoCategoryFixture = map[string]any{
	"id": "5101", "title": "合成短剧", "cate_name": "短剧",
}

// TestHuangguoAICatalogOnlyRequestsSelectedCategory 旧实现在 category 未
// 命中映射表时并发请求全部分类，用户点「AI 短剧」会拿到混合内容。这里
// 验证选中一个分类时只发一条对应请求。
func TestHuangguoAICatalogOnlyRequestsSelectedCategory(t *testing.T) {
	var mu sync.Mutex
	var paths []string
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		target := huangguoEdgeTarget(t, request)
		mu.Lock()
		paths = append(paths, target.Path)
		mu.Unlock()
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
			"items":      []any{huangguoCategoryFixture},
			"pagination": map[string]any{"pages": 1},
		})), nil
	})

	items, _, err := d.fetchHuangguoAICatalogPage(context.Background(), 1, "ai-duanju")
	if err != nil || len(items) == 0 {
		t.Fatalf("selected category failed: items=%d err=%v", len(items), err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(paths) != 1 || !strings.HasSuffix(paths[0], "/api/videos/category/ai-duanju") {
		t.Fatalf("selected category issued wrong requests: %v", paths)
	}
}

// TestHuangguoAICatalogOnlyRequestsUnknownSlug 未知 slug 也不该退化成
// 「并发全部类别」——那会把别类内容混进用户点开的分组。
func TestHuangguoAICatalogOnlyRequestsUnknownSlug(t *testing.T) {
	var mu sync.Mutex
	var paths []string
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		target := huangguoEdgeTarget(t, request)
		mu.Lock()
		paths = append(paths, target.Path)
		mu.Unlock()
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
			"items":      []any{huangguoCategoryFixture},
			"pagination": map[string]any{"pages": 1},
		})), nil
	})

	if _, _, err := d.fetchHuangguoAICatalogPage(context.Background(), 1, "brand-new-slug"); err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if len(paths) != 1 || !strings.HasSuffix(paths[0], "/api/videos/category/brand-new-slug") {
		t.Fatalf("unknown slug fell back to all categories: %v", paths)
	}
}

// TestHuangguoAICatalogPartialFailureKeepsSuccessfulCategory 站点部分分类
// 返回 410 时，只要选中的分类成功就不该把整页判失败；失败也不能撑起
// hasMore（否则上拉会一直重发同一页）。
func TestHuangguoAICatalogPartialFailureKeepsSuccessfulCategory(t *testing.T) {
	d := edgeFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		target := huangguoEdgeTarget(t, request)
		if strings.HasSuffix(target.Path, "/ai-mogai") {
			return sourceFixtureResponse(request, http.StatusGone, "gone"), nil
		}
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(map[string]any{
			"items":      []any{huangguoCategoryFixture},
			"pagination": map[string]any{"pages": 1},
		})), nil
	})

	items, more, err := d.fetchHuangguoAICatalogPage(context.Background(), 1, "ai-duanju")
	if err != nil || len(items) == 0 {
		t.Fatalf("single healthy category failed: items=%d err=%v", len(items), err)
	}
	if more {
		t.Fatal("last page must not claim hasMore")
	}
}
