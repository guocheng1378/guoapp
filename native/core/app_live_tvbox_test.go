package core

import (
	"context"
	"net/http"
	"testing"
)

// TVBox 兼容 P1：JSON 频道列表解析、自填订阅自定义请求头、配置内嵌频道正文。

func TestParseLivePlaylistJSONChannels(t *testing.T) {
	const body = `{
  "lives": [
    {"name": "央视组", "channels": [
      {"name": "CCTV1", "group": "央视", "urls": ["http://stream.test/1.m3u8", "http://stream.test/1b.m3u8"]},
      {"name": "CCTV5", "url": "http://stream.test/5.m3u8"}
    ]},
    {"name": "订阅引用", "url": "https://live.test/list.m3u"}
  ]
}`
	channels := parseLivePlaylist(body)
	if len(channels) != 2 {
		t.Fatalf("JSON 应解析出 2 个频道（订阅引用不算频道），得到 %d: %+v", len(channels), channels)
	}
	if channels[0].Name != "CCTV1" || channels[0].Group != "央视" {
		t.Fatalf("首个频道字段错误：%+v", channels[0])
	}
	if len(channels[0].URLs) != 2 || channels[0].URLs[1] != "http://stream.test/1b.m3u8" {
		t.Fatalf("多线路解析错误：%+v", channels[0].URLs)
	}
	if channels[1].Name != "CCTV5" || channels[1].Group != "央视组" {
		t.Fatalf("分组继承错误：%+v", channels[1])
	}
	if len(channels[1].URLs) != 1 || channels[1].URLs[0] != "http://stream.test/5.m3u8" {
		t.Fatalf("单 url 频道解析错误：%+v", channels[1].URLs)
	}
}

func TestParseLivePlaylistJSONArray(t *testing.T) {
	channels := parseLivePlaylist(`[
  {"name": "CCTV1", "url": "http://stream.test/1.m3u8"},
  {"name": "坏频道", "url": "not-a-url"}
]`)
	if len(channels) != 1 || channels[0].Name != "CCTV1" {
		t.Fatalf("顶层数组解析错误：%+v", channels)
	}
	// 非法 JSON 应回落到 txt 解析而不是 panic。
	if got := parseLivePlaylist(`{broken`); len(got) != 0 {
		t.Fatalf("非法 JSON 不应产生频道：%+v", got)
	}
}

func TestLiveChannelsCustomHeaders(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	customURL := "https://custom.test/src.txt"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	var seenAgent, seenToken string
	transport := func(request *http.Request) (*http.Response, error) {
		switch request.URL.String() {
		case customURL:
			seenAgent = request.Header.Get("User-Agent")
			seenToken = request.Header.Get("X-Token")
			return rankingHTTPResponse(request, http.StatusOK, liveTestTXT), nil
		case listURL:
			return rankingHTTPResponse(request, http.StatusOK, liveTestM3U), nil
		default:
			return rankingHTTPResponse(request, http.StatusInternalServerError, "boom"), nil
		}
	}
	engine, _ := newLiveTestEngine(t, transport)
	resp, err := engine.nativeLive(context.Background(), nativeInput{
		Action: "live.channels",
		ListID: "test",
		LiveSources: []liveSourceInput{{
			URL: customURL,
			Headers: map[string]string{
				"User-Agent": "UA-Custom",
				"X-Token":    "abc",
				"Host":       "evil.test",
			},
		}},
	})
	if err != nil {
		t.Fatalf("带请求头的自填源合并失败：%v", err)
	}
	if resp.(map[string]any)["channelCount"].(int) == 0 {
		t.Fatal("带请求头的自填源应产出频道")
	}
	if seenAgent != "UA-Custom" || seenToken != "abc" {
		t.Fatalf("自定义请求头未透传：UA=%q X-Token=%q", seenAgent, seenToken)
	}
}

func TestLiveChannelsInlinePayload(t *testing.T) {
	listURL := "https://live.test/list.m3u"
	withLiveBuiltInLists(t, []liveListDef{{ID: "test", Name: "测试列表", Candidates: []string{listURL}}})
	engine, _ := newLiveTestEngine(t, liveTestTransport(map[string]string{listURL: liveTestM3U}))
	const payload = `{"channels":[{"name":"内联频道","urls":["http://stream.test/inline.m3u8"]}]}`
	resp, err := engine.nativeLive(context.Background(), nativeInput{
		Action: "live.channels",
		ListID: "test",
		LiveSources: []liveSourceInput{{
			URL:     "inline:0",
			Payload: payload,
		}},
	})
	if err != nil {
		t.Fatalf("内联订阅合并失败：%v", err)
	}
	// 内置 5 个 + 内联 1 个；内联频道没有走 HTTP 也不会被 transport 拦截。
	if count := resp.(map[string]any)["channelCount"].(int); count != 6 {
		t.Fatalf("内联频道未合并，channelCount=%d", count)
	}
}

func TestLiveHeaderCacheSuffix(t *testing.T) {
	if liveHeaderCacheSuffix(nil) != "" {
		t.Fatal("无请求头时不应改变缓存 key")
	}
	a := liveHeaderCacheSuffix(map[string]string{"X-Token": "1"})
	b := liveHeaderCacheSuffix(map[string]string{"X-Token": "2"})
	if a == "" || a == b {
		t.Fatalf("不同请求头必须落到不同缓存：a=%q b=%q", a, b)
	}
	if a != liveHeaderCacheSuffix(map[string]string{"X-Token": "1"}) {
		t.Fatal("相同请求头的缓存 key 必须稳定")
	}
	if sanitizeLiveHeaders(map[string]string{"Host": "evil", "X": "a\r\nb"}) != nil {
		t.Fatal("非法请求头应被丢弃")
	}
}
