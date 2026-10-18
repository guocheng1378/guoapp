package provider

import (
	"context"
	"fmt"
	"math"
	"net/url"
	"regexp"
	"strconv"
	"strings"
	"time"
)

var (
	playerData     = regexp.MustCompile(`(?s)player_aaaa\s*=\s*(\{.*?\})\s*</script>`)
	playerURLField = regexp.MustCompile(`(?i)"url"\s*:\s*"([^"]+)"`)
	playerFallback = []*regexp.Regexp{
		regexp.MustCompile(`(?i)\$\.url\s*=\s*"([^"]+)"`),
		regexp.MustCompile(`(?i)"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"`),
		regexp.MustCompile(`(?i)(https?://[^\s"'<>]+\.(?:m3u8|mp4)[^\s"'<>]*)`),
	}
	unicodeEscape = regexp.MustCompile(`\\?u([0-9a-fA-F]{4})`)
)

// PlayerURL 从网页播放器脚本里提取真实播放地址。
func PlayerURL(body string) string {
	if matches := playerData.FindStringSubmatch(body); len(matches) > 1 {
		if inner := playerURLField.FindStringSubmatch(matches[1]); len(inner) > 1 {
			return strings.ReplaceAll(inner[1], `\/`, `/`)
		}
	}
	for _, pattern := range playerFallback {
		if matches := pattern.FindStringSubmatch(body); len(matches) > 1 {
			return strings.ReplaceAll(matches[1], `\/`, `/`)
		}
	}
	return ""
}

// NormalizePlaybackURL 清理播放地址中的转义与标点，并解码部分站点的 unicode 目录名。
func NormalizePlaybackURL(raw string) string {
	raw = strings.TrimSpace(strings.ReplaceAll(raw, `\/`, `/`))
	raw = strings.Trim(raw, ",\\。，;；")
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if strings.Contains(raw, "p.") || strings.Contains(raw, "c1.") {
		parts := strings.Split(raw, "/")
		if len(parts) >= 3 {
			base := strings.Join(parts[:len(parts)-2], "/")
			folder := parts[len(parts)-2]
			if decoded := DecodeUnicode(folder); decoded != folder {
				return base + "/" + url.PathEscape(decoded) + "/index.m3u8"
			}
		}
	}
	return raw
}

// DecodeUnicode 还原 \uXXXX 形式的 unicode 转义。
func DecodeUnicode(value string) string {
	return unicodeEscape.ReplaceAllStringFunc(value, func(match string) string {
		hex := match[len(match)-4:]
		if number, err := strconv.ParseInt(hex, 16, 32); err == nil {
			return string(rune(number))
		}
		return match
	})
}

// M3U8Duration 统计 #EXTINF 行的总时长，无法解析的行跳过。
func M3U8Duration(raw string) time.Duration {
	var total time.Duration
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if !strings.HasPrefix(line, "#EXTINF:") {
			continue
		}
		value := strings.TrimSpace(strings.TrimPrefix(line, "#EXTINF:"))
		if comma := strings.IndexByte(value, ','); comma >= 0 {
			value = value[:comma]
		}
		seconds, err := strconv.ParseFloat(strings.TrimSpace(value), 64)
		if err != nil || seconds < 0 || math.IsNaN(seconds) || math.IsInf(seconds, 0) {
			continue
		}
		total += time.Duration(seconds * float64(time.Second))
	}
	return total
}

// ResolveWebMedia 是网页型站源 ResolveMedia 的公共收尾：
// 校验播放地址，m3u8 时经 host 拉取播放列表并计算时长。
func ResolveWebMedia(ctx context.Context, host Host, address, referer, sourceName string) (Media, error) {
	parsed, err := url.Parse(address)
	if err != nil || !HTTPMediaURL(address) || parsed.User != nil {
		return Media{}, fmt.Errorf("%s未返回有效播放地址，请刷新详情后重试", sourceName)
	}
	media := Media{URL: address, Referer: referer}
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		media.Playlist, media.URL, err = host.MediaPlaylist(ctx, address, referer)
		if err != nil {
			return Media{}, fmt.Errorf("获取%s播放列表失败：%w", sourceName, err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(media.Playlist, "\ufeff")), "#EXTM3U") {
			return Media{}, fmt.Errorf("%s播放列表无效，请重新解析播放", sourceName)
		}
		if duration := M3U8Duration(media.Playlist); duration > 0 {
			media.Duration = duration
		}
	}
	return media, nil
}
