package maccmsweb

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

const (
	fallbackCatalogBody = `<html><body>
	<ul id="home1" class="_9dbe81752a1dbf17-vodlist clearfix">
	<li class="_9dbe81752a1dbf17-vodlist__item">
	<a class="_9dbe81752a1dbf17-vodlist__thumb lazyload" href="/zywview/20523.html" title="回退测试剧" data-original="https://pic.example.cn/a.jpg"><span class="pic-text">全集</span></a>
	<h4 class="_9dbe81752a1dbf17-vodlist__title"><a href="/zywview/20523.html" title="回退测试剧">回退测试剧</a></h4>
	</li></ul></body></html>`
	fallbackDetailBody = `<html><body>
	<h1>回退测试剧</h1>
	<div class="pcDrama_catalogList">
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/20523/sid/1/nid/1.html">第1集</a>
	<a class="pcDrama_catalogItem" href="/index.php/vod/play/id/20523/sid/1/nid/2.html">第2集</a>
	</div></body></html>`
)

// fallbackHost 让运行时覆盖域恒定失败、内置域成功，用于验证两跳回退。
type fallbackHost struct {
	primary string
	body    string
	calls   []string
}

func (h *fallbackHost) JSON(context.Context, provider.Request) (map[string]any, error) {
	return nil, errors.New("测试不支持 JSON")
}

func (h *fallbackHost) Text(_ context.Context, request provider.Request) (string, error) {
	h.calls = append(h.calls, request.Address)
	if h.primary != "" && strings.HasPrefix(request.Address, h.primary) {
		return "", errors.New("覆盖域不可用")
	}
	return h.body, nil
}

func (h *fallbackHost) Bytes(context.Context, provider.Request) ([]byte, error) {
	return nil, errors.New("测试不支持 Bytes")
}

func (h *fallbackHost) BaseURL(string) string { return h.primary }

func (h *fallbackHost) MediaPlaylist(context.Context, string, string) (string, string, error) {
	return "", "", errors.New("测试不支持 MediaPlaylist")
}

func fallbackSource() *Source {
	return New(provider.Spec{
		ID:   provider.SourceHuaguo,
		Name: "花国",
		Base: "https://builtin.example.cn",
	})
}

func TestCatalogPageFallsBackToBuiltinBase(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackCatalogBody}
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("回退内置域后仍应成功: %v", err)
	}
	if len(items) != 1 || items[0].SourceID != "20523" {
		t.Fatalf("回退后条目不符: %+v", items)
	}
	if len(host.calls) != 2 {
		t.Fatalf("应先试覆盖域再回退内置域: %v", host.calls)
	}
	if !strings.HasPrefix(host.calls[0], "https://mirror.example.cn") {
		t.Fatalf("首跳应为覆盖域: %s", host.calls[0])
	}
	if !strings.HasPrefix(host.calls[1], "https://builtin.example.cn") {
		t.Fatalf("次跳应为内置域: %s", host.calls[1])
	}
}

// 命中内置域后，卡片相对地址必须按内置域补全（不能残留覆盖域）。
func TestCatalogPageUsesHitBaseForCards(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackCatalogBody}
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	cover, _ := items[0].Cover.(string)
	if !strings.HasPrefix(cover, "https://pic.example.cn") {
		t.Fatalf("封面应保持源站绝对地址: %v", items[0].Cover)
	}
}

func TestSearchFallsBackToBuiltinBase(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackCatalogBody}
	items, err := source.Search(context.Background(), host, "回退")
	if err != nil {
		t.Fatalf("搜索回退后仍应成功: %v", err)
	}
	if len(items) != 1 {
		t.Fatalf("搜索回退后条目不符: %+v", items)
	}
	if len(host.calls) != 2 || !strings.HasPrefix(host.calls[1], "https://builtin.example.cn") {
		t.Fatalf("搜索应先试覆盖域再回退内置域: %v", host.calls)
	}
}

