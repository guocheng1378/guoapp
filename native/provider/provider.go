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

type Config struct {
	AllSources bool
	Hosts      map[string]string
}
