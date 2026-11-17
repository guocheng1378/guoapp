package core

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
)

func (manager *nativeDownloads) jobDirectory(job nativeDownloadJob) string {
	base := filepath.Join(manager.root, job.ID)
	if job.Folder == "" {
		return base
	}
	// 安全审查修复：Folder 由「源 id + 任务 id」拼出，而源 id 可能来自站源
	// 返回的 JSON（不可信）。这里做归一化 + 前缀断言，穿越值一律回落到
	// 任务 id 目录，避免 os.RemoveAll 删除下载根目录之外的东西。
	candidate := filepath.Clean(filepath.Join(manager.root, filepath.FromSlash(job.Folder)))
	prefix := filepath.Clean(manager.root) + string(os.PathSeparator)
	if !strings.HasPrefix(candidate, prefix) {
		return base
	}
	return candidate
}

func (manager *nativeDownloads) localFilesValid(record nativeDownloadRecord) bool {
	if record.File == "" {
		return false
	}
	directory := manager.jobDirectory(record.nativeDownloadJob)
	seen := map[string]bool{}
	var validate func(string, int) bool
	validate = func(name string, depth int) bool {
		if depth > 8 || len(seen) > 20100 || filepath.Base(name) != name || strings.ContainsAny(name, "/\\:") {
			return false
		}
		if seen[name] {
			return true
		}
		seen[name] = true
		file := filepath.Join(directory, name)
		info, err := os.Stat(file)
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
			return false
		}
		if name == "media.mp4" && record.Bytes > 0 && info.Size() != record.Bytes {
			return false
		}
		if !strings.HasSuffix(name, ".m3u8") {
			return true
		}
		if info.Size() > 4<<20 {
			return false
		}
		data, err := os.ReadFile(file)
		if err != nil || !strings.HasPrefix(strings.TrimSpace(string(data)), "#EXTM3U") {
			return false
		}
		for _, line := range strings.Split(string(data), "\n") {
			line = strings.TrimSpace(line)
			if line != "" && !strings.HasPrefix(line, "#") && !validate(line, depth+1) {
				return false
			}
			for _, match := range nativePlaylistURI.FindAllStringSubmatch(line, -1) {
				if !validate(match[1], depth+1) {
					return false
				}
			}
		}
		return true
	}
	return validate(record.File, 0)
}

type nativeDownloadControlResult struct {
	Completed []string          `json:"completed"`
	Failures  map[string]string `json:"failures"`
}

func (manager *nativeDownloads) controlBatch(ids []string, command string) (nativeDownloadControlResult, error) {
	return manager.controlBatchExpected(context.Background(), ids, command, nil)
}

func (manager *nativeDownloads) controlBatchExpected(ctx context.Context, ids []string, command string, expected map[string]string) (nativeDownloadControlResult, error) {
	result := nativeDownloadControlResult{Completed: []string{}, Failures: map[string]string{}}
	if len(ids) == 0 || len(ids) > 500 {
		return result, errors.New("请选择 1 至 500 个下载任务")
	}
	switch command {
	case "pause", "resume", "remove", "archive", "restore":
	default:
		return result, errors.New("批量下载操作无效")
	}
	// 批量路径统一落盘一次：单条 controlExpected 会逐条 Marshal + Sync 整份索引，
	// 500 条能把界面卡十几秒。批量期间只改内存，循环结束后统一写。
	manager.mu.Lock()
	if manager.batchSave {
		manager.mu.Unlock()
		return result, errors.New("已有批量操作正在进行，请稍后重试")
	}
	manager.batchSave = true
	manager.mu.Unlock()
	defer func() {
		manager.mu.Lock()
		manager.batchSave = false
		manager.mu.Unlock()
	}()

	seen := map[string]bool{}
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		if ctx.Err() != nil {
			result.Failures[id] = "操作已停止，尚未处理此任务"
			continue
		}
		if expected != nil && expected[id] == "" {
			result.Failures[id] = "原分集校验信息缺失，已保留文件"
			continue
		}
		if err := manager.controlExpected(id, command, expected[id]); err != nil {
			result.Failures[id] = publicError(err).Error()
		} else {
			result.Completed = append(result.Completed, id)
		}
	}
	manager.mu.Lock()
	saveErr := manager.saveLocked()
	manager.mu.Unlock()
	if saveErr != nil {
		return result, saveErr
	}
	return result, nil
}
