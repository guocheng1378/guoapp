package core

// 直播列表测试：m3u/txt 解析、线路合并、双列表归组、缓存 TTL/过期兜底/磁盘恢复、
// live.channels dispatch（内置 + 自填源合并、自填源失败降级）。

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"
)

const liveTestM3U = `#EXTM3U
#EXTVLCOPT:http-user-agent=live
#EXTINF:-1 tvg-logo="http://logo.test/cctv1.png" group-title="央视",CCTV-1
http://stream.test/cctv1.m3u8
#EXTINF:-1 tvg-logo="http://logo.test/cctv2.png" group-title="央视,综合",CCTV-2
http://stream.test/cctv2.m3u8
#EXTINF:-1 tvg-name="CCTV3" group-title="央视"
http://stream.test/cctv3.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
http://stream.test/hntv.m3u8
http://stream.test/no-extinf.m3u8
#EXTINF:-1 group-title="卫视",坏频道
javascript:void(0)
#EXTINF:-1 group-title="卫视",无线视
not-a-url-at-all
#EXTINF:-1 group-title="卫视"
http://stream.test/unknown-name.m3u8
`

const liveTestTXT = `央视,#genre#
CCTV-1,http://a.test/1.m3u8#http://b.test/1.m3u8
CCTV-2,http://a.test/2.m3u8
卫视频道,#genre#
湖南卫视,http://a.test/hn.m3u8
坏行,not-a-url
无地址行
`

func TestParseLivePlaylistM3U(t *testing.T) {
	channels := parseLivePlaylist(liveTestM3U)
	if len(channels) != 5 {
		t.Fatalf("期望 5 个有效频道，得到 %d：%+v", len(channels), channels)
	}
	first := channels[0]
	if first.Name != "CCTV-1" || first.Group != "央视" || first.Logo != "http://logo.test/cctv1.png" {
		t.Fatalf("首频道解析错误：%+v", first)
	}
	if len(first.URLs) != 1 || first.URLs[0] != "http://stream.test/cctv1.m3u8" {
		t.Fatalf("首频道地址错误：%+v", first.URLs)
	}
	// 引号内的逗号不切标题：group 保留 "央视,综合"，标题是 CCTV-2。
	if channels[1].Group != "央视,综合" || channels[1].Name != "CCTV-2" {
		t.Fatalf("引号内逗号解析错误：%+v", channels[1])
	}
	// 无标题时 tvg-name 兜底。
	if channels[2].Name != "CCTV3" {
		t.Fatalf("tvg-name 兜底失败：%+v", channels[2])
	}
	// EXTINF 后无效 URL 行跳过；下一有效 URL 归属其 EXTINF。
	if channels[3].Name != "湖南卫视" {
		t.Fatalf("no-EXTINF/坏行跳过后归属错乱：%+v", channels[3])
	}
	// 无标题频道用 URL 派生名。
	if channels[4].Name != "unknown-name" {
		t.Fatalf("URL 派生名错误：%+v", channels[4])
	}
}

func TestParseLivePlaylistTXT(t *testing.T) {
	channels := parseLivePlaylist(liveTestTXT)
	if len(channels) != 3 {
		t.Fatalf("期望 3 个有效频道，得到 %d：%+v", len(channels), channels)
	}
	if channels[0].Name != "CCTV-1" || channels[0].Group != "央视" {
		t.Fatalf("txt 首频道错误：%+v", channels[0])
	}
	if len(channels[0].URLs) != 2 || channels[0].URLs[1] != "http://b.test/1.m3u8" {
		t.Fatalf("txt 多线路解析错误：%+v", channels[0].URLs)
	}
	if channels[2].Group != "卫视频道" {
		t.Fatalf("#genre# 分组错误：%+v", channels[2])
	}
}

func TestMergeLiveChannels(t *testing.T) {
	merged := mergeLiveChannels([]liveChannel{
		{Name: "CCTV-1", Group: "央视", URLs: []string{"http://a/1"}},
		{Name: "CCTV-1", Group: "央视", URLs: []string{"http://a/1", "http://b/1"}},
		{Name: "CCTV-2", Group: "央视", URLs: []string{"http://a/2"}},
		{Name: "CCTV-1", Group: "卫视", URLs: []string{"http://c/1"}},
		{Name: "空线路", Group: "卫视", URLs: nil},
	})
	if len(merged) != 3 {
		t.Fatalf("期望 3 个频道，得到 %d：%+v", len(merged), merged)
	}
	if len(merged[0].URLs) != 2 || merged[0].URLs[1] != "http://b/1" {
		t.Fatalf("同名频道未并线或未去重：%+v", merged[0])
	}
	if merged[2].Name != "CCTV-1" || merged[2].Group != "卫视" {
		t.Fatalf("不同分组同名频道不应合并：%+v", merged[2])
	}
}

