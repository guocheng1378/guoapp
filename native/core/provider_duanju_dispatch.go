package core

import (
	"context"
	"duanjuapp/native/provider"
	"errors"
	"fmt"
	"strings"
)

func (d *Downloader) fetchDuanjuCategories(ctx context.Context, source string) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	if !isDuanjuProviderSource(source) {
		return nil, errors.New("该站源不支持分类读取")
	}
	cataloguer, ok := duanjuSourceFor(d, source).(provider.Cataloguer)
	if !ok {
		return nil, errors.New("该站源暂未提供分类")
	}
	return cataloguer.Categories(ctx, d.host())
}

func (d *Downloader) fetchDuanjuCatalogPage(ctx context.Context, source string, page int, category, sort string) ([]Drama, bool, error) {
	source = canonicalProviderSource(source)
	cataloguer, ok := duanjuSourceFor(d, source).(provider.Cataloguer)
	if !ok {
		return nil, false, errors.New("该站源暂未接入目录")
	}
	// 服务端排序：源实现 CatalogSorter 且 sort 有效时下传，否则回退源站顺序
	//（客户端 sortCatalog 兜底排序不受影响）。
	switch sort = strings.TrimSpace(sort); sort {
	case "", "source":
	default:
		if sorted, sorted_ok := cataloguer.(provider.CatalogSorter); sorted_ok {
			items, more, err := sorted.CatalogPageSorted(ctx, d.host(), page, category, sort)
			if err == nil {
				return items, more, nil
			}
			// 模块没覆盖该排序/该分类时回落源站顺序，而不是把错误抛给上层：
			// nativeCatalog 重试同一函数只会再失败一次，整页变成空白+报错。
			// 客户端 sortCatalog 仍会兜底排序。
		}
	}
	return cataloguer.CatalogPage(ctx, d.host(), page, category, "")
}

func (d *Downloader) fetchDuanjuDetail(ctx context.Context, source, sourceID string) (Drama, []Chapter, error) {
	source = canonicalProviderSource(source)
	detailer, ok := duanjuSourceFor(d, source).(provider.Detailer)
	if !ok {
		return Drama{}, nil, errors.New("该站源暂未接入详情")
	}
	return detailer.Detail(ctx, d.host(), sourceID)
}

func (d *Downloader) searchDuanju(ctx context.Context, source, query string) ([]Drama, error) {
	items, _, _, err := d.searchDuanjuPage(ctx, source, query, 1)
	return items, err
}

// searchDuanjuPage 让在线搜索与目录共用 page/hasMore 语义。实现
// PagedSearcher 的源（maccms 视频源）按页拉取；只实现 Searcher 的源
// 仍是单页结果，hasMore=false，不会每次上拉都重复第一页。
// warning 是源站部分失败时的说明（实现 WarningSearcher 的源才会给）。
func (d *Downloader) searchDuanjuPage(ctx context.Context, source, query string, page int) ([]Drama, bool, string, error) {
	source = canonicalProviderSource(source)
	entry := duanjuSourceFor(d, source)
	if warn, ok := entry.(provider.WarningSearcher); ok {
		items, more, warning, err := warn.SearchPageWithWarning(ctx, d.host(), query, page)
		// 模块只导出 search、没导出 searchWithWarning 时，这一层会回
		// errModuleCapabilityUnsupported。必须继续往下回落普通分页搜索，
		// 否则 maccms 系模块（影视工厂/360/魔都/电影天堂…）的搜索会被
		// 静默判死——表现就是「搜索只剩真果·鉴」。
		if !errors.Is(err, errModuleCapabilityUnsupported) {
			return items, more, warning, err
		}
	}
	if paged, ok := entry.(provider.PagedSearcher); ok {
		items, more, err := paged.SearchPage(ctx, d.host(), query, page)
		return items, more, "", err
	}
	searcher, ok := entry.(provider.Searcher)
	if !ok {
		return nil, false, "", errors.New("该站源不支持在线搜索")
	}
	items, err := searcher.Search(ctx, d.host(), query)
	return items, false, "", err
}

