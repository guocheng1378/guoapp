package core

// sourceConfig.appConfigUrl 是「弹窗/更新配置」的自建源地址。Go 核心并不直接
// 拉取 app_config.json（那是 Dart remote_notice.dart 的职责），但 sourceConfig
// 由 config.source 统一转发，Go 侧同样做权威校验并记录，供诊断与测试断言；
// 真正的拉取链置顶由 Dart 侧消费同一个字段完成。旧版 App 忽略该未知键，
// 因此该字段可安全写入线上配置而不破坏兼容性。

import (
	"net/url"
	"strings"
	"sync"
)

var (
	appConfigSourceMu   sync.RWMutex
	appConfigSourceHost string
)

// setAppConfigSourceURL 校验并记录下发的配置源地址；空串 = 清空（回落内置链）。
func setAppConfigSourceURL(raw string) bool {
	text := strings.TrimSpace(raw)
	if text == "" {
		appConfigSourceMu.Lock()
		appConfigSourceHost = ""
		appConfigSourceMu.Unlock()
		return true
	}
	parsed, err := url.Parse(text)
	if err != nil || (parsed.Scheme != "http" && parsed.Scheme != "https") || parsed.Host == "" {
		return false
	}
	appConfigSourceMu.Lock()
	appConfigSourceHost = strings.TrimSuffix(text, "/")
	appConfigSourceMu.Unlock()
	return true
}

// appConfigSourceURL 返回当前生效的配置源覆盖（空串 = 未配置）。
func appConfigSourceURL() string {
	appConfigSourceMu.RLock()
	defer appConfigSourceMu.RUnlock()
	return appConfigSourceHost
}
