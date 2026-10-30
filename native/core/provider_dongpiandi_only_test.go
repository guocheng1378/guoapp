package core

// 「仅官方线路」三处修复回归（2026-10-25 用户反馈「官源还是不行」）：
//  1. 冷启动/未解析过的集（缓存为空）不能被当成三方地址拦掉——拦掉只会让
//     首播先付一次全链重解析，失败就直接播不了；
//  2. 站源健康诊断（管理页「检测」）不受该播放偏好污染——样本剧恰好没有
//     官方线时，健康的站源会被误判成「未返回有效播放地址」；
//  3. 报错要区分「站点没给票」与「票据兑换失败（资源暂不可用）」。

import (
	"context"
	"strings"
	"testing"
)

func TestDongpiandiOnlyUncachedAddressNotBlocked(t *testing.T) {
	t.Cleanup(func() { setDongpiandiOfficialOnly(false) })
	setDongpiandiOfficialOnly(true)
	resetDongpiandiLineCache(t)
	d := &Downloader{}
	task := Task{Chapter: Chapter{ID: providerDramaID(sourceDongpiandi, "av_ep2")}}

	// 缓存为空（冷启动续播最常见）：没有证据说它是三方，不能拦。
	if d.dongpiandiOfficialOnlyBlocksAddress(context.Background(), task, "http://x/v.m3u8") {
		t.Fatal("缓存为空时不应拦截地址，否则冷启动首播付全链重解析、失败即播不了")
	}

	// 缓存明确登记为三方：拦。
	dongpiandiCacheLines("av_ep2", zzThirdOnlyLines("http://cache.test"), false)
	if !d.dongpiandiOfficialOnlyBlocksAddress(context.Background(), task, "http://cache.test/v/index.m3u8") {
		t.Fatal("缓存登记为三方的地址必须拦截")
	}
	// 缓存里有官方线：官方地址放行。
	dongpiandiCacheLines("av_ep2", []dongpiandiLine{
		{Label: "官方", URL: "http://cache.test/official.mp4", URLKind: "mp4", Official: true},
		{Label: "三方", URL: "http://cache.test/v/index.m3u8", URLKind: "m3u8"},
	}, true)
	if d.dongpiandiOfficialOnlyBlocksAddress(context.Background(), task, "http://cache.test/official.mp4") {
		t.Fatal("缓存登记为官方的地址不应拦截")
	}
}

// 健康诊断旁路：only 开启时，诊断上下文里的解析仍能看到全部线路。
func TestDongpiandiHealthBypassKeepsAllLines(t *testing.T) {
	t.Cleanup(func() { setDongpiandiOfficialOnly(false) })
	setDongpiandiOfficialOnly(true)
	srv := newZZTicketServer(t, map[string]dongpiandiLine{
		"tk-a": {Label: "官方线甲", URL: "http://127.0.0.1:9/official.mp4", URLKind: "mp4"},
	})
	srv.resolve = dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": srv.server.URL + "/v/index.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900},
		{"id": "l2", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 500},
	})
	withDongpiandiBaseURL(t, srv.server.URL)
	client := newDongpiandiClient()

	// 播放路径：三方被过滤，只剩官方。
	playCtx := context.Background()
	set, err := dongpiandiResolveLinesSet(playCtx, client, "token2", false, true, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Lines) != 1 || !set.Lines[0].Official {
		t.Fatalf("播放路径应只保留官方线: %+v", set.Lines)
	}

	// 诊断路径（bypass）：三方线保留，站源健康不被误判。
	probeCtx := context.WithValue(context.Background(), officialOnlyBypassKey{}, true)
	set, err = dongpiandiResolveLinesSet(probeCtx, client, "token2", false, true, 0)
	if err != nil {
		t.Fatal(err)
	}
	if len(set.Lines) != 2 {
		t.Fatalf("诊断旁路应保留全部线路，得到 %d 条: %+v", len(set.Lines), set.Lines)
	}
}

// 报错区分：站点没给票 vs 票据兑换失败（资源暂不可用）。
func TestDongpiandiOnlyErrorMessageDistinguishesTickets(t *testing.T) {
	t.Cleanup(func() { setDongpiandiOfficialOnly(false) })
	setDongpiandiOfficialOnly(true)

	newTask := func(srv *zzTicketServer) Task {
		return Task{Chapter: Chapter{
			ID:      providerDramaID(sourceDongpiandi, "av_ep2"),
			PageURL: srv.server.URL + "/player/av_1",
		}}
	}
	d := &Downloader{}
	ctx := context.Background()

	// a) 站点没有下发票据（只有三方直连）：提示「未提供官方线路」。
	srv := newZZTicketServer(t, map[string]dongpiandiLine{})
	srv.resolve = dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": srv.server.URL + "/v/index.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900},
	})
	withDongpiandiBaseURL(t, srv.server.URL)
	_, err := d.resolveDongpiandiMedia(ctx, newTask(srv))
	if err == nil || !strings.Contains(err.Error(), "未提供官方线路") {
		t.Fatalf("无票据剧应报「未提供官方线路」: %v", err)
	}

	// b) 站点下发了票据但兑换失败（资源暂不可用）：提示「官方线路暂时不可用」。
	resetDongpiandiLineCache(t)
	srv2 := newZZTicketServer(t, map[string]dongpiandiLine{})
	srv2.resolve = dongpiandiLineOptionsJSON([]map[string]any{
		{"id": "l1", "label": "无水印资源", "url": srv2.server.URL + "/v/index.mp4", "url_kind": "mp4", "resolved": true, "preference_weight": 900},
		{"id": "l2", "label": "官方线甲", "url": "resolve://tk-a", "url_kind": "resolve_ticket", "resolved": false, "preference_weight": 500},
	})
	// resolve-line 返回 {}（无 line 字段）→ 兑换失败。
	srv2.ticketOff = true
	withDongpiandiBaseURL(t, srv2.server.URL)
	_, err = d.resolveDongpiandiMedia(ctx, newTask(srv2))
	if err == nil || !strings.Contains(err.Error(), "官方线路暂时不可用") {
		t.Fatalf("票据兑换失败应报「官方线路暂时不可用」: %v", err)
	}
}
