package core

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
	_ "duanjuapp/native/sources/all"
)

// TestManualSourceHealth 对全部站源执行与应用内「检测连接与播放」一致的健康检测。
// 仅在 GUOAPP_HEALTH_CHECK=1 时运行：GUOAPP_HEALTH_CHECK=1 go test -run TestManualSourceHealth -v -timeout 120m
func TestManualSourceHealth(t *testing.T) {
	if os.Getenv("GUOAPP_HEALTH_CHECK") != "1" {
		t.Skip("设置 GUOAPP_HEALTH_CHECK=1 以启用手动全源健康检测")
	}
	provider.Configure(provider.Config{AllSources: true})
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatalf("初始化检测引擎失败: %v", err)
	}
	entries := provider.All()
	if selected := strings.TrimSpace(os.Getenv("GUOAPP_HEALTH_SOURCES")); selected != "" {
		wanted := map[string]bool{}
		for _, id := range strings.Split(selected, ",") {
			if id = provider.Canonical(strings.TrimSpace(id)); id != "" {
				wanted[id] = true
			}
		}
		filtered := entries[:0]
		for _, entry := range entries {
			if wanted[entry.Spec().ID] {
				filtered = append(filtered, entry)
			}
		}
		entries = filtered
	}
	type outcome struct {
		Source  string             `json:"source"`
		Name    string             `json:"name"`
		Base    string             `json:"base"`
		State   string             `json:"state"`
		Sample  string             `json:"sample,omitempty"`
		Error   string             `json:"error,omitempty"`
		Seconds int64              `json:"seconds"`
		Steps   []nativeHealthStep `json:"steps,omitempty"`
	}
	var results []outcome
	startedAll := time.Now()
	for index, entry := range entries {
		spec := entry.Spec()
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Minute)
		started := time.Now()
		checkErr := engine.checkSource(ctx, spec.ID, nativeDrama{}, true)
		cancel()
		elapsed := time.Since(started)
		item := outcome{Source: spec.ID, Name: spec.Name, Base: spec.Base, Seconds: int64(elapsed.Seconds())}
		engine.mu.Lock()
		record, found := engine.sourceRecords[spec.ID]
		engine.mu.Unlock()
		if found && record.Health != nil {
			item.State, item.Sample, item.Steps = record.Health.State, record.Health.Sample, record.Health.Steps
		}
		if checkErr != nil {
			item.Error = publicError(checkErr).Error()
		}
		results = append(results, item)
		t.Logf("[%d/%d] %s(%s) => %s 用时 %ds %s", index+1, len(entries), spec.Name, spec.ID, item.State, item.Seconds, item.Error)
		for _, step := range item.Steps {
			t.Logf("    - %s: %s %s", step.Name, step.State, step.Message)
		}
	}
	sort.Slice(results, func(i, j int) bool { return results[i].Source < results[j].Source })
	body, err := json.MarshalIndent(results, "", "  ")
	if err != nil {
		t.Fatalf("序列化结果失败: %v", err)
	}
	target := os.Getenv("GUOAPP_HEALTH_REPORT")
	if target == "" {
		target = filepath.Join(os.TempDir(), "guoapp_health_report.json")
	} else {
		if abs, err := filepath.Abs(target); err == nil {
			target = abs
		}
		if dir := filepath.Dir(target); dir != "" {
			_ = os.MkdirAll(dir, 0o755)
		}
	}
	if err := os.WriteFile(target, body, 0o644); err != nil {
		t.Fatalf("写入报告失败: %v", err)
	}
	failed := 0
	for _, item := range results {
		if item.State != "ok" {
			failed++
		}
	}
	t.Logf("检测完成：%d 个源，%d 个异常，总用时 %s，报告已写入 %s",
		len(results), failed, strings.TrimSpace(time.Since(startedAll).String()), target)
	fmt.Fprintln(os.Stderr, "GUOAPP_HEALTH_REPORT_PATH="+target)
}
