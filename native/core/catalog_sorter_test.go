package core

import (
	"context"
	"net/http"
	"net/url"
	"testing"

	"duanjuapp/native/provider"
)

// fakeSortCataloguer 只实现 Cataloguer 的站源：任何 sort 都应回退到 CatalogPage。
type fakeSortCataloguer struct {
	id      string
	pageHit int
}

func (f *fakeSortCataloguer) Spec() provider.Spec {
	return provider.Spec{ID: f.id, Name: f.id, Family: provider.FamilyDuanju}
}

func (f *fakeSortCataloguer) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	return nil, nil
}

func (f *fakeSortCataloguer) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]Drama, bool, error) {
	f.pageHit++
	return []Drama{{ID: f.id + ":1", Title: "源站顺序"}}, false, nil
}

func (f *fakeSortCataloguer) fetch(ctx context.Context, page int, category, sort string) ([]Drama, bool, error) {
	return (&nativeEngine{downloader: &Downloader{}}).downloader.fetchDuanjuCatalogPage(ctx, f.id, page, category, sort)
}

// fakeSortSorted 同时实现 Cataloguer 与 CatalogSorter：有效 sort 应走服务端排序。
type fakeSortSorted struct {
	*fakeSortCataloguer
	sortedHits []string
}

func (f *fakeSortSorted) CatalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]Drama, bool, error) {
	f.sortedHits = append(f.sortedHits, sort)
	return []Drama{{ID: f.id + ":2", Title: "服务端排序"}}, false, nil
}

func TestFetchDuanjuCatalogPageSortRouting(t *testing.T) {
	sorted := &fakeSortSorted{fakeSortCataloguer: &fakeSortCataloguer{id: "sorttest-plus"}}
	provider.Register(sorted)
	plain := &fakeSortCataloguer{id: "sorttest-plain"}
	provider.Register(plain)

	ctx := context.Background()
	items, _, err := sorted.fetch(ctx, 1, "", "heat")
	if err != nil || len(items) != 1 || items[0].Title != "服务端排序" {
		t.Fatalf("sorted source should serve server-side sort: %+v %v", items, err)
	}
	if len(sorted.sortedHits) != 1 || sorted.sortedHits[0] != "heat" || sorted.pageHit != 0 {
		t.Fatalf("sort routing missed CatalogPageSorted: hits=%v page=%d", sorted.sortedHits, sorted.pageHit)
	}
	if _, _, err := sorted.fetch(ctx, 1, "", ""); err != nil {
		t.Fatal(err)
	}
	if _, _, err := sorted.fetch(ctx, 1, "", "source"); err != nil {
		t.Fatal(err)
	}
	if len(sorted.sortedHits) != 1 || sorted.pageHit != 2 {
		t.Fatalf("empty/source sort must fall back to CatalogPage: hits=%v page=%d", sorted.sortedHits, sorted.pageHit)
	}

	items, _, err = plain.fetch(ctx, 1, "", "heat")
	if err != nil || len(items) != 1 || items[0].Title != "源站顺序" {
		t.Fatalf("plain source should fall back to CatalogPage: %+v %v", items, err)
	}
	if plain.pageHit != 1 {
		t.Fatalf("plain source unexpectedly served a sort: page=%d", plain.pageHit)
	}
}

func TestNativeCatalogHuangjuSortMapping(t *testing.T) {
	var queries []url.Values
	engine := sourceFixtureEngine(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path == "/auth/guest" {
			return sourceFixtureResponse(request, http.StatusOK, `{"token":"guest-token"}`), nil
		}
		if request.URL.Path != "/dramas" {
			t.Fatalf("unexpected huangju request: %s", request.URL.String())
		}
		queries = append(queries, request.URL.Query())
		return sourceFixtureResponse(request, http.StatusOK, `{"items":[{"id":"301","slug":"sort-a","title":"排序样本"}],"page":1,"pageSize":20,"total":1}`), nil
	})

	ctx := context.Background()
	for _, input := range []nativeInput{
		{Source: sourceHuangju, Page: 1, Sort: "date"},
		{Source: sourceHuangju, Page: 1, Sort: "heat"},
		{Source: sourceHuangju, Page: 1, Sort: "views"},
		{Source: sourceHuangju, Page: 1, Sort: "DROP TABLE"},
		{Source: sourceHuangju, Page: 1, Category: huangjuNewestCategory, Sort: "date"},
	} {
		if _, err := engine.nativeCatalog(ctx, input); err != nil {
			t.Fatalf("%s catalog failed: %v", input.Sort, err)
		}
	}
	if len(queries) != 5 {
		t.Fatalf("each cache key must fetch once: %d", len(queries))
	}
	assertions := []struct {
		index    int
		sort     string
		category string
		note     string
	}{
		{0, "new", "", "date maps to the newest feed"},
		{1, "hot", "", "heat keeps the default hot feed"},
		{2, "hot", "", "views falls back to the hot feed"},
		{3, "hot", "", "invalid sort is normalized away"},
		{4, "new", "", "newest category keeps its native sort=new channel"},
	}
	for _, want := range assertions {
		query := queries[want.index]
		if got := query.Get("sort"); got != want.sort {
			t.Fatalf("%s: sort=%q want %q", want.note, got, want.sort)
		}
		if got := query.Get("category"); got != want.category {
			t.Fatalf("%s: category=%q want %q", want.note, got, want.category)
		}
	}
}
