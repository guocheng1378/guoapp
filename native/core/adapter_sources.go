package core

import (
	"context"
	"duanjuapp/native/provider"
	_ "duanjuapp/native/sources/all"
	"errors"
)

func init() {
	for _, entry := range provider.All() {
		spec := entry.Spec()
		if spec.Family != provider.FamilyDuanju {
			continue
		}
		if provider.IsRegistered(spec.ID) {
			continue
		}
		provider.Register(newDuanjuSourceAdapter(spec))
	}
}

type duanjuSourceAdapter struct {
	spec        provider.Spec
	categories  func(d *Downloader, ctx context.Context) ([]nativeCategory, error)
	catalogPage func(d *Downloader, ctx context.Context, page int, category string) ([]Drama, bool, error)
	detail      func(d *Downloader, ctx context.Context, sourceID string) (Drama, []Chapter, error)
	search      func(d *Downloader, ctx context.Context, query string) ([]Drama, error)
}

func (adapter *duanjuSourceAdapter) Spec() provider.Spec { return adapter.spec }

func (adapter *duanjuSourceAdapter) bind(d *Downloader) *boundDuanjuSourceAdapter {
	return &boundDuanjuSourceAdapter{adapter: adapter, downloader: d}
}

type boundDuanjuSourceAdapter struct {
	adapter    *duanjuSourceAdapter
	downloader *Downloader
}

func (bound *boundDuanjuSourceAdapter) Spec() provider.Spec {
	return bound.adapter.spec
}

func (bound *boundDuanjuSourceAdapter) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	if static, found := duanjuStaticCategories[bound.adapter.spec.ID]; found {
		categories := make([]nativeCategory, 0, len(static))
		for _, entry := range static {
			categories = append(categories, nativeCategory{ID: entry.ID, Name: entry.Name})
		}
		return categories, nil
	}
	if bound.adapter.categories == nil {
		return nil, errors.New("该站源暂未提供分类")
	}
	return bound.adapter.categories(bound.downloader, ctx)
}

func (bound *boundDuanjuSourceAdapter) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]Drama, bool, error) {
	if bound.adapter.catalogPage == nil {
		return nil, false, errors.New("该站源暂未接入目录")
	}
	return bound.adapter.catalogPage(bound.downloader, ctx, page, category)
}

func (bound *boundDuanjuSourceAdapter) Detail(ctx context.Context, host provider.Host, sourceID string) (Drama, []Chapter, error) {
	if bound.adapter.detail == nil {
		return Drama{}, nil, errors.New("该站源暂未接入详情")
	}
	return bound.adapter.detail(bound.downloader, ctx, sourceID)
}

func (bound *boundDuanjuSourceAdapter) Search(ctx context.Context, host provider.Host, query string) ([]Drama, error) {
	if bound.adapter.search == nil {
		return nil, errors.New("该站源不支持在线搜索")
	}
	return bound.adapter.search(bound.downloader, ctx, query)
}

func newDuanjuSourceAdapter(spec provider.Spec) *duanjuSourceAdapter {
	adapter := &duanjuSourceAdapter{spec: spec}
	switch spec.ID {
	case sourceSorani:
		adapter.catalogPage = func(d *Downloader, ctx context.Context, page int, category string) ([]Drama, bool, error) {
			return d.fetchSoraniCatalogPage(ctx, page, category, "")
		}
		adapter.detail = func(d *Downloader, ctx context.Context, sourceID string) (Drama, []Chapter, error) {
			return d.fetchSoraniDetail(ctx, sourceID)
		}
		adapter.search = func(d *Downloader, ctx context.Context, query string) ([]Drama, error) {
			items, _, err := d.fetchSoraniCatalogPage(ctx, 1, "", query)
			return items, err
		}
	case sourceDongpiandi:
		adapter.categories = func(d *Downloader, ctx context.Context) ([]nativeCategory, error) {
			return fetchDongpiandiCategories(), nil
		}
		adapter.catalogPage = func(d *Downloader, ctx context.Context, page int, category string) ([]Drama, bool, error) {
			return d.fetchDongpiandiCatalogPage(ctx, page, category, "")
		}
		adapter.detail = func(d *Downloader, ctx context.Context, sourceID string) (Drama, []Chapter, error) {
			return d.fetchDongpiandiDetail(ctx, sourceID)
		}
		adapter.search = func(d *Downloader, ctx context.Context, query string) ([]Drama, error) {
			return d.searchDongpiandi(ctx, query)
		}
	}
	return adapter
}

func duanjuCatalogSpecs() []duanjuSourceSpec {
	specs := []duanjuSourceSpec{}
	for _, entry := range provider.All() {
		if spec := entry.Spec(); spec.Family == provider.FamilyDuanju {
			specs = append(specs, spec)
		}
	}
	return specs
}

func duanjuSourceRegistered(source string) bool {
	entry, found := provider.Get(source)
	if !found {
		return false
	}
	if _, ok := entry.(*duanjuSourceAdapter); ok {
		return true
	}
	_, ok := entry.(provider.Cataloguer)
	return ok
}

func duanjuSourceFor(d *Downloader, source string) provider.Provider {
	entry, found := provider.Get(source)
	if !found {
		return nil
	}
	if adapter, ok := entry.(*duanjuSourceAdapter); ok {
		return adapter.bind(d)
	}
	return entry
}

var (
	_ provider.Cataloguer = (*boundDuanjuSourceAdapter)(nil)
	_ provider.Detailer   = (*boundDuanjuSourceAdapter)(nil)
	_ provider.Searcher   = (*boundDuanjuSourceAdapter)(nil)
)
