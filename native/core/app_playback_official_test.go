package core

import (
	"testing"
)

// 线路面板的官方源/第三方源分组依赖这两件事：官方线排在前面（默认进官方源），
// 且 nativePlan 把官方标记按位输出给 Dart。此前 providerMedia 根本没有官方
// 标记，Dart 侧只能看到几十条混排线路，官方源被第三方淹没。
func TestNativePlaybackChoicesPutsOfficialFirst(t *testing.T) {
	media := providerMedia{URL: "https://third.test/v.mp4", Label: "新浪资源", Quality: 1080}
	media.Variants = []providerMedia{
		{URL: "https://official.test/a.mp4", Label: "1080P-官方R", Official: true},
		{URL: "https://third2.test/v.mp4", Label: "豆瓣资源", Quality: 720},
	}
	choice := nativePlaybackChoices(media, 0)
	if len(choice.media) != 3 {
		t.Fatalf("三条线路都应保留: %+v", choice.media)
	}
	if !choice.media[0].Official || choice.media[0].Label != "1080P-官方R" {
		t.Fatalf("官方线必须排在首位（Quality=0 也不例外）: %+v", choice.media)
	}
	// 同组内仍按清晰度降序：1080 → 720。
	if choice.media[1].Quality != 1080 || choice.media[2].Quality != 720 {
		t.Fatalf("官方组内应按清晰度降序: %+v", choice.media)
	}
}

// 没有官方线的源（除真果·鉴外的全部站源）排序语义保持不变。
func TestNativePlaybackChoicesKeepsQualityOrderWithoutOfficial(t *testing.T) {
	media := providerMedia{URL: "https://a.test/v.mp4", Quality: 720}
	media.Variants = []providerMedia{{URL: "https://b.test/v.mp4", Quality: 1080}, {URL: "https://c.test/v.mp4"}}
	choice := nativePlaybackChoices(media, 0)
	if len(choice.media) != 3 || choice.media[0].Quality != 1080 || choice.media[1].Quality != 720 {
		t.Fatalf("无官方标记时仍按清晰度降序: %+v", choice.media)
	}
	if official := nativeRouteOfficial(choice.media); official != nil {
		t.Fatalf("无官方线时不应输出官方标记: %+v", official)
	}
}

func TestNativeRouteOfficialAlignsRouteLabels(t *testing.T) {
	media := []providerMedia{
		{URL: "https://official.test/a.mp4", Label: "官方线", Official: true},
		{URL: "https://third.test/v.mp4", Label: "新浪资源"},
		{URL: "https://official.test/b.mp4", Label: "官方线乙", Official: true},
	}
	flags := nativeRouteOfficial(media)
	labels := nativeRouteLabels(media)
	if len(flags) != len(labels) || len(flags) != 3 {
		t.Fatalf("官方标记必须与线路名等长: flags=%v labels=%v", flags, labels)
	}
	if !flags[0] || flags[1] || !flags[2] {
		t.Fatalf("官方标记错位: %v", flags)
	}
}

// 主播放地址本身就是官方线时，合并线路表要把官方标记补回主媒体，
// 否则面板会把它算成第三方（官方源个数少一条）。
func TestDongpiandiMergeRoutesMarksMainOfficial(t *testing.T) {
	downloader := &Downloader{}
	media := providerMedia{URL: "https://official.test/main.mp4", Label: "官方线甲"}
	downloader.mergeDongpiandiRoutes(&media, []dongpiandiLine{
		{URL: "https://official.test/main.mp4", Label: "官方线甲", Resolved: true, Official: true},
		{URL: "https://official.test/second.mp4", Label: "官方线乙", Resolved: true, Official: true},
		{URL: "https://third.test/v.m3u8", Label: "新浪资源", Resolved: true},
	})
	if !media.Official {
		t.Fatalf("主媒体与官方线同址时官方标记应补回: %+v", media)
	}
	if len(media.Variants) != 2 || !media.Variants[0].Official || media.Variants[1].Official {
		t.Fatalf("第三方线不得被标成官方: %+v", media.Variants)
	}
}