func duanjuSupportsSearch(source string) bool {
	spec, found := duanjuSourceSpecFor(source)
	return found && spec.Searcher
}

func duanjuSupportsPaging(source string) bool {
	spec, found := duanjuSourceSpecFor(source)
	return found && spec.Paged
}

// providerMediaFromResolved 把独立包返回的 provider.Media 映射回 core 内部结构。
func providerMediaFromResolved(media provider.Media) providerMedia {
	converted := providerMedia{
		URL:      media.URL,
		Referer:  media.Referer,
		Duration: media.Duration,
		Playlist: media.Playlist,
		HLSKey:   media.HLSKey,
		CENCKey:  media.CENCKey,
		Quality:  media.Quality,
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, providerMediaFromResolved(variant))
	}
	return converted
}

func (d *Downloader) resolveDuanjuMedia(ctx context.Context, task Task) (providerMedia, error) {
	source := canonicalProviderSource(task.Chapter.Source)
	// 独立包站源自带播放解析（provider.MediaResolver），优先走注册表。
	if resolver, ok := duanjuSourceFor(d, source).(provider.MediaResolver); ok {
		media, err := resolver.ResolveMedia(ctx, d.host(), task)
		if err == nil {
			return providerMediaFromResolved(media), nil
		}
		// 模块取流失败（只覆盖部分线路 / 站点改版）时继续走下面的内置
		// 「详情刷新 + 播放页解析」兜底，不要直接判死整条播放。
	}
	name := duanjuSourceName(source)
	base := d.duanjuBaseURL(source)
	if base == "" {
		return providerMedia{}, errors.New("站源地址不可用")
	}
	address := strings.TrimSpace(task.Chapter.VideoURL)
	pageURL := strings.TrimSpace(task.Chapter.PageURL)
	referer := firstNonEmpty(task.Chapter.Referer, base+"/")
	// 网页型站源的分集保存在详情页，需要即时解析真实播放地址。
	if !isProviderHTTPMediaURL(address) || !duanjuLooksLikeMedia(address) {
		if pageURL == "" {
			if source, sourceID, valid := splitProviderDramaID(task.DramaID); valid {
				if _, chapters, err := d.fetchDuanjuDetail(ctx, source, sourceID); err == nil {
					for _, fresh := range chapters {
						if fresh.ID == task.Chapter.ID {
							address = fresh.VideoURL
							pageURL = fresh.PageURL
							break
						}
					}
				}
			}
		}
		if pageURL != "" {
			resolved, err := d.resolveDuanjuWebPage(ctx, source, pageURL, referer)
			if err != nil {
				return providerMedia{}, err
			}
			return d.prepareWebProviderMedia(ctx, resolved, name)
		}
	}
	if !isProviderHTTPMediaURL(address) {
		return providerMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新章节后重试", name)
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address, Referer: referer}, name)
}

func duanjuLooksLikeMedia(address string) bool {
	return provider.LooksLikeMedia(address)
}

func (d *Downloader) resolveDuanjuWebPage(ctx context.Context, source, pageURL, referer string) (providerMedia, error) {
	body, err := d.fetchProviderText(ctx, pageURL, referer)
	if err != nil {
		return providerMedia{}, err
	}
	address := provider.NormalizePlaybackURL(provider.PlayerURL(body))
	if address == "" {
		return providerMedia{}, fmt.Errorf("%s未返回有效播放地址，请刷新章节后重试", duanjuSourceName(source))
	}
	return providerMedia{URL: address, Referer: pageURL}, nil
}

func (d *Downloader) duanjuSourceProbe(ctx context.Context, source string) (string, error) {
	source = canonicalProviderSource(source)
	items, _, err := d.fetchDuanjuCatalogPage(ctx, source, 1, "", "")
	if err != nil {
		return "", err
	}
	if len(items) == 0 {
		return "", errors.New("站源入口可达，但没有解析到有效剧集")
	}
	return fmt.Sprintf("已解析 %d 部剧", len(items)), nil
}

func duanjuFirstCategory(source string) string {
	if static, found := duanjuStaticCategories[canonicalProviderSource(source)]; found && len(static) > 0 {
		return static[0].ID
	}
	return ""
}
