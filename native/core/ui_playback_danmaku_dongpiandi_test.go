package core

// 真果·鉴时评弹幕测试：身份提取、源分发、窗口裁剪、评论过滤、翻页与纯函数。

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"
)

// dongpiandiStubRoundTrip 按请求序返回预置响应体。
type dongpiandiStubRoundTrip struct {
	bodies []string
	calls  int
}

func (s *dongpiandiStubRoundTrip) RoundTrip(req *http.Request) (*http.Response, error) {
	body := "{}"
	if s.calls < len(s.bodies) {
		body = s.bodies[s.calls]
	}
	s.calls++
	return &http.Response{
		StatusCode: 200,
		Header:     http.Header{"Content-Type": []string{"application/json"}},
		Body:       io.NopCloser(strings.NewReader(body)),
		Request:    req,
	}, nil
}

func dongpiandiStubClient(bodies ...string) *dongpiandiClient {
	return &dongpiandiClient{http: &http.Client{Timeout: 5 * time.Second, Transport: &dongpiandiStubRoundTrip{bodies: bodies}}}
}

func dongpiandiTask(dramaID, chapterID string) Task {
	return Task{
		DramaID: dramaID,
		Chapter: Chapter{ID: chapterID, Source: sourceDongpiandi, VideoURL: "https://media.example.test/video/index.m3u8"},
	}
}

func TestDongpiandiDanmakuPlaybackIDs(t *testing.T) {
	valid := dongpiandiTask(providerDramaID(sourceDongpiandi, "variant1"), providerDramaID(sourceDongpiandi, "ep1"))
	if variant, episode, ok := dongpiandiPlaybackIDs(valid); !ok || variant != "variant1" || episode != "ep1" {
		t.Fatalf("valid task rejected: %q %q %v", variant, episode, ok)
	}
	wrongChapter := valid
	wrongChapter.Chapter.Source = sourceHongguo
	if _, _, ok := dongpiandiPlaybackIDs(wrongChapter); ok {
		t.Fatal("wrong chapter source accepted")
	}
	badDrama := dongpiandiTask("dongpiandi:", providerDramaID(sourceDongpiandi, "ep1"))
	if _, _, ok := dongpiandiPlaybackIDs(badDrama); ok {
		t.Fatal("empty variant accepted")
	}
	badEpisode := dongpiandiTask(providerDramaID(sourceDongpiandi, "variant1"), "")
	if _, _, ok := dongpiandiPlaybackIDs(badEpisode); ok {
		t.Fatal("empty episode accepted")
	}
}

func TestDanmakuPlaybackIDsDispatch(t *testing.T) {
	dpp := dongpiandiTask(providerDramaID(sourceDongpiandi, "v1"), providerDramaID(sourceDongpiandi, "e1"))
	if source, series, video, ok := danmakuPlaybackIDs(dpp); !ok || source != sourceDongpiandi || series != "v1" || video != "e1" {
		t.Fatalf("dongpiandi dispatch wrong: %s %s %s %v", source, series, video, ok)
	}
	hg := Task{DramaID: providerDramaID(sourceHongguo, "111"), Chapter: Chapter{Source: sourceHongguo, VideoURL: "hongguo-cenc://222"}}
	if source, series, video, ok := danmakuPlaybackIDs(hg); !ok || source != sourceHongguo || series != "111" || video != "222" {
		t.Fatalf("hongguo dispatch wrong: %s %s %s %v", source, series, video, ok)
	}
	other := Task{DramaID: providerDramaID(sourceHuangdou, "333"), Chapter: Chapter{ID: providerDramaID(sourceHuangdou, "e"), Source: sourceHuangdou}}
	if _, _, _, ok := danmakuPlaybackIDs(other); ok {
		t.Fatal("other source accepted")
	}
}

