package yunzhui

import (
	"duanjuapp/native/provider"
)

func init() {
	if spec, found := provider.SpecOf(provider.SourceYunzhui); found {
		provider.Register(New(spec))
	}
}

var (
	_ provider.Cataloguer    = (*Source)(nil)
	_ provider.CatalogSorter = (*Source)(nil)
	_ provider.Detailer      = (*Source)(nil)
	_ provider.Searcher      = (*Source)(nil)
	_ provider.MediaResolver = (*Source)(nil)
	_ provider.Prober        = (*Source)(nil)
	_ provider.Ranker        = (*Source)(nil)
)
