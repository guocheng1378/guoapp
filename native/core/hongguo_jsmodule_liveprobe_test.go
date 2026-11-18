package core

import (
	"encoding/json"
	"os"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

// JS Drama 字段经 JSON round-trip 必须完整映射到 provider.Drama。
// 这是目录/搜索/榜单接线的字段对齐保障，不依赖网络。
func TestHongguoJSDramaRoundTrip(t *testing.T) {
	raw := map[string]any{
		"id": "7000000000000000001", "source": "hongguo", "sourceId": "7000000000000000001",
		"title": "测试短剧", "cover": "https://img.test/a.jpg",
		"episodeCount": float64(30), "score": "9.1", "onlineDate": "2026-01-01",
		"tags": []any{"甜宠", "逆袭"}, "heat": "12345",
	}
	var drama provider.Drama
	if err := jsRoundTrip(raw, &drama); err != nil {
		t.Fatalf("round trip: %v", err)
	}
	if drama.Title != "测试短剧" || drama.Score != "9.1" || drama.Heat != "12345" {
		t.Fatalf("字段丢失: %+v", drama)
	}
	if len(drama.Tags) != 2 || drama.Tags[0] != "甜宠" {
		t.Fatalf("tags 丢失: %+v", drama.Tags)
	}
	// json tag 对齐验证：序列化后仍是原字段名。
	encoded, _ := json.Marshal(drama)
	var back map[string]any
	json.Unmarshal(encoded, &back)
	if back["title"] != "测试短剧" || back["score"] != "9.1" {
		t.Fatalf("json tag 未对齐: %s", encoded)
	}
}

// parseJSDramaPage 必须补 hongguo: 前缀，供 nativeNormalize 反解 source。
func TestHongguoJSParseDramaPage(t *testing.T) {
	page, err := parseJSDramaPage(map[string]any{
		"hasMore": true,
		"items": []any{
			map[string]any{"id": "123", "source": "hongguo", "title": "甲"},
			map[string]any{"id": "hongguo:456", "source": "hongguo", "title": "乙"},
			map[string]any{"id": "", "title": "空"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if !page.HasMore || len(page.Items) != 2 {
		t.Fatalf("hasMore=%v items=%d", page.HasMore, len(page.Items))
	}
	if page.Items[0].ID != "hongguo:123" || page.Items[1].ID != "hongguo:456" {
		t.Fatalf("ID 前缀未归一: %s / %s", page.Items[0].ID, page.Items[1].ID)
	}
}

// 真网可用性探针：JS 各导出在真实 host 下能返回数据（接线前提）。
// 用 -run TestHongguoJSLiveProbe -timeout 180s 单独跑，默认 go test 也会跑，
// 依赖网络；若 CI 无网络可通过 -short 跳过。
func TestHongguoJSLiveProbe(t *testing.T) {
	// 依赖 hongguoJS 进程单例未被其它 mock 测试污染；全量套件里单例已被
	// 先跑的测试占用，故默认跳过，只在新 shell 里显式单独跑：
	//   HONGGUO_JS_LIVE=1 go test ./core/ -run TestHongguoJSLiveProbe -v -timeout 180s
	if os.Getenv("HONGGUO_JS_LIVE") == "" {
		t.Skip("真网探针：设 HONGGUO_JS_LIVE=1 单独跑")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	module, err := engine.downloader.hongguoJS()
	if err != nil {
		t.Fatalf("load module: %v", err)
	}

	// 目录先拿一条真实 ID，再用它测详情（假 ID 会领域报错，不是链路问题）。
	page, err := module.catalogPage("", 1)
	if err != nil || len(page.Items) == 0 {
		t.Fatalf("catalogPage: err=%v items=%d", err, len(page.Items))
	}
	t.Logf("LIVE catalogPage items=%d first=%s", len(page.Items), page.Items[0].Title)
	if words, err := module.suggestions("短剧"); err != nil || len(words) == 0 {
		t.Fatalf("suggestions: err=%v words=%d", err, len(words))
	} else {
		t.Logf("LIVE suggestions=%v", words[:min(3, len(words))])
	}
	// categories 依赖分类页网络，偶发失败会回落 Go 静态分类，故只日志不 fail。
	if cats, err := module.categories(); err != nil || len(cats) == 0 {
		t.Logf("LIVE categories fallback: err=%v cats=%d", err, len(cats))
	} else {
		t.Logf("LIVE categories=%d", len(cats))
	}
	if rank, err := module.rankingPage("hongguo-hot", 1); err != nil || len(rank.Items) == 0 {
		t.Fatalf("rankingPage: err=%v items=%d", err, len(rank.Items))
	} else {
		t.Logf("LIVE rankingPage items=%d first=%s", len(rank.Items), rank.Items[0].Drama.Title)
	}
	// 用目录返回的第一部真实剧 ID 测详情（JS detail 只认纯数字 ID，
	// 生产接线用 splitProviderDramaID 剥前缀，这里同样剥掉）。
	firstID := strings.TrimPrefix(page.Items[0].ID, "hongguo:")
	detailRaw, err := module.hongguoJSCall("detail", firstID)
	if err != nil || detailRaw == nil {
		t.Fatalf("detail(%s): err=%v", firstID, err)
	}
	t.Logf("LIVE detail(%s) ok", firstID)
}
