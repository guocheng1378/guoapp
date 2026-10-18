package maccmsweb

import (
	"strings"
	"testing"

	"golang.org/x/net/html"

	"duanjuapp/native/provider"
)

func TestPlayerParsingHandlesCommonShells(t *testing.T) {
	playerShell := `<html><script>var player_aaaa={"flag":"1","url":"https:\/\/cdn.example.cn\/hls\/index.m3u8"}</script></html>`
	if got := provider.NormalizePlaybackURL(provider.PlayerURL(playerShell)); got != "https://cdn.example.cn/hls/index.m3u8" {
		t.Fatalf("player url parsing is wrong: %q", got)
	}
	encodedShell := `<html><script>var player_aaaa={"url":"https://cdn.example.cn/p.\/u6d4b\u8bd5\/index.m3u8"}</script></html>`
	got := provider.NormalizePlaybackURL(provider.PlayerURL(encodedShell))
	if !strings.Contains(got, "index.m3u8") || strings.Contains(got, `\u`) {
		t.Fatalf("encoded folder handling is wrong: %q", got)
	}
	if got := provider.PlayerURL(`<html>no player here</html>`); got != "" {
		t.Fatalf("should not invent a url: %q", got)
	}
}

func TestAcceptsHashedClassNamesAndWidenedEpisodes(t *testing.T) {
	document, err := html.Parse(strings.NewReader(`<html><body>
	<ul id="home1" class="_9dbe81752a1dbf17-vodlist clearfix">
	<li class="_9dbe81752a1dbf17-vodlist__item">
	<a class="_9dbe81752a1dbf17-vodlist__thumb lazyload" href="/zywview/20523.html" title="不做替身后被长公主截胡赐婚" data-original="https://pic.example.cn/a.jpg"><span class="pic-text">全集</span></a>
	<h4 class="_9dbe81752a1dbf17-vodlist__title"><a href="/zywview/20523.html" title="不做替身后被长公主截胡赐婚">不做替身后被长..</a></h4>
	</li></ul></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	source := New(provider.Spec{ID: provider.SourceHuaguo})
	cards := source.cards(document, "https://www.example.cn")
	if len(cards) != 1 || cards[0].SourceID != "20523" {
		t.Fatalf("hashed class cards are wrong: %+v", cards)
	}
	if cards[0].Cover != "https://pic.example.cn/a.jpg" {
		t.Fatalf("hashed class cover is wrong: %q", cards[0].Cover)
	}
	if cards[0].DisplayTitle() != "不做替身后被长公主截胡赐婚" {
		t.Fatalf("hashed class title is wrong: %q", cards[0].DisplayTitle())
	}

	detail, err := html.Parse(strings.NewReader(`<html><body>
	<div class="pcDrama_catalogList">
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/45856/sid/1/nid/1.html">第1集</a>
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/45856/sid/1/nid/2.html">第2集</a>
	</div></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	episodes := episodesFromDocument(detail)
	if len(episodes) != 2 {
		t.Fatalf("catalog item episodes are wrong: %+v", episodes)
	}
}

func TestDetailCandidatesMatchLiveSites(t *testing.T) {
	cases := map[string]string{
		provider.SourceWuguo:   "https://www.example.cn/index.php/vod/detail/id/45856.html",
		provider.SourceWangguo: "https://www.example.cn/vod/48478.html",
		provider.SourceHuaguo:  "https://www.example.cn/zywview/20523.html",
	}
	for source, want := range cases {
		got := profiles[source].detailURLs("https://www.example.cn", firstNumericTail(want))
		if len(got) == 0 || got[0] != want {
			t.Fatalf("%s detail candidate is wrong: %v", source, got)
		}
	}
}

func firstNumericTail(address string) string {
	cleaned := strings.TrimSuffix(address, ".html")
	parts := strings.Split(cleaned, "/")
	for index := len(parts) - 1; index >= 0; index-- {
		if provider.IsNumericID(parts[index]) {
			return parts[index]
		}
	}
	return ""
}

func TestFallsBackToDetailAnchors(t *testing.T) {
	document, err := html.Parse(strings.NewReader(`<html><body>
	<div class="random-hash-outer"><ul><li class="x1 y2 z3"><div class="q9 w8 e7 thumb">
	<a class="a1 b2 v-thumb stui-vodlist__thumb lazyload" href="/xzyxvd/269321.html" title="都市古仙医" data-original="https://image.example.cn/a.jpg">
	<span class="c3 pic-text text-right">第216集</span></a></div></li></ul></div></body></html>`))
	if err != nil {
		t.Fatal(err)
	}
	source := New(provider.Spec{ID: provider.SourceFaguo})
	cards := source.cards(document, "https://www.example.cn")
	if len(cards) != 1 || cards[0].SourceID != "269321" {
		t.Fatalf("anchor fallback cards are wrong: %+v", cards)
	}
	if cards[0].DisplayTitle() != "都市古仙医" || cards[0].Remark != "第216集" {
		t.Fatalf("anchor fallback metadata is wrong: %+v", cards[0])
	}
	if cards[0].Cover != "https://image.example.cn/a.jpg" {
		t.Fatalf("anchor fallback cover is wrong: %q", cards[0].Cover)
	}
}

func TestCleanTitleStripsLiveSeoSuffixes(t *testing.T) {
	cases := map[string]string{
		"黑月光归来-短剧黑月光归来全集-黑月光归来免费在线观看 - 免费五五短剧视频分享大全 - 最新的免费短剧视频": "黑月光归来",
		"修仙入世我在都市当靠山_高清完整版在线观看_爽文短剧 - 短剧网":                       "修仙入世我在都市当靠山",
		"三万月薪，我自己做主-短剧三万月薪，我自己做主全集-三万月薪，我自己做主免费在线观看":             "三万月薪，我自己做主",
		"不做替身后被长公主截胡赐婚 - 花生短剧":                                   "不做替身后被长公主截胡赐婚",
		"九转星辰诀":   "九转星辰诀",
		"我的剧-第二季": "我的剧-第二季",
	}
	for input, want := range cases {
		if got := cleanTitle(input); got != want {
			t.Fatalf("clean %q => %q, want %q", input, got, want)
		}
	}
}

func TestNormalizePlaybackURLStripsTrailingPunctuation(t *testing.T) {
	cases := map[string]string{
		"https://cdn.example.cn/wjv11/202508/15/SnEXGkSedD83/video/index.m3u8,": "https://cdn.example.cn/wjv11/202508/15/SnEXGkSedD83/video/index.m3u8",
		"https://cdn.example.cn/a/index.m3u8。":                                  "https://cdn.example.cn/a/index.m3u8",
		"https://cdn.example.cn/a/index.m3u8":                                   "https://cdn.example.cn/a/index.m3u8",
		`https:\/\/cdn.example.cn\/a\/index.m3u8\,`:                             "https://cdn.example.cn/a/index.m3u8",
	}
	for input, want := range cases {
		if got := provider.NormalizePlaybackURL(input); got != want {
			t.Fatalf("normalize %q => %q, want %q", input, got, want)
		}
	}
	if got := provider.NormalizePlaybackURL(","); got != "" {
		t.Fatalf("punctuation-only input should normalize to empty, got %q", got)
	}
}