// dongpiandiCommentFixture 构造一页评论；rows 为 (id, content, status, episodeID, positionSec)。
func dongpiandiCommentFixture(rows [][5]any, hasMore bool, cursor string) string {
	var resp dongpiandiCommentResp
	resp.Object = "comments.list"
	resp.HasMore = hasMore
	if cursor != "" {
		resp.NextCursor = cursor
	}
	for _, r := range rows {
		row := dongpiandiCommentRow{ID: r[0].(string), Content: r[1].(string), Status: r[2].(string)}
		row.Metadata.PlaybackContext = &dongpiandiPlaybackContext{EpisodeID: r[3].(string), PositionSec: r[4]}
		resp.Results = append(resp.Results, row)
	}
	resp.ReturnedCount = len(resp.Results)
	raw, _ := json.Marshal(resp)
	return string(raw)
}

func TestFetchDongpiandiCommentsFilter(t *testing.T) {
	d := &Downloader{}
	client := dongpiandiStubClient(dongpiandiCommentFixture([][5]any{
		{"c1", "第一集真好看", "visible", "ep1", float64(65)},
		{"c2", "折叠低质", "folded", "ep1", float64(66)},
		{"c3", "别的集的", "visible", "ep2", float64(67)},
		{"c4", "无时间轴", "visible", "ep1", nil},
		{"c5", "负时间", "visible", "ep1", float64(-5)},
		{"c6", "字符串秒", "visible", "ep1", "120"},
	}, false, ""))
	items, err := d.fetchDongpiandiComments(context.Background(), client, "v1", "ep1")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 {
		t.Fatalf("want 2 items (c1/c6), got %d: %+v", len(items), items)
	}
	// c1=65s, c6=120s；按时间排序
	if items[0].ID != "c1" || items[0].TimeMS != 65000 || items[0].Text != "第一集真好看" {
		t.Fatalf("item0 wrong: %+v", items[0])
	}
	if items[1].ID != "c6" || items[1].TimeMS != 120000 {
		t.Fatalf("item1 wrong: %+v", items[1])
	}
}

func TestFetchDongpiandiCommentsPagination(t *testing.T) {
	d := &Downloader{}
	stub := &dongpiandiStubRoundTrip{bodies: []string{
		dongpiandiCommentFixture([][5]any{{"c1", "第一页", "visible", "ep1", float64(10)}}, true, "cursorA"),
		dongpiandiCommentFixture([][5]any{{"c2", "第二页", "visible", "ep1", float64(20)}}, false, ""),
	}}
	client := &dongpiandiClient{http: &http.Client{Timeout: 5 * time.Second, Transport: stub}}
	items, err := d.fetchDongpiandiComments(context.Background(), client, "v1", "ep1")
	if err != nil {
		t.Fatal(err)
	}
	if len(items) != 2 || stub.calls != 2 {
		t.Fatalf("pagination broken: items=%+v calls=%d", items, stub.calls)
	}
}

