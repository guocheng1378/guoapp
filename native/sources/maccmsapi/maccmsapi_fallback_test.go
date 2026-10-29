package maccmsapi

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

// failPrimaryHost 让运行时覆盖域恒定失败、内置域成功，用于验证两跳回退。
type failPrimaryHost struct {
	fakeHost
	primary string
	calls   []string
}

func (f *failPrimaryHost) BaseURL(string) string { return f.primary }

func (f *failPrimaryHost) Text(ctx context.Context, req provider.Request) (string, error) {
	f.calls = append(f.calls, req.Address)
	if strings.HasPrefix(req.Address, f.primary) {
		return "", errors.New("覆盖域不可用")
	}
	f.address = req.Address
	return f.body, nil
}

func fallbackTestSource() *Source {
	return New(provider.Spec{
		ID:   provider.SourceYingshigongchang,
		Name: "影视工厂",
		Base: "https://builtin.example.com",
	}, "46")
}

func TestCatalogPageFallsBackToBuiltinBase(t *testing.T) {
	source := fallbackTestSource()
	host := &failPrimaryHost{fakeHost: fakeHost{body: catalogFixture}, primary: "https://mirror.example.com"}
	items, _, err := source.CatalogPage(context.Background(), host, 1, "", "")
	if err != nil {
		t.Fatalf("回退内置域后仍应成功: %v", err)
	}
	if len(items) != 3 {
		t.Fatalf("回退后条目数不符: %d", len(items))
	}
	if len(host.calls) != 2 {
		t.Fatalf("应先试覆盖域再回退内置域: %v", host.calls)
	}
	if !strings.HasPrefix(host.calls[0], "https://mirror.example.com/") {
		t.Fatalf("首跳应为覆盖域: %s", host.calls[0])
	}
	if !strings.HasPrefix(host.calls[1], "https://builtin.example.com") {
		t.Fatalf("次跳应为内置域: %s", host.calls[1])
	}
}

func TestBasesDedupesBuiltin(t *testing.T) {
	source := fallbackTestSource()
	if got := source.bases(&fakeHost{}); len(got) != 1 || got[0] != "https://builtin.example.com" {
		t.Fatalf("无覆盖时只应有一个 base: %v", got)
	}
	same := &failPrimaryHost{primary: "https://builtin.example.com/"}
	if got := source.bases(same); len(got) != 1 {
		t.Fatalf("覆盖值等于内置域时应去重: %v", got)
	}
	overridden := &failPrimaryHost{primary: "https://mirror.example.com"}
	if got := source.bases(overridden); len(got) != 2 || got[0] != "https://mirror.example.com" || got[1] != "https://builtin.example.com" {
		t.Fatalf("覆盖时应返回覆盖域+内置域: %v", got)
	}
}

// TestCatalogPageReusesHitBaseAcrossCalls 目录翻页是逐次调用，
// 命中域必须在调用之间记住，否则每页都要再等一次死域超时。
func TestCatalogPageReusesHitBaseAcrossCalls(t *testing.T) {
	source := fallbackTestSource()
	host := &failPrimaryHost{fakeHost: fakeHost{body: catalogFixture}, primary: "https://mirror.example.com"}
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
	if len(host.calls) != 1 || !strings.HasPrefix(host.calls[0], "https://builtin.example.com") {
		t.Fatalf("第二页应直接复用命中域: %v", host.calls)
	}
}

// TestOrderedBasesDropsHitWhenOverrideChanges 远程换了覆盖域，旧命中判断必须作废。
func TestOrderedBasesDropsHitWhenOverrideChanges(t *testing.T) {
	source := fallbackTestSource()
	host := &failPrimaryHost{fakeHost: fakeHost{body: catalogFixture}, primary: "https://mirror.example.com"}
	if _, _, err := source.CatalogPage(context.Background(), host, 1, "", ""); err != nil {
		t.Fatalf("CatalogPage: %v", err)
	}
	host.primary = "https://mirror2.example.com"
	got := source.orderedBases(host)
	if len(got) != 2 || got[0] != "https://mirror2.example.com" || got[1] != "https://builtin.example.com" {
		t.Fatalf("覆盖域变更后应重新按新覆盖域优先: %v", got)
	}
}

// TestOrderedBasesIgnoresExpiredHit 命中域会过期，避免覆盖域修好后仍永久降级。
func TestOrderedBasesIgnoresExpiredHit(t *testing.T) {
	source := fallbackTestSource()
	host := &failPrimaryHost{primary: "https://mirror.example.com"}
	source.hitMu.Lock()
	source.hit = baseHit{
		base:    "https://builtin.example.com",
		primary: "https://mirror.example.com",
		at:      time.Now().Add(-baseHitTTL - time.Minute),
	}
	source.hitMu.Unlock()
	got := source.orderedBases(host)
	if len(got) != 2 || got[0] != "https://mirror.example.com" {
		t.Fatalf("命中域过期后应回到覆盖域优先: %v", got)
	}
}

// TestCategoriesReusesHitBaseAcrossPages 命中覆盖域后，第二页不应再回头试死域。
func TestCategoriesReusesHitBaseAcrossPages(t *testing.T) {
	source := fallbackTestSource()
	// 覆盖域整体不可用：第一页回退内置域，第二页应直接用内置域。
	host := &failPrimaryHost{fakeHost: fakeHost{body: catalogFixture}, primary: "https://mirror.example.com"}
	if _, err := source.Categories(context.Background(), host); err != nil {
		t.Fatalf("Categories: %v", err)
	}
	if len(host.calls) != 3 {
		t.Fatalf("期望「覆盖域失败+内置域两页」共 3 次请求，实际 %v", host.calls)
	}
	if !strings.HasPrefix(host.calls[1], "https://builtin.example.com") || !strings.HasPrefix(host.calls[2], "https://builtin.example.com") {
		t.Fatalf("命中内置域后应复用，不再试覆盖域: %v", host.calls)
	}
}
