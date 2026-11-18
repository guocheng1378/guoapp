package provider

import (
	"context"
	"time"
)

type Category string

const (
	CategoryShortDrama Category = "shortDrama"
	CategoryVideo      Category = "video"
	CategoryAdult      Category = "adult"
)

type Family string

const (
	FamilyDuanju   Family = "duanju"
	FamilyHuangguo Family = "huangguo"
)

type Spec struct {
	ID                 string
	Name               string
	Base               string
	Kind               string
	Agent              string
	Referer            string
	Headers            map[string]string // 自定义站源的 UA/防盗链头，随每个 Request 下发
	Category           Category
	Family             Family
	Searcher           bool
	Paged              bool
	Browser            bool
	RequiresAllSources bool
}

type Provider interface {
	Spec() Spec
}

type Cataloguer interface {
	Provider
	Categories(ctx context.Context, host Host) ([]CatalogCategory, error)
	CatalogPage(ctx context.Context, host Host, page int, category, query string) ([]Drama, bool, error)
}

// CatalogSorter 是目录排序的可选扩展：实现的源在目录请求里携带服务端排序参数，
// 让「热度/最新」等排序作用在源站全量数据上（而非客户端已加载的分页片段）。
// sort 词表沿用客户端 CatalogSort 枚举名：heat、views、date；空串表示源站顺序。
// 只实现 Cataloguer 的源不受影响，调度层会自动回退到 CatalogPage + 客户端排序。
type CatalogSorter interface {
	Provider
	CatalogPageSorted(ctx context.Context, host Host, page int, category, sort string) ([]Drama, bool, error)
}

type Detailer interface {
	Provider
	Detail(ctx context.Context, host Host, sourceID string) (Drama, []Chapter, error)
}

type Searcher interface {
	Provider
	Search(ctx context.Context, host Host, query string) ([]Drama, error)
}

// PagedSearcher 是在线搜索分页的可选扩展：调度层把页码直接透传给源，
// hasMore 由源站总页数决定，使搜索与目录共用同一套上拉加载语义。
// 只实现 Searcher 的源仍按单页处理（hasMore=false），不会反复请求第一页。
type PagedSearcher interface {
	Provider
	SearchPage(ctx context.Context, host Host, query string, page int) ([]Drama, bool, error)
}

// WarningSearcher 是搜索带警告的可选扩展（上游 SearchWithWarning）：源站
// 部分结果失败时把原因带回界面，而不是整页报错或静默丢结果。
type WarningSearcher interface {
	Provider
	SearchPageWithWarning(ctx context.Context, host Host, query string, page int) ([]Drama, bool, string, error)
}

type Prober interface {
	Provider
	Probe(ctx context.Context, host Host) (string, error)
}

type Media struct {
	URL      string
	Referer  string
	Duration time.Duration
	Playlist string
	HLSKey   []byte
	CENCKey  []byte
	Quality  int
	Variants []Media
}

type MediaResolver interface {
	Provider
	ResolveMedia(ctx context.Context, host Host, task Task) (Media, error)
}

// Ranker 是榜单的可选扩展：实现的源在榜单页直接提供按服务端排序的条目，
// 由 core 的 fetchProviderRankingPage 统一收口（落盘/缓存/在途去重复用同一套）。
type Ranker interface {
	Provider
	RankingPage(ctx context.Context, host Host, path string, page int) ([]Drama, error)
}

type Config struct {
	AllSources bool
	Hosts      map[string]string
}