func TestLiveGroupsFromLists(t *testing.T) {
	listA := mergeLiveChannels(parseLivePlaylist(liveTestM3U))
	listB := mergeLiveChannels(parseLivePlaylist(liveTestTXT))
	groups, count := liveGroupsFromLists(listA, listB)
	if count == 0 {
		t.Fatal("合并后频道总数为 0")
	}
	// 分组顺序保留首见：央视 → 卫视。
	if len(groups) < 2 || groups[0].Name != "央视" {
		t.Fatalf("分组首见顺序错误：%+v", groupNames(groups))
	}
	found := false
	for _, g := range groups {
		if g.Name != "央视" {
			continue
		}
		for _, ch := range g.Channels {
			if ch.Name == "CCTV-1" {
				found = true
				if len(ch.URLs) != 3 {
					t.Fatalf("跨列表同名频道应并成 3 线路（去重后），得到 %v", ch.URLs)
				}
			}
		}
	}
	if !found {
		t.Fatal("跨列表 CCTV-1 合并失败")
	}
	names := groupNames(groups)
	for i := 1; i < len(names); i++ {
		if names[i] == names[i-1] {
			t.Fatalf("分组名重复未合并：%v", names)
		}
	}
}

func groupNames(groups []liveGroup) []string {
	names := make([]string, 0, len(groups))
	for _, g := range groups {
		names = append(names, g.Name)
	}
	return names
}

func liveTestTransport(bodies map[string]string) rankingTransport {
	return func(request *http.Request) (*http.Response, error) {
		if body, ok := bodies[request.URL.String()]; ok {
			return rankingHTTPResponse(request, http.StatusOK, body), nil
		}
		return rankingHTTPResponse(request, http.StatusInternalServerError, "boom"), nil
	}
}

func newLiveTestEngine(t *testing.T, fn rankingTransport) (*nativeEngine, *Downloader) {
	t.Helper()
	d := rankingTestDownloader(t, fn)
	d.loadLiveCache()
	return &nativeEngine{downloader: d}, d
}

func withLiveBuiltInLists(t *testing.T, defs []liveListDef) {
	t.Helper()
	original := liveBuiltInLists
	liveBuiltInLists = defs
	t.Cleanup(func() { liveBuiltInLists = original })
}

func TestLiveChannelsFetchTTLAndStale(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	bodies := map[string]string{listURL: liveTestM3U}
	engine, _ := newLiveTestEngine(t, liveTestTransport(bodies))
	ctx := context.Background()

	input := nativeInput{Action: "live.channels", ListID: "test"}
	first, err := engine.nativeLive(ctx, input)
	if err != nil {
		t.Fatalf("首次获取失败：%v", err)
	}
	resp := first.(map[string]any)
	if resp["channelCount"].(int) != 5 {
		t.Fatalf("首次 channelCount 应为 5：%v", resp["channelCount"])
	}
	if resp["stale"].(bool) {
		t.Fatal("首次获取不应标记 stale")
	}
	lists, ok := resp["lists"].([]liveListDef)
	if !ok || len(lists) != 1 || lists[0].Name != "测试列表" {
		t.Fatalf("lists 字段错误：%+v", resp["lists"])
	}

	// TTL 内重复请求：直接命中内存缓存（即使源已挂也不重拉）。
	engine2, d2 := newLiveTestEngine(t, liveTestTransport(map[string]string{}))
	d2.live.entries["test"] = liveListEntry{
		Key:       "test",
		Channels:  mergeLiveChannels(parseLivePlaylist(liveTestM3U)),
		FetchedAt: time.Now(),
	}
	second, err := engine2.nativeLive(ctx, input)
	if err != nil {
		t.Fatalf("TTL 内请求失败：%v", err)
	}
	if second.(map[string]any)["stale"].(bool) {
		t.Fatal("TTL 内命中缓存不应标记 stale")
	}

	// force 重拉失败：回退过期缓存并标记 stale（独立引擎：缓存有旧条目、网络全挂）。
	engine3, d3 := newLiveTestEngine(t, liveTestTransport(map[string]string{}))
	d3.live.entries["test"] = liveListEntry{
		Key:       "test",
		Channels:  mergeLiveChannels(parseLivePlaylist(liveTestM3U)),
		FetchedAt: time.Now().Add(-25 * time.Hour),
	}
	third, err := engine3.nativeLive(ctx, nativeInput{Action: "live.channels", ListID: "test", Force: true})
	if err != nil {
		t.Fatalf("force 回退不应报错：%v", err)
	}
	resp3 := third.(map[string]any)
	if !resp3["stale"].(bool) {
		t.Fatal("force 重拉失败应标记 stale")
	}
	if resp3["channelCount"].(int) != 5 {
		t.Fatalf("stale 兜底应保留旧频道：%v", resp3["channelCount"])
	}
	if resp3["warning"].(string) == "" {
		t.Fatal("stale 兜底应携带 warning")
	}
}

