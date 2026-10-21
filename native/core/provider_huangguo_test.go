package core

import (
	"strings"
	"testing"
)

// TestParseAIEpisodesFiltersForeignLinks 详情页「相关推荐」的外部视频
// （/video/{其他ID}/）不是本剧剧集，必须过滤；ep-N 链接键归一成纯数字
// 且序号取自链接而非出现顺序；自链接（/video/{sourceID}/）补位第 1 集。
// 2026-10-20 真网实测：推荐位泄漏会把 1 真集混成 15 集，且 ep-2 经
// Index 兜底错配到 epPlaySrcs["1"]（第 1 集地址）导致播错集。
func TestParseAIEpisodesFiltersForeignLinks(t *testing.T) {
	body := `<!doctype html><html><body>
<a href="/video/9520/" title="空少男友">播放</a>
<a href="/video/5667/ep-2/" title="东京牛头人">推荐</a>
<a href="/video/9520/ep-2/"><span>第2集</span></a>
<a href="/video/9520/ep-3/"><span>第3集</span></a>
</body></html>`
	eps := parseHuangguoAIEpisodes(body, "https://huangguoai.com/video/9520/", "9520")
	if len(eps) != 3 {
		t.Fatalf("want 3 episodes (self+ep2+ep3), got %d: %+v", len(eps), eps)
	}
	for i, ep := range eps {
		if ep.Index != i+1 {
			t.Fatalf("episode %d has index %d, want %d", i, ep.Index, i+1)
		}
	}
	if eps[0].Key != "1" || eps[1].Key != "2" || eps[2].Key != "3" {
		t.Fatalf("keys not normalized to numbers: %q %q %q", eps[0].Key, eps[1].Key, eps[2].Key)
	}
	for _, ep := range eps[1:] {
		if strings.Contains(ep.URL, "5667") {
			t.Fatalf("foreign recommendation leaked into episodes: %s", ep.URL)
		}
	}
	if !strings.HasSuffix(eps[1].URL, "/video/9520/ep-2/") || !strings.HasSuffix(eps[2].URL, "/video/9520/ep-3/") {
		t.Fatalf("episode page URLs wrong: %q %q", eps[1].URL, eps[2].URL)
	}
}

// TestParseAIEpisodeMediaMap 仅当 videoInitialData 的 epPlaySrcs 存在且
// 值能归一成 http(s) m3u8/mp4 时才产出映射。
func TestParseAIEpisodeMediaMap(t *testing.T) {
	body := `<html><script id="videoInitialData">{"ep":"1","videoSrc":"https://cdn.example/v1.m3u8","epPlaySrcs":{"1":"https://cdn.example/v1.m3u8?auth_key=1-0-0-x","2":"https://cdn.example/v2.m3u8","3":"not-a-url"},"videoApi":"/api/video"}</script></html>`
	m := parseAIEpisodeMediaMap(body, "https://huangguoai.com/video/9520/")
	if len(m) != 2 {
		t.Fatalf("want 2 valid entries, got %d: %v", len(m), m)
	}
	if m["1"] != "https://cdn.example/v1.m3u8?auth_key=1-0-0-x" || m["2"] != "https://cdn.example/v2.m3u8" {
		t.Fatalf("entries not normalized: %v", m)
	}
	if got := parseAIEpisodeMediaMap("<html>no data</html>", "https://x.com/"); got != nil {
		t.Fatalf("want nil without videoInitialData, got %v", got)
	}
}

// TestMergeAIEpisodeMedia epPlaySrcs 是全集地址的权威来源：按 Key/Index
// 回填；映射未覆盖的集保留空 HLS（resolve 走 ep-N 页面按需解析）；
// 无链接剧集时按映射合成；键风格不同（"01" vs "1"）经 Index 兜底命中。
func TestMergeAIEpisodeMedia(t *testing.T) {
	detailURL := "https://huangguoai.com/video/9520/"
	map12 := map[string]string{"1": "https://cdn.example/v1.m3u8", "2": "https://cdn.example/v2.m3u8"}

	t.Run("fills mapped and keeps unmapped", func(t *testing.T) {
		eps := []providerEpisode{
			{Key: "1", Title: "空少男友", URL: detailURL, Index: 1},
			{Key: "2", Title: "第2集", URL: detailURL + "ep-2/", Index: 2},
			{Key: "3", Title: "第3集", URL: detailURL + "ep-3/", Index: 3},
		}
		got := mergeAIEpisodeMedia(eps, map12, detailURL)
		if len(got) != 3 {
			t.Fatalf("want 3 episodes, got %d", len(got))
		}
		if got[0].HLS != map12["1"] || got[1].HLS != map12["2"] {
			t.Fatalf("mapped episodes not filled: %q %q", got[0].HLS, got[1].HLS)
		}
		if got[2].HLS != "" {
			t.Fatalf("unmapped episode must keep PageURL path, got %q", got[2].HLS)
		}
	})

	t.Run("synthesizes when no links parsed", func(t *testing.T) {
		got := mergeAIEpisodeMedia(nil, map12, detailURL)
		if len(got) != 2 {
			t.Fatalf("want 2 synthesized episodes, got %d", len(got))
		}
		if got[0].Key != "1" || got[0].HLS != map12["1"] || got[0].Index != 1 {
			t.Fatalf("first synthesized episode wrong: %+v", got[0])
		}
		if got[1].Key != "2" || got[1].Index != 2 {
			t.Fatalf("second synthesized episode wrong: %+v", got[1])
		}
	})

	t.Run("index fallback covers slug key mismatch", func(t *testing.T) {
		eps := []providerEpisode{{Key: "01", Title: "第1集", URL: detailURL, Index: 1}}
		got := mergeAIEpisodeMedia(eps, map[string]string{"1": "https://cdn.example/v1.m3u8"}, detailURL)
		if got[0].HLS != "https://cdn.example/v1.m3u8" {
			t.Fatalf("index fallback fill failed: %+v", got[0])
		}
	})

	t.Run("no map returns episodes untouched", func(t *testing.T) {
		eps := []providerEpisode{{Key: "1", Title: "x", URL: detailURL, Index: 1}}
		got := mergeAIEpisodeMedia(eps, nil, detailURL)
		if len(got) != 1 || got[0].HLS != "" {
			t.Fatalf("episodes modified without map: %+v", got)
		}
	})
}
