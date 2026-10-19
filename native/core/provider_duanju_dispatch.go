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
			return sorted.CatalogPageSorted(ctx, d.host(), page, category, sort)
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
	source = canonicalProviderSource(source)
	searcher, ok := duanjuSourceFor(d, source).(provider.Searcher)
	if !ok {
		return nil, errors.New("该站源不支持在线搜索")
	}
	return searcher.Search(ctx, d.host(), query)
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
		if err != nil {
			return providerMedia{}, err
		}
		return providerMediaFromResolved(media), nil
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
