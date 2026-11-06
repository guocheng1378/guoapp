package core

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"sort"
	"strings"
	"time"
)

type nativePlaybackChoice struct {
	danmakuSource string
	danmakuSeries string
	danmakuVideo  string
	// 社区跳过预设（真果·鉴）：片头结束秒数 / 片尾起点距结尾秒数。
	skipIntro        int
	skipOutroFromEnd int
	media            []providerMedia
	// 线路面板按需补兑需要知道当前播放的是哪一集（P0-3：起播不再同步
	// attach 线路表，改由打开面板时现场拉）。
	task             Task
	index            int
	qualities        []int
	streamSession    string
	created          time.Time
	refresher        func(context.Context) (providerMedia, error)
}

func nativePlaybackChoices(media providerMedia, quality int) nativePlaybackChoice {
	choice := nativePlaybackChoice{qualities: []int{}}
	seen := map[string]bool{}
	qualities := map[int]bool{}
	for _, option := range append([]providerMedia{media}, media.Variants...) {
		if !isProviderHTTPMediaURL(option.URL) {
			continue
		}
		identity := option.URL + "\x00" + option.Referer + "\x00" + hex.EncodeToString(option.CENCKey) + "\x00" + hex.EncodeToString(option.HLSKey)
		if seen[identity] {
			continue
		}
		seen[identity] = true
		option.Variants = nil
		choice.media = append(choice.media, option)
		if option.Quality > 0 {
			qualities[option.Quality] = true
		}
	}
	// 官方线恒排在前面（真果·鉴用户定调「默认就进官方源」），同组内再按
	// 清晰度降序——只按清晰度排会把 Quality=0 的官方线挤到几十条三方线
	// 之后，默认地址也就落不到官方线上了。
	sort.SliceStable(choice.media, func(i, j int) bool {
		if choice.media[i].Official != choice.media[j].Official {
			return choice.media[i].Official
		}
		return choice.media[i].Quality > choice.media[j].Quality
	})
	for value := range qualities {
		choice.qualities = append(choice.qualities, value)
	}
	sort.Sort(sort.Reverse(sort.IntSlice(choice.qualities)))
	if quality > 0 && qualities[quality] {
		filtered := make([]providerMedia, 0, len(choice.media))
		for _, option := range choice.media {
			if option.Quality == quality {
				filtered = append(filtered, option)
			}
		}
		choice.media = filtered
	}
	return choice
}

func (engine *nativeEngine) nativeOpenPlayback(ctx context.Context, choice nativePlaybackChoice) (nativePlan, error) {
	if err := ctx.Err(); err != nil {
		return nativePlan{}, err
	}
	if choice.index < 0 || choice.index >= len(choice.media) {
		return nativePlan{}, errors.New("该集没有其他可用的播放线路")
	}
	media := choice.media[choice.index]
	var err error
	if !isProviderHTTPMediaURL(media.URL) {
		return nativePlan{}, errors.New("站源未返回有效的播放地址")
	}
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return nativePlan{}, errors.New("无法初始化播放会话")
	}
	plan := nativePlan{
		DanmakuID:        choice.danmakuVideo,
		SkipIntroSeconds: choice.skipIntro, SkipOutroFromEndSeconds: choice.skipOutroFromEnd,
		URL: media.URL, Headers: map[string]string{"User-Agent": hongguoWebMediaUserAgent(media.URL), "Referer": media.Referer},
		Key: hex.EncodeToString(media.CENCKey), Quality: media.Quality, Qualities: choice.qualities,
		RouteIndex: choice.index, RouteCount: len(choice.media), RouteLabels: nativeRouteLabels(choice.media),
		RouteOfficial: nativeRouteOfficial(choice.media), Session: hex.EncodeToString(tokenBytes),
	}
	if media.credentials != nil && !media.credentials.expires.IsZero() {
		if !time.Now().Before(media.credentials.expires) {
			return nativePlan{}, errors.New("播放凭证已过期，请重新解析播放")
		}
		plan.ExpiresAt = media.credentials.expires.UnixMilli()
	}
	choice.streamSession = ""
	{
		engine.mu.Lock()
		if engine.stream == nil {
			engine.stream, err = newNativeStreamServer(engine.downloader)
		}
		stream := engine.stream
		engine.mu.Unlock()
		if err != nil {
			return nativePlan{}, err
		}
		address, token, err := stream.nativeOpen(media, choice.refresher)
		if err != nil {
			return nativePlan{}, err
		}
		plan.URL, choice.streamSession = address, token
	}
	choice.created = time.Now()
	engine.mu.Lock()
	if engine.playbacks == nil {
		engine.playbacks = map[string]nativePlaybackChoice{}
	}
	var expired []string
	for token, old := range engine.playbacks {
		if time.Since(old.created) > 12*time.Hour {
			expired = append(expired, old.streamSession)
			delete(engine.playbacks, token)
		}
	}
	if len(engine.playbacks) >= 8 {
		// 边看边下载等场景会持续新建播放会话，逐出必须优先让路给正在
		// 播放的一条：按流会话最近被读取的使用序号比较（单调递增，毫
		// 秒内批量打开也能分先后），会话已消失的视为完全空闲最先逐出，
		// 避免把正在观看的会话挤出导致断链。
		victim, victimSeq := "", uint64(0)
		for token, old := range engine.playbacks {
			if seq := engine.stream.nativeSequence(old.streamSession); victim == "" || seq < victimSeq {
				victim, victimSeq = token, seq
			}
		}
		expired = append(expired, engine.playbacks[victim].streamSession)
		delete(engine.playbacks, victim)
	}
	engine.playbacks[plan.Session] = choice
	stream := engine.stream
	engine.mu.Unlock()
	if stream != nil {
		for _, token := range expired {
			stream.nativeRelease(token)
		}
	}
	if err := ctx.Err(); err != nil {
		engine.nativeReleasePlayback(plan.Session)
		return nativePlan{}, err
	}
	return plan, nil
}

