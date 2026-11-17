package core

// EPG 组装回归（2026-11-15）：
//   - 跨天节目（昨天开播、今天结束）不能被 dayStart 整条丢掉，否则午夜档会变「暂无在播」；
//   - now/next 判定不能受「单频道回传 48 条」上限约束。

import (
	"fmt"
	"testing"
	"time"
)

func TestLiveEpgBuildChannelKeepsCrossDayProgram(t *testing.T) {
	dayStart := time.Date(2026, 11, 15, 0, 0, 0, 0, time.Local)
	now := dayStart.Add(10 * time.Minute)
	rows := []liveEpgRow{
		{title: "午夜剧场", start: dayStart.Add(-40 * time.Minute), stop: dayStart.Add(20 * time.Minute)},
		{title: "早间新闻", start: dayStart.Add(6 * time.Hour), stop: dayStart.Add(7 * time.Hour)},
	}
	result, ok := liveEpgBuildChannel(rows, now, dayStart, now.Add(24*time.Hour))
	if !ok {
		t.Fatal("应命中频道")
	}
	if result.Now == nil || result.Now.Title != "午夜剧场" {
		t.Fatalf("跨天节目应判为正在播：%+v", result.Now)
	}
	if len(result.Programs) != 2 || result.Programs[0].Title != "午夜剧场" {
		t.Fatalf("跨天节目不应被丢弃：%+v", result.Programs)
	}
}

func TestLiveEpgBuildChannelFindsOnAirBeyondProgramCap(t *testing.T) {
	dayStart := time.Date(2026, 11, 15, 0, 0, 0, 0, time.Local)
	// 一天 60 档 24 分钟节目：在播的一档落在第 48 条之后。
	rows := make([]liveEpgRow, 0, 60)
	for i := 0; i < 60; i++ {
		rows = append(rows, liveEpgRow{
			title: fmt.Sprintf("节目%d", i),
			start: dayStart.Add(time.Duration(i) * 24 * time.Minute),
			stop:  dayStart.Add(time.Duration(i+1) * 24 * time.Minute),
		})
	}
	now := dayStart.Add(58*24*time.Minute + time.Minute)
	result, ok := liveEpgBuildChannel(rows, now, dayStart, now.Add(24*time.Hour))
	if !ok {
		t.Fatal("应命中频道")
	}
	if len(result.Programs) != liveEpgMaxPrograms {
		t.Fatalf("节目表应截到上限 %d，实际 %d", liveEpgMaxPrograms, len(result.Programs))
	}
	if result.Now == nil || result.Now.Title != "节目58" {
		t.Fatalf("超出回传上限仍应标出正在播：%+v", result.Now)
	}
}
