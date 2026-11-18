package core

import (
	"context"
	"errors"
	"time"
)

func (engine *nativeEngine) nativeDanmaku(ctx context.Context, input nativeInput) (hongguoDanmakuPage, error) {
	if input.StartMS < 0 || input.DurationMS <= input.StartMS || input.DurationMS > danmakuMaxDurationMS {
		return hongguoDanmakuPage{}, errors.New("弹幕时间范围无效")
	}
	engine.mu.Lock()
	choice, exists := engine.playbacks[input.PlaybackSession]
	engine.mu.Unlock()
	if !exists || time.Since(choice.created) > 12*time.Hour {
		return hongguoDanmakuPage{}, errors.New("播放会话已过期")
	}
	if choice.danmakuSeries == "" || choice.danmakuVideo == "" {
		return hongguoDanmakuPage{}, errors.New("本集暂不支持弹幕")
	}
	var page hongguoDanmakuPage
	var err error
	// 模块站源：由模块提供弹幕（模块没提供则回退内置实现）。
	moduleIDsOnly := false
	if danmaku, ok := moduleCapabilityProvider(choice.danmakuSource).(moduleDanmakuProvider); ok {
		result, moduleErr := danmaku.ModuleDanmaku(ctx, engine.downloader.host(), choice.danmakuSeries, choice.danmakuVideo, input.StartMS, input.DurationMS)
		if !errors.Is(moduleErr, errModuleCapabilityUnsupported) {
			if moduleErr != nil {
				return hongguoDanmakuPage{}, moduleErr
			}
			return result, ctx.Err()
		}
		moduleIDsOnly = true
	}
	if moduleIDsOnly {
		// 模块只导出 danmakuIds、没导出 danmaku：明确报「暂不支持」，
		// 而不是拿模块 ID 去调红果接口（会报「弹幕请求参数无效」）。
		return hongguoDanmakuPage{}, errors.New("该站源暂不支持弹幕")
	}
	switch choice.danmakuSource {
	case sourceDongpiandi:
		page, err = engine.downloader.dongpiandiDanmaku(ctx, choice.danmakuSeries, choice.danmakuVideo, input.StartMS, input.DurationMS)
	default:
		// 红果内嵌 JS 模块优先（仅纯数字 ID，JS 要求）；失败回落 Go 直连。
		if choice.danmakuSource == sourceHongguo && isAllDigits(choice.danmakuSeries) && isAllDigits(choice.danmakuVideo) {
			if module, jsErr := engine.downloader.hongguoJS(); jsErr == nil {
				if jsPage, jsErr := module.danmaku(choice.danmakuSeries, choice.danmakuVideo, input.StartMS, input.DurationMS); jsErr == nil {
					page = jsPage
					break
				}
			}
		}
		page, err = engine.downloader.hongguoDanmaku(ctx, choice.danmakuSeries, choice.danmakuVideo, input.StartMS, input.DurationMS)
	}
	if err != nil {
		return hongguoDanmakuPage{}, err
	}
	engine.mu.Lock()
	_, exists = engine.playbacks[input.PlaybackSession]
	engine.mu.Unlock()
	if !exists {
		return hongguoDanmakuPage{}, errors.New("播放会话已过期")
	}
	return page, ctx.Err()
}
