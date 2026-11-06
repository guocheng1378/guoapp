package core

import (
	"context"
	"testing"
)

// P0-3：起播首帧只有一条线路时，打开线路面板由 routes action 现场补
// 齐线路表（缓存命中零网络），且不重开流会话/不换 URL。
func TestNativePlaybackRoutesFillsLinesOnPanelOpen(t *testing.T) {
	srv := newDongpiandiRouteServer(
		`{"id":"d1","title":"测试剧","episodes":[{"id":"e-routes-action","key":"e-0001","token":"t1"}]}`,
		dongpiandiLineOptionsJSON(nil),
	)
	defer srv.close()
	withDongpiandiBaseURL(t, srv.server.URL)

	const episodeID = "e-routes-action"
	// 缓存里带上一条新鲜官方线，routeLines 就不会现场补兑/打 API。
	dongpiandiCacheLines(episodeID, []dongpiandiLine{
		{ID: "main", Label: "主线", URL: srv.server.URL + "/v1.mp4"},
		{ID: "official", Label: "官方", URL: srv.server.URL + "/vo.mp4", Official: true},
		{ID: "backup", Label: "备线", URL: srv.server.URL + "/v2.mp4"},
	}, true)

	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	choice := nativePlaybackChoices(providerMedia{URL: srv.server.URL + "/v1.mp4"}, 0)
	choice.task = Task{
		DramaID: providerDramaID(sourceDongpiandi, "d1"),
		Chapter: Chapter{
			ID:      providerDramaID(sourceDongpiandi, episodeID),
			PageURL: srv.server.URL + "/player/d1",
		},
	}
	if engine.playbacks == nil {
		engine.playbacks = map[string]nativePlaybackChoice{}
	}
	engine.playbacks["routes-session"] = choice

	result, err := engine.nativePlaybackRoutes(context.Background(), "routes-session")
	if err != nil {
		t.Fatal(err)
	}
	count, _ := result["routeCount"].(int)
	if count < 2 {
		t.Fatalf("panel should expose the full route table, got %d routes", count)
	}
	labels, _ := result["routeLabels"].([]string)
	if len(labels) != count {
		t.Fatalf("labels/count mismatch: %d labels for %d routes", len(labels), count)
	}
	// 会话仍然只有原来的 URL/session：routes 不重开流。
	if got := engine.playbacks["routes-session"].media[choice.index].URL; got != srv.server.URL+"/v1.mp4" {
		t.Fatalf("primary URL changed: %q", got)
	}
	if _, err := engine.nativePlaybackRoutes(context.Background(), "missing-session"); err == nil {
		t.Fatal("evicted/missing session must be reported")
	}
}
