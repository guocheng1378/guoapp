package core

// 详情页后台补兑（见 dongpiandiBackfillOfficialLines）回归：
// 详情页为了不被限流只兑首集，其余集的官方票据靠这个后台任务补齐，
// 否则线路面板里永远只有第三方源（用户报「面板里没有官方源」）。

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
)

// 兑换不完整（3 张票只成 1 张）时，兑出来的那条官方线也要进缓存——否则这一集
// 永远没有官方源。之后再遇到「这次一条官方线都没兑出来」的残缺刷新，旧的官方
// 线必须保留（防一次 429 把已兑好的擦掉）。
func TestDongpiandiLineCacheKeepsPartialOfficialOnFirstWrite(t *testing.T) {
	resetDongpiandiLineCache(t)
	epID := "ep_partial"
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "1080P-官方D", Official: true, Resolved: true},
		{URL: "http://cached.test/third.m3u8", Label: "新浪资源", Resolved: true},
	}, false)
	lines := dongpiandiCachedLines(epID)
	if len(lines) != 2 || !lines[0].Official {
		t.Fatalf("首次残缺兑换也要缓存官方线: %+v", lines)
	}
	// 下一次残缺刷新一条官方线都没兑出来：旧官方保留，三方替换。
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/third2.m3u8", Label: "索尼资源", Resolved: true},
	}, false)
	lines = dongpiandiCachedLines(epID)
	if len(lines) != 2 || !lines[0].Official || !strings.Contains(lines[1].URL, "third2") {
		t.Fatalf("残缺刷新应保留旧官方线并替换三方: %+v", lines)
	}
	// 完整兑换：官方线整体覆盖为新的那条；这次没带三方线，旧三方保留。
	dongpiandiCacheLines(epID, []dongpiandiLine{
		{URL: "http://cached.test/official2.mp4", Label: "1080P-官方E", Official: true, Resolved: true},
	}, true)
	lines = dongpiandiCachedLines(epID)
	if len(lines) != 2 || !strings.Contains(lines[0].URL, "official2") {
		t.Fatalf("完整兑换应覆盖官方线: %+v", lines)
	}
}

func TestDongpiandiBackfillWritesOfficialForEveryEpisode(t *testing.T) {
	resetDongpiandiLineCache(t)
	var resolveCalls, redeemCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			atomic.AddInt32(&resolveCalls, 1)
			fmt.Fprint(w, `{"line_options":[
				{"id":"l1","label":"新浪资源","url":"http://127.0.0.1:1/third/index.m3u8","url_kind":"m3u8","resolved":true,"preference_weight":900},
				{"id":"l2","label":"1080P-官方D","url":"resolve://tk-a","url_kind":"resolve_ticket","resolved":false}]}`)
		case r.URL.Path == "/v1/users/anonymous":
			fmt.Fprint(w, `{}`)
		case r.URL.Path == "/v1/playback/resolve-line":
			atomic.AddInt32(&redeemCalls, 1)
			fmt.Fprint(w, `{"line":{"id":"l2","label":"1080P-官方D","url":"http://127.0.0.1:9/official.mp4","url_kind":"mp4","resolved":true}}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	withDongpiandiBaseURL(t, srv.URL)

	episodes := []dongpiandiEpisode{{ID: "ep1", Token: "t1"}, {ID: "ep2", Token: "t2"}}
	(&Downloader{}).dongpiandiBackfillOfficialLines(
		context.Background(),
		newDongpiandiClient(),
		"d1",
		episodes,
	)

	if resolveCalls != 2 || redeemCalls != 2 {
		t.Fatalf("每集都要补兑一次: resolve=%d redeem=%d", resolveCalls, redeemCalls)
	}
	for _, ep := range episodes {
		lines := dongpiandiCachedLines(ep.ID)
		official := 0
		for _, line := range lines {
			if line.Official {
				official++
			}
		}
		if official != 1 {
			t.Fatalf("%s 缓存里应有 1 条官方线: %+v", ep.ID, lines)
		}
	}
}

func TestDongpiandiBackfillSkipsEpisodeWithFreshOfficial(t *testing.T) {
	resetDongpiandiLineCache(t)
	var resolveCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			atomic.AddInt32(&resolveCalls, 1)
			fmt.Fprint(w, `{"line_options":[
				{"id":"l2","label":"1080P-官方D","url":"resolve://tk-a","url_kind":"resolve_ticket","resolved":false}]}`)
		case r.URL.Path == "/v1/users/anonymous":
			fmt.Fprint(w, `{}`)
		default:
			fmt.Fprint(w, `{"line":{"url":"http://127.0.0.1:9/official.mp4","url_kind":"mp4","resolved":true}}`)
		}
	}))
	defer srv.Close()
	withDongpiandiBaseURL(t, srv.URL)

	// ep1 已有新鲜官方线：不该再发请求。
	dongpiandiCacheLines("ep1", []dongpiandiLine{
		{URL: "http://cached.test/official.mp4", Label: "1080P-官方D", Official: true, Resolved: true},
	}, true)

	episodes := []dongpiandiEpisode{{ID: "ep1", Token: "t1"}, {ID: "ep2", Token: "t2"}}
	(&Downloader{}).dongpiandiBackfillOfficialLines(
		context.Background(),
		newDongpiandiClient(),
		"d2",
		episodes,
	)
	if resolveCalls != 1 {
		t.Fatalf("已有官方线的集应跳过，只处理 ep2，实际 resolve=%d", resolveCalls)
	}
}

// 连续两集「有票据但一张都兑不出来」= 站点限流/线路整体不可用，立即收手：
// 第三集不能再打请求，否则会把限流放大。
func TestDongpiandiBackfillStopsWhenTicketsNeverRedeem(t *testing.T) {
	resetDongpiandiLineCache(t)
	var resolveCalls int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		switch {
		case strings.HasPrefix(r.URL.Path, "/v1/playback/resolve/"):
			atomic.AddInt32(&resolveCalls, 1)
			fmt.Fprint(w, `{"line_options":[
				{"id":"l1","label":"1080P-官方甲","url":"resolve://tk-a","url_kind":"resolve_ticket","resolved":false},
				{"id":"l2","label":"1080P-官方乙","url":"resolve://tk-b","url_kind":"resolve_ticket","resolved":false}]}`)
		case r.URL.Path == "/v1/users/anonymous":
			fmt.Fprint(w, `{}`)
		case r.URL.Path == "/v1/playback/resolve-line":
			w.WriteHeader(http.StatusNotFound)
			fmt.Fprint(w, `{"statusCode":404,"code":"playback_line_unavailable","message":"播放资源暂时不可用"}`)
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()
	withDongpiandiBaseURL(t, srv.URL)

	episodes := []dongpiandiEpisode{
		{ID: "ep1", Token: "t1"},
		{ID: "ep2", Token: "t2"},
		{ID: "ep3", Token: "t3"},
	}
	(&Downloader{}).dongpiandiBackfillOfficialLines(
		context.Background(),
		newDongpiandiClient(),
		"d3",
		episodes,
	)
	if resolveCalls != 2 {
		t.Fatalf("连续两集兑不出应停止，第三集不该再请求，实际 resolve=%d", resolveCalls)
	}
	for _, ep := range episodes {
		for _, line := range dongpiandiCachedLines(ep.ID) {
			if line.Official {
				t.Fatalf("兑换全失败时不应缓存官方线: %+v", line)
			}
		}
	}
}
