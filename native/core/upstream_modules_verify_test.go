package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// TestUpstreamOfficialModulesLoad 验证下载到 upstream_modules_full 的官方模块
// 能在本项目的 goja 运行时里加载（host 原语齐全、签名兼容）。
// 该目录由 C:\cmake-src\fetch_upstream_modules.py 生成，属本地取证数据：
// 目录不存在时跳过，不影响常规 CI。
func TestUpstreamOfficialModulesLoad(t *testing.T) {
	root := os.Getenv("GUOAPP_UPSTREAM_MODULES")
	if root == "" {
		t.Skip("GUOAPP_UPSTREAM_MODULES 未设置（本地取证数据目录）")
	}
	entries, err := os.ReadDir(root)
	if err != nil {
		t.Skipf("模块目录不可读: %v", err)
	}
	d := &Downloader{client: nil}
	type result struct {
		id  string
		err error
	}
	var results []result
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		manifestPath := filepath.Join(root, entry.Name(), "manifest.json")
		scriptPath := filepath.Join(root, entry.Name(), "main.js")
		manifestRaw, err := os.ReadFile(manifestPath)
		if err != nil {
			results = append(results, result{id: entry.Name(), err: err})
			continue
		}
		script, err := os.ReadFile(scriptPath)
		if err != nil {
			results = append(results, result{id: entry.Name(), err: err})
			continue
		}
		var manifest JSModuleManifest
		if err := json.Unmarshal(manifestRaw, &manifest); err != nil {
			results = append(results, result{id: entry.Name(), err: err})
			continue
		}
		manifest.normalize(entry.Name())
		runtime, err := newJSModuleRuntime(d, manifest, string(script))
		if err != nil {
			results = append(results, result{id: entry.Name(), err: err})
			continue
		}
		// 确认至少导出了 categories/catalogPage/detail 三件套之一。
		hasAny := false
		for _, fn := range []string{"categories", "catalogPage", "detail", "resolveMedia"} {
			if runtime.hasExport(fn) {
				hasAny = true
				break
			}
		}
		if !hasAny {
			results = append(results, result{id: entry.Name(), err: gojaErr("无目录/详情导出")})
			continue
		}
		results = append(results, result{id: entry.Name()})
	}
	sort.Slice(results, func(i, j int) bool { return results[i].id < results[j].id })
	loaded := 0
	for _, r := range results {
		if r.err != nil {
			t.Errorf("模块 %-18s 加载失败: %v", r.id, r.err)
		} else {
			t.Logf("模块 %-18s OK", r.id)
			loaded++
		}
	}
	t.Logf("加载成功 %d/%d", loaded, len(results))
	if len(results) == 0 {
		t.Fatal("没有发现任何模块")
	}
}

type gojaErr string

func (e gojaErr) Error() string { return string(e) }