func TestDongpiandiDanmakuWindow(t *testing.T) {
	d := &Downloader{}
	d.dongpiandiDanmakuClient() // 初始化 store
	// 预置缓存条目（绕开 HTTP 测窗口逻辑）：30s/95s/400s 三条
	d.dongpiandiDanmakuStore.mu.Lock()
	d.dongpiandiDanmakuStore.entries["v1\x00ep1"] = dongpiandiDanmakuEntry{
		items: []hongguoDanmakuItem{
			{ID: "a", Text: "x", TimeMS: 30_000},
			{ID: "b", Text: "y", TimeMS: 95_000},
			{ID: "c", Text: "z", TimeMS: 400_000},
		},
		expires: time.Now().Add(time.Minute),
	}
	d.dongpiandiDanmakuStore.mu.Unlock()

	// 窗口 0 起：覆盖页一次覆盖全片（最晚 400s 条目 +30s=430s），
	// Dart 侧 _covering 命中后不再逐窗口空打；三条都在 [0,430s) 内
	page, err := d.dongpiandiDanmaku(context.Background(), "v1", "ep1", 0, 600_000)
	if err != nil {
		t.Fatal(err)
	}
	if page.StartMS != 0 || page.NextMS != 430_000 || len(page.Items) != 3 || page.EpisodeID != "ep1" || page.Total != 3 {
		t.Fatalf("window0 wrong: %+v", page)
	}

	// 起点 30s：同样覆盖到 430s，三条全在窗口内
	page, err = d.dongpiandiDanmaku(context.Background(), "v1", "ep1", 30_000, 600_000)
	if err != nil {
		t.Fatal(err)
	}
	if page.StartMS != 30_000 || len(page.Items) != 3 || page.Items[0].ID != "a" || page.Items[2].ID != "c" {
		t.Fatalf("window30 wrong: %+v", page)
	}
	if page.NextMS != 430_000 {
		t.Fatalf("cover page nextMs want 430000 got %d", page.NextMS)
	}

	// 起点 90s：30s 条目被裁掉，含 95s/400s 两条；覆盖页仍=430s
	page, err = d.dongpiandiDanmaku(context.Background(), "v1", "ep1", 90_000, 600_000)
	if err != nil {
		t.Fatal(err)
	}
	if page.NextMS != 430_000 || len(page.Items) != 2 || page.Items[0].ID != "b" || page.Items[1].ID != "c" {
		t.Fatalf("window90 wrong: %+v", page)
	}

	// 覆盖不超过视频总长：duration=300s 时 nextMs 截到 300s，400s 条目被裁掉
	page, err = d.dongpiandiDanmaku(context.Background(), "v1", "ep1", 90_000, 300_000)
	if err != nil {
		t.Fatal(err)
	}
	if page.NextMS != 300_000 || len(page.Items) != 1 || page.Items[0].ID != "b" {
		t.Fatalf("duration clamp broken: %+v", page)
	}

	// 参数校验
	if _, err := d.dongpiandiDanmaku(context.Background(), "v1", "ep1", -1, 600_000); err == nil {
		t.Fatal("negative start accepted")
	}
	if _, err := d.dongpiandiDanmaku(context.Background(), "", "ep1", 0, 600_000); err == nil {
		t.Fatal("empty variant accepted")
	}
	if _, err := d.dongpiandiDanmaku(context.Background(), "v1", "ep1", 0, 0); err == nil {
		t.Fatal("zero duration accepted")
	}
}

func TestDongpiandiPositionMS(t *testing.T) {
	cases := []struct {
		raw     any
		want    int64
		wantOK  bool
	}{
		{float64(366), 366_000, true},
		{"120", 120_000, true},
		{json.Number("7.5"), 7_500, true},
		{int(9), 9_000, true},
		{nil, 0, false},
		{"abc", 0, false},
		{float64(-5), 0, false},
		{float64(8 * 24 * 3600), 0, false},
		{true, 0, false},
	}
	for _, c := range cases {
		got, ok := dongpiandiPositionMS(c.raw)
		if ok != c.wantOK || (ok && got != c.want) {
			t.Fatalf("positionMS(%v) = %d,%v want %d,%v", c.raw, got, ok, c.want, c.wantOK)
		}
	}
}

func TestDongpiandiDanmakuText(t *testing.T) {
	if got := dongpiandiDanmakuText("  好看\t\t爱看\n"); got != "好看 爱看" {
		t.Fatalf("whitespace collapse wrong: %q", got)
	}
	if got := dongpiandiDanmakuText("a\x01b\u2028c"); got != "a b c" {
		t.Fatalf("control strip wrong: %q", got)
	}
	long := strings.Repeat("甲", 200)
	got := dongpiandiDanmakuText(long)
	if len([]rune(got)) != 181 || !strings.HasSuffix(got, "…") {
		t.Fatalf("truncate wrong: %d runes", len([]rune(got)))
	}
	if dongpiandiDanmakuText("   ") != "" {
		t.Fatal("blank should be empty")
	}
}
