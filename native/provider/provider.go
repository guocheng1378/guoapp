package provider

import (
	"context"
	"time"
)

type Category string

const (
	CategoryShortDrama Category = "shortDrama"
	CategoryVideo      Category = "video"
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
