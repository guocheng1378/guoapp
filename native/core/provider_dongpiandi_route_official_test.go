package core

// 线路列表「补兑官方票」回归（2026-10-25 真网复现的「看不到官方源」）：
// 详情页多路并发被站点限流时，多数集写进缓存的只有三方直连；线路面板不能拿
// 这份缓存充数，必须在播放期重兑一次官方票，否则官方源从此消失。
// 反过来，站点压根没有票据的剧要冷却，别每次开面板都跑完整条解析链。

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

// zzTicketServer 是与真 iTunes 同构的最小桩：目录 → 单集 resolve（含票据）
// → 匿名会话 → 票据兑换。
type zzTicketServer struct {
	server    *httptest.Server
	catalog   string
	resolve   string
	tickets   map[string]dongpiandiLine
	mu        sync.Mutex
	apiCalls  atomic.Int32
	ticketOff bool // 关掉票：模拟站点这一集没有票据
}

func newZZTicketServer(t *testing.T, tickets map[string]dongpiandiLine) *zzTicketServer {
	t.Helper()
	s := &zzTicketServer{catalog: `{"id":"av_1","title":"测试剧","episodes":[{"id":"av_ep2","number":2,"token":"token2"}]}`, tickets: tickets}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/catalog/", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, s.catalog)
	})
	mux.HandleFunc("/v1/playback/resolve/", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		w.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprint(w, s.resolve)
	})
	mux.HandleFunc("/v1/users/anonymous", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		_, _ = fmt.Fprint(w, "{}")
	})
	mux.HandleFunc("/v1/playback/resolve-line", func(w http.ResponseWriter, r *http.Request) {
		s.apiCalls.Add(1)
		var body struct {
			Ticket string `json:"ticket"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		s.mu.Lock()
		off, line, ok := s.ticketOff, s.tickets[body.Ticket], true
		if !ok {
			line, ok = s.tickets[body.Ticket]
		}
		s.mu.Unlock()
		if off || !ok {
			_, _ = fmt.Fprint(w, "{}")
			return
		}
		ack, _ := json.Marshal(map[string]dongpiandiLine{"line": line})
		_, _ = w.Write(ack)
	})
	s.server = httptest.NewServer(mux)
	t.Cleanup(s.server.Close)
	return s
}

func zzThirdOnlyLines(base string) []dongpiandiLine {
	return []dongpiandiLine{{
		ID:       "t1",
		Label:    "无水印资源",
		URL:      base + "/v/index.m3u8",
		URLKind:  "m3u8",
		Resolved: true,
	}}
}

func TestDongpiandiRouteLinesBackfillsOfficialWhenCacheIsThirdOnly(t *testing.T) {
	resetDongpiandiLineCache(t)
	srv := newZZTicketServer(t, map[string]dongpiandiLine{
		"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/official.mp4", URLKind: "mp4"},
	})
	srv.resolve = dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": srv.server.URL + "/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900},
		{"id": "l2", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 500},
	})
	withDongpiandiBaseURL(t, srv.server.URL)

	// 详情页被限流：这一集写进缓存的只有三方直连。
	dongpiandiCacheLines("av_ep2", zzThirdOnlyLines(srv.server.URL), false)
	d := &Downloader{}
	task := Task{Chapter: Chapter{
		ID:      providerDramaID(sourceDongpiandi, "av_ep2"),
		PageURL: srv.server.URL + "/player/av_1",
	}}

	lines := d.dongpiandiRouteLines(context.Background(), task)
	official := 0
	for _, line := range lines {
		if line.Official {
			official++
		}
	}
	if official != 1 {
		t.Fatalf("缓存里没有官方线时必须补兑，得到 official=%d / 共 %d 条: %+v", official, len(lines), lines)
	}
	// 官方线恒排首（用户定调「默认就进官方源」）。
	if !lines[0].Official {
		t.Fatalf("官方线必须排在首位，实际首条 %+v", lines[0])
	}

	// 缓存里已经有官方线后：再取线路零网络请求（面板秒开）。
	before := srv.apiCalls.Load()
	again := d.dongpiandiRouteLines(context.Background(), task)
	if srv.apiCalls.Load() != before {
		t.Fatalf("已有官方线时应零等待复用缓存，实际又请求了 %d 次", srv.apiCalls.Load()-before)
	}
	if len(again) != len(lines) {
		t.Fatalf("复用缓存条数应一致，得到 %d 期望 %d", len(again), len(lines))
	}
}

func TestDongpiandiRouteLinesCoolsDownWhenDramaHasNoTicket(t *testing.T) {
	resetDongpiandiLineCache(t)
	srv := newZZTicketServer(t, map[string]dongpiandiLine{})
	srv.resolve = dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": srv.server.URL + "/v/index.m3u8", "url_kind": "m3u8", "resolved": true, "preference_weight": 900},
	})
	srv.ticketOff = true
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	task := Task{Chapter: Chapter{
		ID:      providerDramaID(sourceDongpiandi, "av_ep2"),
		PageURL: srv.server.URL + "/player/av_1",
	}}
	dongpiandiCacheLines("av_ep2", zzThirdOnlyLines(srv.server.URL), false)

	// 第一次：值得再试一次（本剧可能只是这次被限流）。
	if lines := d.dongpiandiRouteLines(context.Background(), task); len(lines) == 0 {
		t.Fatal("无票时应回退缓存里的三方线，不能返回空")
	}
	first := srv.apiCalls.Load()
	if first == 0 {
		t.Fatal("缺官方线时应去站点兑一次")
	}

	// 第二次：刚兑过，冷却窗内不再付一次完整往返。
	before := srv.apiCalls.Load()
	d.dongpiandiRouteLines(context.Background(), task)
	if srv.apiCalls.Load() != before {
		t.Fatalf("冷却窗内不应重复重解析，实际又请求了 %d 次", srv.apiCalls.Load()-before)
	}

	// 冷却窗过后允许再试（换剧/换网络后官方票可能就到了）。
	dongpiandiLinesMu.Lock()
	entry := dongpiandiLinesCache["av_ep2"]
	entry.officialTriedAt = time.Now().Add(-dongpiandiOfficialRetryGap - time.Second)
	dongpiandiLinesCache["av_ep2"] = entry
	dongpiandiLinesMu.Unlock()

	before = srv.apiCalls.Load()
	d.dongpiandiRouteLines(context.Background(), task)
	if srv.apiCalls.Load() == before {
		t.Fatal("冷却窗结束后应允许再次补兑官方票")
	}
}
