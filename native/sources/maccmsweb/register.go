package maccmsweb

import (
	"duanjuapp/native/provider"
)

func init() {
	for _, id := range []string{
		provider.SourceHuaguo,
		provider.SourceFaguo,
		provider.SourceWuguo,
		provider.SourceWangguo,
	} {
		if spec, found := provider.SpecOf(id); found {
			provider.Register(New(spec))
		}
	}
}

var (
	_ provider.Cataloguer    = (*Source)(nil)
	_ provider.Detailer      = (*Source)(nil)
	_ provider.Searcher      = (*Source)(nil)
	_ provider.MediaResolver = (*Source)(nil)
)
