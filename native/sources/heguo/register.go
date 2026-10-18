package heguo

import (
	"duanjuapp/native/provider"
)

func init() {
	if spec, found := provider.SpecOf(provider.SourceHeguo); found {
		provider.Register(New(spec))
	}
}

var (
	_ provider.Cataloguer    = (*Source)(nil)
	_ provider.Detailer      = (*Source)(nil)
	_ provider.Searcher      = (*Source)(nil)
	_ provider.MediaResolver = (*Source)(nil)
)
