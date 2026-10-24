package core

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"
)

// 「豆瓣榜单没图」端到端回归：用真实引擎（含 cdnTransport 分流与限速器）
// 走 loadCover 全链路，封面必须真的下载落盘（需真实网络）。
// img9.doubanio.com 的 EdgeOne Bot 管理最严（Go 原生指纹拿 1KB EO_Bot_Ssid
// 挑战页），必须覆盖；img2 相对宽松，早年掩盖了指纹问题。
func TestDoubanCoverLoadRealEngineIntegration(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: requires network")
	}
	cases := []struct {
		id, title, cover string
	}{
		{"douban:37068446", "生化危机：爆发夜",
			"https://img2.doubanio.com/view/photo/m_ratio_poster/public/p2936442661.jpg"},
		// 2026-10-19 实时热门 rank2/rank3 实测，img9 域名。
		{"douban:36726409", "杯雪·一战成名",
			"https://img9.doubanio.com/view/photo/m_ratio_poster/public/p2936719035.jpg"},
		{"douban:36893751", "你能看到一切",
			"https://img9.doubanio.com/view/photo/m_ratio_poster/public/p2936729175.jpg"},
	}
	for _, tc := range cases {
		engine, err := newNativeEngine(t.TempDir())
		if err != nil {
			t.Fatalf("engine: %v", err)
		}
		drama := nativeDrama{ID: tc.id, Source: sourceDouban, SourceID: strings.TrimPrefix(tc.id, "douban:"),
			Title: tc.title, Cover: tc.cover}
		result, err := engine.loadCover(context.Background(), drama, false)
		if err != nil {
			t.Fatalf("loadCover %s (%s): %v", tc.cover, tc.title, err)
		}
		info, statErr := os.Stat(result["path"].(string))
		if statErr != nil {
			t.Fatalf("cover file stat: %v", statErr)
		}
		if info.Size() < 10240 {
			t.Fatalf("%s: cover file too small (%d bytes) — EdgeOne bot challenge?", tc.cover, info.Size())
		}
		t.Logf("douban cover cached: %s (%d bytes)", result["path"], info.Size())
	}
}

func TestDoubanCoverLoadIntegration(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: requires network")
	}
	dir := t.TempDir()
	downloader := &Downloader{cfg: defaultConfig()}
	downloader.cfg.dataDir = t.TempDir()
	downloader.client = &http.Client{Timeout: 30 * time.Second}
	downloader.limiter = newRequestLimiter(8, time.Nanosecond)
	engine := &nativeEngine{
		downloader:      downloader,
		directory:       dir,
		catalogs:        map[string][]nativeDrama{},
		catalogStates:   map[string]nativeCatalogState{},
		categoryOptions: map[string][]nativeCategory{},
		recommendations: map[string]nativeRecommendationState{},
		covers:          newNativeCoverCache(dir, downloader),
	}
	// 2026-10-19 rexxar movie_top250 首条实测（肖申克的救赎）。
	drama := nativeDrama{ID: "douban:1292052", Source: sourceDouban, SourceID: "1292052",
		Title: "肖申克的救赎",
		Cover: "https://img3.doubanio.com/view/photo/m_ratio_poster/public/p2934829882.jpg"}
	result, err := engine.loadCover(context.Background(), drama, false)
	if err != nil {
		t.Fatalf("loadCover douban cover: %v", err)
	}
	info, statErr := os.Stat(result["path"].(string))
	if statErr != nil {
		t.Fatalf("cover file stat: %v", statErr)
	}
	if info.Size() < 1024 {
		t.Fatalf("cover file too small: %d bytes", info.Size())
	}
	t.Logf("douban cover cached: %s (%d bytes)", result["path"], info.Size())
}

// 「豆瓣榜单没图」第二层回归：真实引擎走 nativeRanking 全链路（拉榜→
// nativeNormalize→序列化），确认输出 JSON 里条目带 cover URL——手机端
// 榜单无图时优先排除榜单构建层丢封面。
func TestDoubanRankingJSONCoverIntegration(t *testing.T) {
	if testing.Short() {
		t.Skip("integration: requires network")
	}
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("engine: %v", err)
	}
	result, err := engine.nativeRanking(context.Background(),
		nativeInput{Action: "rankings", Board: "douban-realtime", Page: 1})
	if err != nil {
		t.Fatalf("nativeRanking: %v", err)
	}
	raw, marshalErr := json.Marshal(result)
	if marshalErr != nil {
		t.Fatalf("marshal: %v", marshalErr)
	}
	var parsed struct {
		Items []struct {
			Drama struct {
				ID    string `json:"id"`
				Title string `json:"title"`
				Cover string `json:"cover"`
			} `json:"drama"`
		} `json:"items"`
	}
	if unmarshalErr := json.Unmarshal(raw, &parsed); unmarshalErr != nil {
		t.Fatalf("unmarshal: %v; raw head: %.400s", unmarshalErr, string(raw))
	}
	if len(parsed.Items) == 0 {
		t.Fatalf("empty items; raw head: %.400s", string(raw))
	}
	withCover := 0
	for _, item := range parsed.Items {
		if item.Drama.Cover != "" {
			withCover++
		}
	}
	if withCover == 0 {
		first, _ := json.Marshal(parsed.Items[0].Drama)
		t.Fatalf("no item carries a cover URL; first drama: %s", first)
	}
	t.Logf("items=%d withCover=%d first: id=%s title=%s cover=%s",
		len(parsed.Items), withCover, parsed.Items[0].Drama.ID,
		parsed.Items[0].Drama.Title, parsed.Items[0].Drama.Cover)
}