func TestLiveCacheRestoreFromDisk(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	engine, d1 := newLiveTestEngine(t, liveTestTransport(map[string]string{listURL: liveTestM3U}))
	if _, err := engine.nativeLive(context.Background(), nativeInput{ListID: "test"}); err != nil {
		t.Fatalf("首取失败：%v", err)
	}
	d1.flushLiveCache()

	// 新引擎（新 transport 全 500）读同目录磁盘缓存：TTL 内不再打网络。
	d2 := &Downloader{cfg: defaultConfig()}
	d2.cfg.dataDir = d1.cfg.dataDir
	d2.client = &http.Client{Transport: liveTestTransport(nil)}
	d2.limiter = d1.limiter
	d2.loadLiveCache()
	if _, ok := d2.live.entries["test"]; !ok {
		t.Fatal("磁盘缓存未恢复")
	}
	engine2 := &nativeEngine{downloader: d2}
	resp, err := engine2.nativeLive(context.Background(), nativeInput{ListID: "test"})
	if err != nil {
		t.Fatalf("磁盘缓存恢复后请求失败：%v", err)
	}
	if resp.(map[string]any)["channelCount"].(int) != 5 {
		t.Fatalf("磁盘缓存频道数错误：%v", resp.(map[string]any)["channelCount"])
	}
}

func TestLiveChannelsMergesCustomSources(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	customURL := "https://custom.test/src.txt"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	engine, _ := newLiveTestEngine(t, liveTestTransport(map[string]string{
		listURL:   liveTestM3U,
		customURL: liveTestTXT,
	}))
	resp, err := engine.nativeLive(context.Background(), nativeInput{
		Action:   "live.channels",
		ListID:   "test",
		LiveURLs: []string{customURL},
	})
	if err != nil {
		t.Fatalf("合并自填源失败：%v", err)
	}
	data := resp.(map[string]any)
	groups := data["groups"].([]liveGroup)
	found := false
	for _, g := range groups {
		if g.Name != "央视" {
			continue
		}
		for _, ch := range g.Channels {
			if ch.Name == "CCTV-1" && len(ch.URLs) == 3 {
				found = true
			}
		}
	}
	if !found {
		t.Fatalf("内置与自填源未合并（CCTV-1 应 3 线路）：%+v", groups)
	}
	if data["warning"].(string) != "" {
		t.Fatalf("正常合并不应有 warning：%v", data["warning"])
	}

	// 自填源失败：仅告警，不影响内置列表。
	resp2, err := engine.nativeLive(context.Background(), nativeInput{
		Action:   "live.channels",
		ListID:   "test",
		LiveURLs: []string{"https://custom.test/dead.m3u", "not-a-url"},
	})
	if err != nil {
		t.Fatalf("自填源失败不应整体失败：%v", err)
	}
	data2 := resp2.(map[string]any)
	if data2["channelCount"].(int) != 5 {
		t.Fatalf("内置列表频道数应保留：%v", data2["channelCount"])
	}
	if data2["warning"].(string) == "" {
		t.Fatal("自填源失败应产生 warning")
	}
}

func TestLiveChannelsUnknownList(t *testing.T) {
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{"https://live.test/list.m3u"}}})
	engine, _ := newLiveTestEngine(t, liveTestTransport(nil))
	if _, err := engine.nativeLive(context.Background(), nativeInput{ListID: "nope"}); err == nil {
		t.Fatal("未知 listId 应报错")
	}
	// 默认回落第一个内置列表。
	engine2, _ := newLiveTestEngine(t, liveTestTransport(map[string]string{"https://live.test/list.m3u": liveTestM3U}))
	resp, err := engine2.nativeLive(context.Background(), nativeInput{})
	if err != nil {
		t.Fatalf("默认列表请求失败：%v", err)
	}
	if resp.(map[string]any)["listId"] != liveBuiltInLists[0].ID {
		t.Fatalf("默认 listId 错误：%v", resp.(map[string]any)["listId"])
	}
}