func TestDetailFallsBackToBuiltinBase(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackDetailBody}
	drama, chapters, err := source.Detail(context.Background(), host, "20523")
	if err != nil {
		t.Fatalf("详情回退后仍应成功: %v", err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集数不符: %d", len(chapters))
	}
	if drama.SourceID != "20523" {
		t.Fatalf("详情 ID 不符: %s", drama.SourceID)
	}
	// 命中内置域后，章节地址与 Referer 必须落在内置域。
	if !strings.HasPrefix(chapters[0].PageURL, "https://builtin.example.cn") {
		t.Fatalf("分集地址应落在命中域: %s", chapters[0].PageURL)
	}
	if !strings.HasPrefix(chapters[0].Referer, "https://builtin.example.cn") {
		t.Fatalf("分集 Referer 应用命中域: %s", chapters[0].Referer)
	}
	if len(host.calls) != 2 || !strings.HasPrefix(host.calls[1], "https://builtin.example.cn") {
		t.Fatalf("详情应先试覆盖域再回退内置域: %v", host.calls)
	}
}

// TestCatalogPageReusesHitBaseAcrossCalls 目录翻页是逐次调用，
// 命中域必须在调用之间记住，否则每页都要再等一次死域超时。
func TestCatalogPageReusesHitBaseAcrossCalls(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackCatalogBody}
	if _, _, err := source.CatalogPage(context.Background(), host, 1, "", ""); err != nil {
		t.Fatalf("第一页: %v", err)
	}
	if len(host.calls) != 2 {
		t.Fatalf("第一页应两跳后命中: %v", host.calls)
	}
	host.calls = nil
	if _, _, err := source.CatalogPage(context.Background(), host, 2, "", ""); err != nil {
		t.Fatalf("第二页: %v", err)
	}
	if len(host.calls) != 1 || !strings.HasPrefix(host.calls[0], "https://builtin.example.cn") {
		t.Fatalf("第二页应直接复用命中域: %v", host.calls)
	}
}

// TestOrderedBasesDropsHitWhenOverrideChanges 远程换了覆盖域，旧命中判断必须作废。
func TestOrderedBasesDropsHitWhenOverrideChanges(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn", body: fallbackCatalogBody}
	if _, _, err := source.CatalogPage(context.Background(), host, 1, "", ""); err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	host.primary = "https://mirror2.example.cn"
	got := source.orderedBases(host)
	if len(got) != 2 || got[0] != "https://mirror2.example.cn" || got[1] != "https://builtin.example.cn" {
		t.Fatalf("覆盖域变更后应重新按新覆盖域优先: %v", got)
	}
}

// TestOrderedBasesIgnoresExpiredHit 命中域会过期，避免覆盖域修好后仍永久降级。
func TestOrderedBasesIgnoresExpiredHit(t *testing.T) {
	source := fallbackSource()
	host := &fallbackHost{primary: "https://mirror.example.cn"}
	source.hitMu.Lock()
	source.hit = baseHit{
		base:    "https://builtin.example.cn",
		primary: "https://mirror.example.cn",
		at:      time.Now().Add(-baseHitTTL - time.Minute),
	}
	source.hitMu.Unlock()
	got := source.orderedBases(host)
	if len(got) != 2 || got[0] != "https://mirror.example.cn" {
		t.Fatalf("命中域过期后应回到覆盖域优先: %v", got)
	}
}

func TestBasesDedupesBuiltin(t *testing.T) {
	source := fallbackSource()
	if got := source.bases(nil); len(got) != 1 || got[0] != "https://builtin.example.cn" {
		t.Fatalf("无覆盖时只应有一个 base: %v", got)
	}
	same := &fallbackHost{primary: "https://builtin.example.cn/"}
	if got := source.bases(same); len(got) != 1 {
		t.Fatalf("覆盖值等于内置域时应去重: %v", got)
	}
	overridden := &fallbackHost{primary: "https://mirror.example.cn/"}
	got := source.bases(overridden)
	if len(got) != 2 || got[0] != "https://mirror.example.cn" || got[1] != "https://builtin.example.cn" {
		t.Fatalf("覆盖时应返回覆盖域+内置域: %v", got)
	}
}
