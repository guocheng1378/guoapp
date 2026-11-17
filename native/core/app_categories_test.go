package core

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"strconv"
	"strings"
	"testing"
)

func TestNativeCategoryPaginationStaysIndependent(t *testing.T) {
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		target := huangguoEdgeTarget(t, request)
		if !strings.HasPrefix(target.Path, "/api/videos/category/ai-") {
			return nil, errors.New("unexpected path: " + target.Path)
		}
		page, _ := strconv.Atoi(target.Query().Get("page"))
		if page < 1 {
			page = 1
		}
		count := 35
		if page != 1 {
			count = 1
		}
		rows := make([]map[string]any, 0, count)
		for index := 0; index < count; index++ {
			rows = append(rows, map[string]any{
				"id": fmt.Sprintf("fixture-p%d-%d", page, index), "title": "合成分类剧集",
			})
		}
		return sourceFixtureResponse(request, 200, huangguoEdgeReply(rows)), nil
	})
	for _, input := range []nativeInput{
		{Source: sourceHuangguoAI, Category: "ai-duanju", Page: 1},
		{Source: sourceHuangguoAI, Category: "ai-duanju", Page: 2},
		{Source: sourceHuangguoAI, Category: "ai-manju", Page: 1},
	} {
		if _, err := engine.nativeCatalog(context.Background(), input); err != nil {
			t.Fatal(err)
		}
	}
	short := engine.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-duanju", ""))
	comic := engine.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-manju", ""))
	if short.Page != 2 || short.HasMore || len(short.Items) != 36 || comic.Page != 1 || !comic.HasMore || len(comic.Items) != 35 {
		t.Fatal("category cursors or entries leaked", short.Page, short.HasMore, len(short.Items), comic.Page, comic.HasMore, len(comic.Items))
	}
	for _, row := range comic.Items {
		if !strings.Contains(row.ID, "ai-manju") && !strings.Contains(row.SourceID, "fixture") {
			t.Fatal("another category was merged into the selected list")
		}
	}
	if len(engine.nativeCached(sourceHuangguoAI).Items) != 36 {
		t.Fatal("source management lost categorized titles")
	}
	restored := &nativeEngine{directory: engine.directory, catalogs: map[string][]nativeDrama{}, catalogStates: map[string]nativeCatalogState{}}
	restored.loadCatalogCache()
	if restored.nativeCached(nativeCatalogKey(sourceHuangguoAI, "ai-duanju", "")).Page != 2 {
		t.Fatal("category position was not persisted")
	}
}

func TestNativeCategoryDiscoveryUsesSourceLinks(t *testing.T) {
	for _, source := range []string{sourceHongguo, sourceHuangdou, sourceHuangguoAI, sourceCloudFront} {
		if validNativeCategory(source, "../other|source") {
			t.Fatal("invalid category entered a cache namespace")
		}
		if err := nativeAuthorizeInput(nativeInput{Action: "categories", Source: source}); (err == nil) != nativeSourceAvailable(source) {
			t.Fatal("categories ignored edition permissions", source, err)
		}
	}
}

func TestLegacyResource404KeepsHealthyEndpoint(t *testing.T) {
	d := legacyFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Path, "/detail/") {
			return sourceFixtureResponse(request, 404, "removed drama"), nil
		}
		return legacyFixtureResponse(request, []Tab{{ID: "active", Name: "合成分类"}}), nil
	})
	d.cfg.Token = "fixture-session"
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	d.apiBase = d.cfg.APIBase
	var detail detailResponse
	if err := d.fetchAPI(context.Background(), "/api/app/playlet/detail/removed", nil, &detail); err == nil {
		t.Fatal("a missing drama was treated as available")
	}
	if d.apiBase != d.cfg.APIBase || len(d.apiFailures) != 0 {
		t.Fatal("one removed drama disabled a healthy API host")
	}
	var tabs legacyTabList
	if err := d.fetchAPI(context.Background(), "/api/app/playlet-tab/all", nil, &tabs); err != nil || len(tabs) != 1 {
		t.Fatal("catalog did not remain usable", err)
	}
}