// TestLiveFetchTextLimits 验证 16MB 上限拦截。
func TestLiveFetchTextLimits(t *testing.T) {
	huge := strings.Repeat("#EXTINF:-1 t,x\nhttp://s/1.m3u8\n", 700000) // ~16MB+
	d := &Downloader{cfg: defaultConfig()}
	d.cfg.dataDir = t.TempDir()
	d.client = &http.Client{Transport: rankingTransport(func(request *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(request, http.StatusOK, huge), nil
	})}
	d.limiter = newRequestLimiter(8, time.Nanosecond)
	if _, err := d.fetchLiveText(context.Background(), "https://huge.test/x.m3u"); err == nil {
		t.Fatal("超大列表应被拒")
	}
}

// liveAdM3U 广告净化 fixture：复刻 guovin 列表实况——快手 CDN 点播循环/MP4 被
// 伪造成湖南/广东卫视线路（首线路即广告），另有购物频道与春晚回放（应豁免）。
const liveAdM3U = `#EXTM3U
#EXTINF:-1 group-title="卫视",湖南卫视
http://txmov2.a.kwimgs.com/hlsb.m3u8
#EXTINF:-1 group-title="卫视",湖南卫视
http://stream.test/hntv.m3u8
#EXTINF:-1 group-title="电视购物",家有购物
http://stream.test/shop.m3u8
#EXTINF:-1 group-title="央视",CCTV-1
http://stream.test/cctv1.m3u8
#EXTINF:-1 group-title="点播",春晚回放
http://txmov2.a.kwimgs.com/chunwan.mp4
#EXTINF:-1 group-title="卫视",广东卫视
http://alimov2.a.kwimgs.com/gd2023.mp4
`

func TestFilterLiveChannels(t *testing.T) {
	channels := filterLiveChannels(mergeLiveChannels(parseLivePlaylist(liveAdM3U)))
	// 家有购物（广告词）整频道剔除；湖南卫视 kwimgs 假线剔除、真线保留；
	// 广东卫视线路全为点播 CDN → 整频道删除；春晚回放豁免保留。
	if len(channels) != 3 {
		t.Fatalf("期望 3 个频道，得到 %d：%+v", len(channels), channels)
	}
	if channels[0].Name != "湖南卫视" || len(channels[0].URLs) != 1 || channels[0].URLs[0] != "http://stream.test/hntv.m3u8" {
		t.Fatalf("湖南卫视应剔 VOD 假线保留真线：%+v", channels[0])
	}
	if channels[1].Name != "CCTV-1" {
		t.Fatalf("正常频道不应被过滤：%+v", channels[1])
	}
	if channels[2].Name != "春晚回放" || len(channels[2].URLs) != 1 || !strings.Contains(channels[2].URLs[0], "kwimgs.com") {
		t.Fatalf("回放频道应豁免保留点播 CDN 线路：%+v", channels[2])
	}
}

func TestFilterLiveChannelsEmpty(t *testing.T) {
	if got := filterLiveChannels(nil); len(got) != 0 {
		t.Fatalf("空列表过滤应返回空：%+v", got)
	}
	only := filterLiveChannels([]liveChannel{{Name: "纯广告频道", Group: "购物", URLs: []string{"http://a.test/1.m3u8"}}})
	if len(only) != 0 {
		t.Fatalf("纯广告频道应被剔除：%+v", only)
	}
}

// TestLiveCacheRestoreFiltersAds 旧版本落盘缓存含广告线路：升级后磁盘恢复即净化，
// 无需等待 6h TTL 过期重拉。
func TestLiveCacheRestoreFiltersAds(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	engine, d1 := newLiveTestEngine(t, liveTestTransport(map[string]string{listURL: liveAdM3U}))
	if _, err := engine.nativeLive(context.Background(), nativeInput{ListID: "test"}); err != nil {
		t.Fatalf("首取失败：%v", err)
	}
	d1.flushLiveCache()

	d2 := &Downloader{cfg: defaultConfig()}
	d2.cfg.dataDir = d1.cfg.dataDir
	d2.client = &http.Client{Transport: liveTestTransport(nil)}
	d2.limiter = d1.limiter
	d2.loadLiveCache()
	entry, ok := d2.live.entries["test"]
	if !ok {
		t.Fatal("磁盘缓存未恢复")
	}
	if len(entry.Channels) != 3 {
		t.Fatalf("磁盘缓存恢复应净化为 3 频道，得到 %d：%+v", len(entry.Channels), entry.Channels)
	}
	for _, ch := range entry.Channels {
		if ch.Name == "家有购物" || ch.Name == "广东卫视" {
			t.Fatalf("广告/纯 VOD 频道应被剔除：%+v", ch)
		}
		if ch.Name == "湖南卫视" && len(ch.URLs) != 1 {
			t.Fatalf("湖南卫视缓存恢复应只剩真线：%+v", ch)
		}
	}
}