func (engine *nativeEngine) nativeNextPlayback(ctx context.Context, session string) (nativePlan, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	engine.mu.Unlock()
	if !exists {
		return nativePlan{}, errors.New("播放线路已失效，请重新解析播放")
	}
	choice.index++
	return engine.nativeOpenPlayback(ctx, choice)
}

// nativeRouteLabels 从线路表提取显示名（无 Label 的源留空串，由 UI 回退
// 「线路 N」）。数量与 RouteCount 对齐。
func nativeRouteLabels(media []providerMedia) []string {
	if len(media) < 2 {
		return nil
	}
	labels := make([]string, len(media))
	for i, option := range media {
		labels[i] = strings.TrimSpace(option.Label)
	}
	return labels
}

// nativeRouteOfficial 与 nativeRouteLabels 对齐输出官方线标记：只有站源
// 真有官方票据时才有值，其余源返回 nil（Dart 侧按「无官方线」平铺全部线路）。
func nativeRouteOfficial(media []providerMedia) []bool {
	if len(media) < 2 {
		return nil
	}
	flags := make([]bool, len(media))
	any := false
	for i, option := range media {
		if option.Official {
			flags[i] = true
			any = true
		}
	}
	if !any {
		return nil
	}
	return flags
}

// nativeSelectPlayback 按索引任选一条线路（播放器线路面板点选）。
// 与 nativeNextPlayback 的区别：不递增 index，可任意跳转。
func (engine *nativeEngine) nativeSelectPlayback(ctx context.Context, session string, index int) (nativePlan, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	engine.mu.Unlock()
	if !exists {
		return nativePlan{}, errors.New("播放线路已失效，请重新解析播放")
	}
	if index < 0 || index >= len(choice.media) {
		return nativePlan{}, errors.New("所选线路不可用，请重新解析播放")
	}
	if index == choice.index {
		// 已在该线路上：仍重开一次，让调用方拿到新 plan（幂等）。
		return engine.nativeOpenPlayback(ctx, choice)
	}
	choice.index = index
	return engine.nativeOpenPlayback(ctx, choice)
}

// nativePlaybackRoutes 供线路面板打开时按需补齐线路表（P0-3）。
// 起播不再同步 attach，因此首帧可能只有 1 条线路；这里现场拉全表并补
// 兑官方线（dongpiandiRouteLines 内部有缓存与冷却闸门，第二次零网络）。
// 不重开流会话、不换 URL：只更新当前会话的 choice.media，把线路元数据
// 返回给 Dart 合并进现有 plan。
func (engine *nativeEngine) nativePlaybackRoutes(ctx context.Context, session string) (map[string]any, error) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	engine.mu.Unlock()
	if !exists {
		return nil, errors.New("播放线路已失效，请重新解析播放")
	}
	if len(choice.media) < 2 &&
		sourceFromDramaID(choice.task.DramaID) == sourceDongpiandi {
		lines := engine.downloader.dongpiandiRouteLines(ctx, choice.task)
		if len(lines) > 0 {
			lines = dongpiandiCurateLines(ctx, lines, 1200*time.Millisecond)
			seen := map[string]bool{}
			for _, option := range choice.media {
				seen[option.URL] = true
			}
			for _, line := range lines {
				option := dongpiandiLineMedia(line)
				if option.URL == "" || seen[option.URL] {
					continue
				}
				seen[option.URL] = true
				choice.media = append(choice.media, option)
			}
		}
		// 会话可能已被逐出/释放：不要把一个已消失的 session 写回来。
		engine.mu.Lock()
		if _, still := engine.playbacks[session]; still {
			engine.playbacks[session] = choice
		}
		engine.mu.Unlock()
	}
	return map[string]any{
		"routeIndex":    choice.index,
		"routeCount":    len(choice.media),
		"routeLabels":   nativeRouteLabels(choice.media),
		"routeOfficial": nativeRouteOfficial(choice.media),
	}, nil
}

func (engine *nativeEngine) nativeReleasePlayback(session string) {
	engine.mu.Lock()
	choice, exists := engine.playbacks[session]
	delete(engine.playbacks, session)
	stream := engine.stream
	engine.mu.Unlock()
	if exists && stream != nil && choice.streamSession != "" {
		stream.nativeRelease(choice.streamSession)
	}
}
