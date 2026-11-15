package core

import (
	"context"
	"time"
)

// hongguoDevices 查询（或强制注册）红果主/辅双设备就绪状态。
// register=true 时清空注册暂停窗口并依次注册主设备与辅助设备，随后刷新
// catalog 快照落盘；ready 仅当两台设备都已登记成功才为 true。
func (engine *nativeEngine) hongguoDevices(ctx context.Context, register bool) (map[string]any, error) {
	if !nativeSourceAvailable(sourceHongguo) {
		return map[string]any{"ready": true}, nil
	}
	downloader := engine.downloader
	client := downloader.hongguoClient()
	if register {
		client.mu.Lock()
		client.registerPausedUntil = time.Time{}
		client.mu.Unlock()
		for _, helper := range []bool{false, true} {
			if err := downloader.ensureHongguoDevice(ctx, helper, ""); err != nil {
				return nil, err
			}
		}
		engine.mu.Lock()
		engine.hongguoCatalog = downloader.hongguoCatalogSnapshot()
		err := engine.writeCatalogDiskLocked()
		engine.mu.Unlock()
		if err != nil {
			return nil, err
		}
	}
	_, _, primary := client.device(false)
	_, _, helper := client.device(true)
	return map[string]any{"ready": primary && helper}, nil
}
