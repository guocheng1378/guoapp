package core

import (
	"context"
	"testing"
)

// 详情懒解析回归：只有首集付一次 resolve，其余集保留反查所需的
// ID/PageURL，VideoURL 留空交给播放期按需解析。
func TestDongpiandiDetailResolvesOnlyLeadEpisode(t *testing.T) {
	srv := newDongpiandiRouteServer(
		`{"id":"d-lazy","title":"懒解析剧","episodes":[
			{"id":"e-lazy-1","key":"e-0001","number":1,"token":"t1"},
			{"id":"e-lazy-2","key":"e-0002","number":2,"token":"t2"},
			{"id":"e-lazy-3","key":"e-0003","number":3,"token":"t3"}
		]}`,
		dongpiandiLineOptionsJSON([]map[string]any{
			{"id": "l1", "label": "主线", "url": "https://a.test/v.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900},
		}),
	)
	defer srv.close()
	withDongpiandiBaseURL(t, srv.server.URL)

	d := &Downloader{}
	_, chapters, err := d.fetchDongpiandiDetail(context.Background(), "d-lazy")
	if err != nil {
		t.Fatal(err)
	}
	if len(chapters) != 3 {
		t.Fatalf("want 3 chapters, got %d: %+v", len(chapters), chapters)
	}
	if chapters[0].VideoURL == "" {
		t.Fatal("lead episode has no playable address")
	}
	for i := 1; i < len(chapters); i++ {
		if chapters[i].VideoURL != "" {
			t.Fatalf("episode %d should be lazily resolved, got %q", i+1, chapters[i].VideoURL)
		}
		if chapters[i].ID == "" || chapters[i].PageURL == "" {
			t.Fatalf("episode %d lost ID/PageURL needed for on-demand resolve: %+v", i+1, chapters[i])
		}
	}
	// catalog 1 次 + 首集 resolve 1 次；旧实现 N 集各一次 resolve。
	if got := srv.apiCalls.Load(); got > 2 {
		t.Fatalf("detail resolved too many episodes: %d API calls", got)
	}
}

// 懒解析后 Chapter.VideoURL 为空，解析缓存仍要能命中（用分集 ID）。
// 其它源保持「无地址不缓存」的旧语义。
func TestNativeResolveCacheKeyUsesDongpiandiEpisodeID(t *testing.T) {
	lazy := Task{
		DramaID: providerDramaID(sourceDongpiandi, "d1"),
		Chapter: Chapter{ID: providerDramaID(sourceDongpiandi, "e1")},
	}
	if key := nativeResolveCacheKey(lazy, nativeInput{}); key == "" {
		t.Fatal("lazy-parsed dongpiandi chapter must remain cacheable")
	}
	other := Task{
		DramaID: providerDramaID(sourceHongguo, "d1"),
		Chapter: Chapter{ID: providerDramaID(sourceHongguo, "e1")},
	}
	if key := nativeResolveCacheKey(other, nativeInput{}); key != "" {
		t.Fatalf("other sources must keep the no-address rule, got %q", key)
	}
}
