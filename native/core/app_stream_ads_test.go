package core

import (
	"fmt"
	"strings"
	"testing"
)

const playlistBase = "https://cdn.example.com/20260909/10352_eb878f5a/2000k/hls/index.m3u8"

// 构造采集站注入广告的清单：正片相对分片 + 广告绝对路径分片段（DISCONTINUITY 包夹）。
func injectedPlaylist(adBefore, adAfter int) string {
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:0\n")
	index := 0
	writeSegment := func(uri string) {
		builder.WriteString("#EXTINF:4.000000,\n")
		builder.WriteString(uri)
		builder.WriteString("\n")
	}
	writeContent := func() string {
		uri := fmt.Sprintf("9bd8a2a212a%07d.ts", index)
		index++
		writeSegment(uri)
		return uri
	}
	for i := 0; i < adBefore; i++ {
		writeContent()
	}
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	for i := 0; i < 2; i++ {
		writeSegment("https://other.cdn.example/20261003/84_9109598f/2000k/hls/751808405d700000" + string(rune('0'+i)) + ".ts")
	}
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	for i := 0; i < adAfter; i++ {
		writeContent()
	}
	builder.WriteString("#EXT-X-ENDLIST\n")
	return builder.String()
}

func TestNativePruneAdSegmentsRemovesInjectedAds(t *testing.T) {
	body := injectedPlaylist(3, 3)
	lines := strings.Split(body, "\n")
	pruned := nativePruneAdSegments(lines, playlistBase)
	text := strings.Join(pruned, "\n")
	if strings.Contains(text, "other.cdn.example") {
		t.Fatalf("广告分片未被剔除:\n%s", text)
	}
	for _, want := range []string{
		"#EXTM3U",
		"#EXT-X-TARGETDURATION:8",
		"#EXTINF:4.000000,\n9bd8a2a212a0000000.ts",
		"#EXTINF:4.000000,\n9bd8a2a212a0000005.ts",
		"#EXT-X-ENDLIST",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("正片内容缺失 %q:\n%s", want, text)
		}
	}
	// 每个保留的分片都应有自己的 EXTINF。
	kept := 0
	for _, line := range pruned {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		kept++
	}
	if kept != 6 {
		t.Fatalf("正片分片数应为 6，实际 %d:\n%s", kept, text)
	}
	if doubled := strings.Count(text, "#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY"); doubled != 0 {
		t.Fatalf("存在相邻重复的 DISCONTINUITY:\n%s", text)
	}
	// 中插广告剔除后应恰好保留一个 DISCONTINUITY（包夹的后标记或补插，
	// 提示播放器正片时间轴在此跳变，缺失会导致音频同步拉扯出杂音）。
	if count := strings.Count(text, "#EXT-X-DISCONTINUITY"); count != 1 {
		t.Fatalf("DISCONTINUITY 应恰好 1 个，实际 %d:\n%s", count, text)
	}
}

func TestNativePruneAdSegmentsInsertsDiscontinuityWithoutTrailer(t *testing.T) {
	// 注入形态变体：广告段只有前置 DISCONTINUITY（后无标记）。
	// 剔除后正片边界必须补插一个 DISCONTINUITY，否则正片时间轴
	// 无提示跳变，播放器音频同步拉扯出杂音。
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:0\n")
	for i := 0; i < 3; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a000000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	for i := 0; i < 2; i++ {
		builder.WriteString("#EXTINF:4.000000,\nhttps://other.cdn.example/20261003/84_9109598f/2000k/hls/751808405d700000" + string(rune('0'+i)) + ".ts\n")
	}
	for i := 3; i < 6; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a000000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-ENDLIST\n")
	pruned := nativePruneAdSegments(strings.Split(builder.String(), "\n"), playlistBase)
	text := strings.Join(pruned, "\n")
	if strings.Contains(text, "other.cdn.example") {
		t.Fatalf("广告分片未被剔除:\n%s", text)
	}
	if count := strings.Count(text, "#EXT-X-DISCONTINUITY"); count != 1 {
		t.Fatalf("剔除块边界应补插 1 个 DISCONTINUITY，实际 %d:\n%s", count, text)
	}
	if doubled := strings.Count(text, "#EXT-X-DISCONTINUITY\n#EXT-X-DISCONTINUITY"); doubled != 0 {
		t.Fatalf("存在相邻重复的 DISCONTINUITY:\n%s", text)
	}
}

