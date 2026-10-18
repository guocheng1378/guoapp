package maccmsapi

import (
	"duanjuapp/native/provider"
)

var dramaTypeIDs = map[string]string{
	provider.SourceYingshigongchang: "46",
	provider.Source360ZY:            "46",
	provider.SourceModu:             "38",
	provider.SourceDytt:             "36",
	provider.SourceNiuniuZY:         "54",
	provider.SourceWsyzy:            "54",
	provider.SourceShandian:         "74",
	provider.SourceHongniu:          "50",
}

func init() {
	for id, typeID := range dramaTypeIDs {
		spec, found := provider.SpecOf(id)
		if !found {
			continue
		}
		provider.Register(New(spec, typeID))
	}
}

var (
	_ provider.Cataloguer = (*Source)(nil)
	_ provider.Detailer   = (*Source)(nil)
	_ provider.Searcher   = (*Source)(nil)
)
