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
	// 成人源：typeID 在请求中已不参与路由（catalog func 固定路径），留空即可。
	// 2026-10-19 探针剔除 7 个死源（maodou/naixx/shayu/jingpin/lajiao/xibao/xiangjiao）。
	provider.SourceZY155:   "",
	provider.SourceYutu:    "",
	provider.SourceFanhao:  "",
	provider.SourceLsbzy:   "",
	provider.SourceHsck:    "",
	provider.SourceDanaizi: "",
	provider.SourceJkun:    "",
	provider.SourceLebo:    "",
	provider.SourceSenlin:  "",
	provider.SourceDoudou:  "",
	provider.SourceDidi:    "",
	provider.SourceHeiliao: "",
	provider.SourceTaohua:  "",
	provider.SourceSouav:   "",
	provider.SourceCkzy:    "",
	provider.SourceAosika:  "",
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
	_ provider.Cataloguer    = (*Source)(nil)
	_ provider.CatalogSorter = (*Source)(nil)
	_ provider.Detailer      = (*Source)(nil)
	_ provider.Searcher      = (*Source)(nil)
)