func TestNativePruneAdSegmentsRestoresMainKeyAfterAd(t *testing.T) {
	// 广告段自带独立 KEY：随段删除后必须在块边界恢复正片生效的 KEY，
	// 否则残留广告密钥会作用到后续正片分片，解密失败即爆音杂音。
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:0\n")
	builder.WriteString("#EXT-X-KEY:METHOD=AES-128,URI=\"https://cdn.example.com/20260909/key/a.key\",IV=0x1\n")
	for i := 0; i < 3; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a000000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	builder.WriteString("#EXT-X-KEY:METHOD=AES-128,URI=\"https://ad.example.com/20261003/key/b.key\"\n")
	for i := 0; i < 2; i++ {
		builder.WriteString("#EXTINF:4.000000,\nhttps://other.cdn.example/20261003/84_9109598f/2000k/hls/751808405d700000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	for i := 3; i < 6; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a000000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-ENDLIST\n")
	pruned := nativePruneAdSegments(strings.Split(builder.String(), "\n"), playlistBase)
	text := strings.Join(pruned, "\n")
	if strings.Contains(text, "other.cdn.example") {
		t.Fatalf("广告分片未被剔除:\n%s", text)
	}
	if strings.Contains(text, "b.key") {
		t.Fatalf("广告密钥残留:\n%s", text)
	}
	if count := strings.Count(text, "a.key"); count != 2 {
		t.Fatalf("正片密钥应出现 2 次（原声明+块边界恢复），实际 %d:\n%s", count, text)
	}
	if count := strings.Count(text, "#EXT-X-DISCONTINUITY"); count != 1 {
		t.Fatalf("DISCONTINUITY 应恰好 1 个，实际 %d:\n%s", count, text)
	}
	// 恢复的 KEY 必须紧邻补插的 DISCONTINUITY、位于块后正片之前。
	if keyIndex := strings.Index(text, "a.key\",IV=0x1\n#EXT-X-DISCONTINUITY"); keyIndex < 0 {
		t.Fatalf("恢复的 KEY 未紧邻补插的 DISCONTINUITY:\n%s", text)
	}
}

func TestNativePruneAdSegmentsKeepsCleanPlaylist(t *testing.T) {
	body := injectedPlaylist(0, 0)
	pruned := nativePruneAdSegments(strings.Split(body, "\n"), playlistBase)
	if strings.Join(pruned, "\n") != body {
		t.Fatalf("无广告清单不应改动:\n%s", strings.Join(pruned, "\n"))
	}
}

func TestNativePruneAdSegmentsSkipsMasterPlaylist(t *testing.T) {
	body := "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=80000,RESOLUTION=1080x608\n2000k/hls/mixed.m3u8\n"
	pruned := nativePruneAdSegments(strings.Split(body, "\n"), playlistBase)
	if strings.Join(pruned, "\n") != body {
		t.Fatalf("主清单不应改动:\n%s", strings.Join(pruned, "\n"))
	}
}

func TestNativePruneAdSegmentsLeadingAdKeepsHeaders(t *testing.T) {
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:8\n#EXT-X-MEDIA-SEQUENCE:0\n")
	builder.WriteString("#EXTINF:4.000000,\nhttps://other.cdn.example/20261003/84_9109598f/2000k/hls/751808405d7000000.ts\n")
	builder.WriteString("#EXT-X-DISCONTINUITY\n")
	for i := 0; i < 5; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a00000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-ENDLIST\n")
	body := builder.String()
	pruned := nativePruneAdSegments(strings.Split(body, "\n"), playlistBase)
	text := strings.Join(pruned, "\n")
	if strings.Contains(text, "other.cdn.example") {
		t.Fatalf("片头广告未被剔除:\n%s", text)
	}
	for _, want := range []string{"#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:8", "#EXT-X-MEDIA-SEQUENCE:0", "9bd8a2a212a000000.ts", "#EXT-X-ENDLIST"} {
		if !strings.Contains(text, want) {
			t.Fatalf("全局头或正片缺失 %q:\n%s", want, text)
		}
	}
}

func TestNativePruneAdSegmentsKeepsAmbiguousPlaylist(t *testing.T) {
	// 两个目录分片数相同（对半分），主目录不显著，不应误杀。
	var builder strings.Builder
	builder.WriteString("#EXTM3U\n#EXT-X-TARGETDURATION:8\n")
	for i := 0; i < 4; i++ {
		builder.WriteString("#EXTINF:4.000000,\n9bd8a2a212a00000" + string(rune('0'+i)) + ".ts\n")
		builder.WriteString("#EXTINF:4.000000,\nhttps://other.cdn.example/20261003/84_9109598f/2000k/hls/751808405d700000" + string(rune('0'+i)) + ".ts\n")
	}
	builder.WriteString("#EXT-X-ENDLIST\n")
	body := builder.String()
	pruned := nativePruneAdSegments(strings.Split(body, "\n"), playlistBase)
	if strings.Join(pruned, "\n") != body {
		t.Fatalf("主目录不显著的清单不应改动:\n%s", strings.Join(pruned, "\n"))
	}
}
