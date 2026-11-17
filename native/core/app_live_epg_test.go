package core

// EPG（电子节目单）测试：台名归一/别名、xmltv 流式解析与命中裁剪、GBK 编码、
// now/next 判定、live.epg 端到端（含缓存与负缓存）、m3u 的 tvg-id 透传。

import (
	"context"
	"fmt"
	"net/http"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

func liveEpgStamp(t time.Time) string { return t.Format("20060102150405 -0700") }

// liveEpgFixtureXML 生成一份「今天中午」的 xmltv：CCTV-1（id 与台名两种命中方式）、
// 湖南卫视（别名命中）、一个与请求无关的购物频道（必须被丢弃）。
func liveEpgFixtureXML(day time.Time) string {
	at := func(hour, minute int) time.Time {
		return time.Date(day.Year(), day.Month(), day.Day(), hour, minute, 0, 0, time.Local)
	}
	return fmt.Sprintf(`<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="test">
  <channel id="cctv1.hd"><display-name lang="zh">CCTV-1 综合</display-name></channel>
  <channel id="hunan.tv"><display-name>湖南卫视高清</display-name></channel>
  <channel id="shop.tv"><display-name>购物频道</display-name></channel>
  <programme start="%s" stop="%s" channel="cctv1.hd"><title lang="zh">新闻联播</title><desc>19点档</desc></programme>
  <programme start="%s" stop="%s" channel="cctv1.hd"><title>焦点访谈</title></programme>
  <programme start="%s" stop="%s" channel="hunan.tv"><title>快乐大本营</title></programme>
  <programme start="%s" stop="%s" channel="shop.tv"><title>不该被回传</title></programme>
</tv>`,
		liveEpgStamp(at(12, 0)), liveEpgStamp(at(12, 30)),
		liveEpgStamp(at(12, 30)), liveEpgStamp(at(13, 0)),
		liveEpgStamp(at(20, 0)), liveEpgStamp(at(21, 0)),
		liveEpgStamp(at(9, 0)), liveEpgStamp(at(10, 0)),
	)
}

func TestLiveChannelKeyNormalization(t *testing.T) {
	same := [][]string{
		{"CCTV-1", "CCTV1", "cctv1", "CCTV-1 综合", "央视一套", "CCTV1高清"},
		{"CCTV5+", "cctv5+", "CCTV-5+", "央视五套加"},
		{"湖南卫视", "湖南卫视高清", "湖南卫视HD"},
		{"CCTV-13", "CCTV13 新闻", "新闻频道"},
	}
	for _, group := range same {
		want := liveChannelKey(group[0])
		if want == "" {
			t.Fatalf("%q 归一结果为空", group[0])
		}
		for _, name := range group[1:] {
			if got := liveChannelKey(name); got != want {
				t.Fatalf("%q 归一为 %q，期望与 %q 一致(%q)", name, got, group[0], want)
			}
		}
	}
	// CCTV5 与 CCTV5+ 是两个频道：折掉 '+' 会把它们并成一个。
	if liveChannelKey("CCTV5") == liveChannelKey("CCTV5+") {
		t.Fatal("CCTV5 与 CCTV5+ 不应归一成同一个键")
	}
	// 全角写法等价。
	if liveChannelKey("ＣＣＴＶ－１") != liveChannelKey("CCTV-1") {
		t.Fatal("全角字符未归一")
	}
}

func TestParseLiveM3UKeepsTVGID(t *testing.T) {
	playlist := `#EXTM3U
#EXTINF:-1 tvg-id="cctv1.hd" tvg-name="CCTV1" tvg-logo="http://logo.test/1.png" group-title="央视",CCTV-1
http://stream.test/1.m3u8
#EXTINF:-1 tvg-id="hunan.tv" group-title="卫视",湖南卫视
http://stream.test/2.m3u8
#EXTINF:-1 group-title="卫视",无标识频道
http://stream.test/3.m3u8
`
	channels := parseLivePlaylist(playlist)
	if len(channels) != 3 {
		t.Fatalf("期望 3 个频道，得到 %d", len(channels))
	}
	if channels[0].TVGID != "cctv1.hd" {
		t.Fatalf("tvg-id 未透传：%+v", channels[0])
	}
	if channels[2].TVGID != "" {
		t.Fatalf("无 tvg-id 的频道不应凭空生成：%+v", channels[2])
	}
	merged := mergeLiveChannels([]liveChannel{
		{Name: "CCTV-1", Group: "央视", URLs: []string{"http://a/1"}},
		{Name: "CCTV-1", Group: "央视", TVGID: "cctv1.hd", URLs: []string{"http://b/1"}},
	})
	if len(merged) != 1 || merged[0].TVGID != "cctv1.hd" {
		t.Fatalf("并线时 tvg-id 丢失：%+v", merged)
	}
}

func TestLiveEpgParseMatchesRequestedChannels(t *testing.T) {
	body := liveEpgFixtureXML(time.Now())
	targets := &liveEpgParseTargets{
		byID:   map[string]string{"cctv1.hd": "tvg:cctv1.hd"},
		byKey:  map[string]string{liveChannelKey("湖南卫视"): "name:湖南卫视"},
		idRef:  map[string]string{},
		idKind: map[string]string{},
		rows:   map[string][]liveEpgRow{},
	}
	if err := liveEpgParseStream(strings.NewReader(body), targets); err != nil {
		t.Fatalf("解析失败：%v", err)
	}
	if targets.idKind["cctv1.hd"] != "tvgId" {
		t.Fatalf("tvg-id 命中方式错误：%+v", targets.idKind)
	}
	if targets.idKind["hunan.tv"] != "name" {
		t.Fatalf("台名命中方式错误：%+v", targets.idKind)
	}
	if _, ok := targets.idRef["shop.tv"]; ok {
		t.Fatal("未请求的频道不应进入结果集")
	}
	if got := len(targets.rows["cctv1.hd"]); got != 2 {
		t.Fatalf("CCTV-1 应解析出 2 条节目，得到 %d", got)
	}
	if targets.rows["hunan.tv"][0].title != "快乐大本营" {
		t.Fatalf("标题解析错误：%+v", targets.rows["hunan.tv"])
	}
}

func TestLiveEpgGBKEncodedPlaylist(t *testing.T) {
	body := `<?xml version="1.0" encoding="GB2312"?>
<tv>
  <channel id="cctv1"><display-name>CCTV-1</display-name></channel>
  <programme start="20260101120000 +0800" stop="20260101123000 +0800" channel="cctv1"><title>新闻联播</title></programme>
</tv>`
	encoded, _, err := transform.Bytes(simplifiedchinese.GBK.NewEncoder(), []byte(body))
	if err != nil {
		t.Fatalf("构造 GBK 数据失败：%v", err)
	}
	targets := &liveEpgParseTargets{
		byID:   map[string]string{"cctv1": "tvg:cctv1"},
		byKey:  map[string]string{},
		idRef:  map[string]string{},
		idKind: map[string]string{},
		rows:   map[string][]liveEpgRow{},
	}
	if err := liveEpgParseStream(strings.NewReader(string(encoded)), targets); err != nil {
		t.Fatalf("GBK 解析失败：%v", err)
	}
	if len(targets.rows["cctv1"]) != 1 || targets.rows["cctv1"][0].title != "新闻联播" {
		t.Fatalf("GBK 中文标题解析错误：%+v", targets.rows["cctv1"])
	}
}

func TestLiveEpgBuildChannelNowNext(t *testing.T) {
	now := time.Date(2026, 11, 8, 20, 10, 0, 0, time.Local)
	dayStart := time.Date(2026, 11, 8, 0, 0, 0, 0, time.Local)
	rows := []liveEpgRow{
		{title: "早间新闻", start: now.Add(-10 * time.Hour), stop: now.Add(-9 * time.Hour)},
		{title: "晚间新闻", start: now.Add(-20 * time.Minute), stop: now.Add(10 * time.Minute)},
		{title: "电视剧", start: now.Add(10 * time.Minute), stop: now.Add(70 * time.Minute)},
		{title: "明天的节目", start: now.Add(30 * time.Hour), stop: now.Add(31 * time.Hour)},
	}
	result, ok := liveEpgBuildChannel(rows, now, dayStart, now.Add(24*time.Hour))
	if !ok {
		t.Fatal("有节目应判定为命中")
	}
	if result.Now == nil || result.Now.Title != "晚间新闻" {
		t.Fatalf("now 判定错误：%+v", result.Now)
	}
	if result.Next == nil || result.Next.Title != "电视剧" {
		t.Fatalf("next 判定错误：%+v", result.Next)
	}
	if len(result.Programs) != 3 {
		t.Fatalf("应回传当日 3 条节目（明天的丢弃），得到 %d", len(result.Programs))
	}
	if result.Programs[0].Start == "" || result.Programs[0].Stop == "" {
		t.Fatalf("时间未序列化：%+v", result.Programs[0])
	}
	// 没有正在播的节目时 now 留空，next 指向下一档。
	onlyFuture := []liveEpgRow{{title: "稍后", start: now.Add(5 * time.Minute), stop: now.Add(35 * time.Minute)}}
	later, _ := liveEpgBuildChannel(onlyFuture, now, dayStart, now.Add(24*time.Hour))
	if later.Now != nil {
		t.Fatalf("无当前节目时 now 应为空：%+v", later.Now)
	}
	if later.Next == nil || later.Next.Title != "稍后" {
		t.Fatalf("next 应指向稍后：%+v", later.Next)
	}
}

// liveEpgCountingTransport 记录 EPG 请求次数，用缓存命中/负缓存判定是否重复拉取。
func liveEpgCountingTransport(body string, hits *int32) rankingTransport {
	return func(request *http.Request) (*http.Response, error) {
		atomic.AddInt32(hits, 1)
		return rankingHTTPResponse(request, http.StatusOK, body), nil
	}
}

func TestLiveEpgEndToEndAndCache(t *testing.T) {
	var hits int32
	epgURL := "https://epg.test/pp.xml"
	engine, _ := newLiveTestEngine(t, liveEpgCountingTransport(liveEpgFixtureXML(time.Now()), &hits))
	input := nativeInput{
		Action:      "live.epg",
		LiveEPG:     []liveSourceInput{{URL: epgURL}},
		EpgChannels: []liveEpgRef{{Name: "CCTV-1"}, {Name: "湖南卫视"}, {Name: "不存在的台"}},
	}
	first, err := engine.nativeLiveEpg(context.Background(), input)
	if err != nil {
		t.Fatalf("EPG 获取失败：%v", err)
	}
	result := first.(liveEpgResult)
	if len(result.Channels) != 3 {
		t.Fatalf("结果应按请求顺序返回 3 项，得到 %d", len(result.Channels))
	}
	if !result.Channels[0].Matched || result.Channels[0].Match != "name" {
		t.Fatalf("CCTV-1 应通过台名命中：%+v", result.Channels[0])
	}
	if !result.Channels[1].Matched {
		t.Fatalf("湖南卫视应命中别名：%+v", result.Channels[1])
	}
	if result.Channels[2].Matched {
		t.Fatalf("不存在的台不应命中：%+v", result.Channels[2])
	}
	if len(result.Channels[0].Programs) != 2 {
		t.Fatalf("CCTV-1 应回传 2 条节目：%+v", result.Channels[0].Programs)
	}
	for _, item := range result.Channels[0].Programs {
		if item.Title == "不该被回传" {
			t.Fatal("未命中的购物频道节目泄漏进了结果")
		}
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("首次应只请求一次 EPG，实际 %d", got)
	}

	second, err := engine.nativeLiveEpg(context.Background(), input)
	if err != nil {
		t.Fatalf("二次请求失败：%v", err)
	}
	if !second.(liveEpgResult).Cached {
		t.Fatal("TTL 内应命中缓存")
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("缓存命中不应重复拉取，实际请求 %d 次", got)
	}

	// 换一组频道：缓存签名不同，必须重新拉取。
	_, err = engine.nativeLiveEpg(context.Background(), nativeInput{
		Action:      "live.epg",
		LiveEPG:     []liveSourceInput{{URL: epgURL}},
		EpgChannels: []liveEpgRef{{Name: "购物频道"}},
	})
	if err != nil {
		t.Fatalf("换频道请求失败：%v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 2 {
		t.Fatalf("请求频道集合变化应重新拉取，实际 %d", got)
	}
}

func TestLiveEpgEmptySourcesMakeNoRequest(t *testing.T) {
	var hits int32
	engine, _ := newLiveTestEngine(t, liveEpgCountingTransport(liveEpgFixtureXML(time.Now()), &hits))
	for _, input := range []nativeInput{
		{Action: "live.epg", EpgChannels: []liveEpgRef{{Name: "CCTV-1"}}},
		{Action: "live.epg", LiveEPG: []liveSourceInput{{URL: "ftp://epg.test/pp.xml"}}, EpgChannels: []liveEpgRef{{Name: "CCTV-1"}}},
		{Action: "live.epg", LiveEPG: []liveSourceInput{{URL: "https://epg.test/pp.xml"}}},
	} {
		result, err := engine.nativeLiveEpg(context.Background(), input)
		if err != nil {
			t.Fatalf("无源/无频道时不应报错：%v", err)
		}
		if len(result.(liveEpgResult).Channels) != 0 {
			t.Fatalf("无源/无频道时应返回空结果：%+v", result)
		}
	}
	if hits != 0 {
		t.Fatalf("无有效源时不应发起网络请求，实际 %d", hits)
	}
}

func TestLiveEpgFailureUsesNegativeCache(t *testing.T) {
	var hits int32
	engine, _ := newLiveTestEngine(t, func(request *http.Request) (*http.Response, error) {
		atomic.AddInt32(&hits, 1)
		return rankingHTTPResponse(request, http.StatusInternalServerError, "boom"), nil
	})
	input := nativeInput{
		Action:      "live.epg",
		LiveEPG:     []liveSourceInput{{URL: "https://epg.test/dead.xml"}},
		EpgChannels: []liveEpgRef{{Name: "CCTV-1"}},
	}
	first, err := engine.nativeLiveEpg(context.Background(), input)
	if err != nil {
		t.Fatalf("源失败不应整体报错：%v", err)
	}
	result := first.(liveEpgResult)
	if result.Warning == "" {
		t.Fatal("源失败应带 warning")
	}
	if result.Channels[0].Matched {
		t.Fatal("源失败不应命中频道")
	}
	if _, err := engine.nativeLiveEpg(context.Background(), input); err != nil {
		t.Fatalf("二次失败请求报错：%v", err)
	}
	if got := atomic.LoadInt32(&hits); got != 1 {
		t.Fatalf("失败应走负缓存，实际请求 %d 次", got)
	}
}
