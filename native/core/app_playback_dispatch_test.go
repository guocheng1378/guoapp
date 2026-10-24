package core

import (
	"context"
	"testing"
)

// 回归：selectPlayback 必须被 nativeDispatch 路由。
// 此前 case 只列了 resolve/fallback（内层 if 写了 selectPlayback 分支却永远
// 进不来），线路面板点选直接落到 default 返回「不支持的应用操作」——表现为
// 任何站源（含红果清晰度变体）切线路都不能播放。
func TestNativeDispatchRoutesSelectPlayback(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
		if engine.stream != nil && engine.stream.server != nil {
			engine.stream.server.Close()
		}
	})

	media := providerMedia{URL: "https://first.test/v.mp4", Label: "主线"}
	media.Variants = []providerMedia{{URL: "https://second.test/v.mp4", Label: "备线"}}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	if plan.RouteCount != 2 {
		t.Fatalf("两条线路应展开为 routeCount=2: %+v", plan)
	}

	data, err := nativeDispatch(nativeInput{Action: "selectPlayback", Session: plan.Session, Route: 1, Sequence: 1})
	if err != nil {
		t.Fatalf("selectPlayback 未被 dispatch 路由: %v", err)
	}
	next, ok := data.(nativePlan)
	if !ok {
		t.Fatalf("返回类型不对: %T", data)
	}
	if next.RouteIndex != 1 || next.URL == "" || next.URL == plan.URL || len(next.RouteLabels) != 2 {
		t.Fatalf("切到第 2 条线路结果不对: %+v", next)
	}
	if next.RouteLabels[1] != "备线" {
		t.Fatalf("线路名丢失: %+v", next.RouteLabels)
	}
}

// 同一入口的 fallback 也走这条 case，顺带确认没有被改坏。
func TestNativeDispatchRoutesFallback(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	nativeState.Lock()
	previous := nativeState.engine
	nativeState.engine = engine
	nativeState.Unlock()
	t.Cleanup(func() {
		nativeState.Lock()
		nativeState.engine = previous
		nativeState.Unlock()
		if engine.stream != nil && engine.stream.server != nil {
			engine.stream.server.Close()
		}
	})

	media := providerMedia{URL: "https://first.test/v.mp4", Label: "主线"}
	media.Variants = []providerMedia{{URL: "https://second.test/v.mp4", Label: "备线"}}
	plan, err := engine.nativeOpenPlayback(context.Background(), nativePlaybackChoices(media, 0))
	if err != nil {
		t.Fatal(err)
	}
	data, err := nativeDispatch(nativeInput{Action: "fallback", Session: plan.Session, Sequence: 1})
	if err != nil {
		t.Fatalf("fallback 未被 dispatch 路由: %v", err)
	}
	next, ok := data.(nativePlan)
	if !ok || next.RouteIndex != 1 {
		t.Fatalf("fallback 应前进到第 2 条线路: %+v", data)
	}
}
