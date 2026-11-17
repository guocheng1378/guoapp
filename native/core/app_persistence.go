package core

import (
	"errors"
	"strings"
)

// nativeCatalogMaxBytes 剧库（catalogs.json）落盘体积安全阀，不是用户配额。
//
// 原值 32 MiB：多源全开 + 上万条目 + 长简介的重度用户会撞到，撞到之后核心
// 拒绝保存并暂停继续翻页——用户看到的就是「新内容一直不出现、库停在旧的一页」。
// 提到 512 MiB 后常规使用不会再触碰，同时仍留一道防爆闸，避免单个 JSON 无限
// 增长拖垮落盘与冷启动解析。变量而非常量：测试可注入极小值验证超限分支。
var nativeCatalogMaxBytes = 512 << 20
const nativeSourceMaxBytes = 4 << 20

var errNativeCatalogLimit = errors.New("剧库超过本地保存上限，新内容尚未保存，已暂停继续加载")
var errNativeSourceLimit = errors.New("站源任务记录超过本地保存上限（4 MiB），最新记录尚未保存")

type nativePersistenceError struct {
	label string
	cause error
}

func (err *nativePersistenceError) Error() string {
	if errors.Is(err.cause, errNativeCatalogLimit) || errors.Is(err.cause, errNativeSourceLimit) {
		return err.cause.Error()
	}
	return err.label + "尚未保存，最新结果仅在本次运行中保留；请检查剩余空间和存储权限后重试保存"
}

func (err *nativePersistenceError) Unwrap() error { return err.cause }

func nativeSaveError(label string, err error) error {
	if err == nil {
		return nil
	}
	return &nativePersistenceError{label: label, cause: err}
}

func joinNativeWarnings(warnings ...string) string {
	seen := map[string]bool{}
	var values []string
	for _, warning := range warnings {
		if warning != "" && !seen[warning] {
			seen[warning] = true
			values = append(values, warning)
		}
	}
	return strings.Join(values, "；")
}

func (engine *nativeEngine) retryCatalogSave() (bool, error) {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.catalogSaveError == nil {
		return false, nil
	}
	return true, engine.writeCatalogDiskLocked()
}

func (engine *nativeEngine) finishCatalogSaveLocked() {
	changed := false
	for source, record := range engine.sourceRecords {
		if record.NeedsSave {
			record.NeedsSave = false
			if !record.Running {
				record.Stage = "已保存，可继续更新"
			}
			engine.sourceRecords[source] = record
			changed = true
		}
	}
	if changed {
		engine.saveSourceRecordsLocked()
	}
}

func (engine *nativeEngine) markCatalogSavePendingLocked() {
	if engine.sourceRecords == nil {
		engine.sourceRecords = map[string]nativeSourceRecord{}
	}
	changed := false
	for key := range engine.catalogs {
		source, _, _ := strings.Cut(key, "|")
		record := engine.sourceRecords[source]
		if !isHuangguoProviderSource(source) || record.NeedsSave {
			continue
		}
		record.NeedsSave = true
		if !record.Running {
			record.Stage = "等待保存"
		}
		engine.sourceRecords[source] = record
		changed = true
	}
	if changed {
		engine.saveSourceRecordsLocked()
	}
}

func (engine *nativeEngine) storageWarningLocked() string {
	var warnings []string
	for _, err := range []error{engine.catalogSaveError, engine.sourceSaveError} {
		if err != nil {
			warnings = append(warnings, err.Error())
		}
	}
	return joinNativeWarnings(warnings...)
}

func (engine *nativeEngine) retrySourceSave(source string) nativeSourceStatus {
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.catalogSaveError != nil {
		engine.writeCatalogDiskLocked()
	}
	if engine.sourceSaveError != nil {
		engine.saveSourceRecordsLocked()
	}
	return engine.sourceStatusLocked(source)
}
