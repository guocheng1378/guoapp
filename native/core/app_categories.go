package core

import (
	"context"
	"duanjuapp/native/provider"
	"errors"
	"fmt"
	"regexp"
	"strings"
	"sync"
)

type nativeCategory = provider.CatalogCategory

var nativeAICategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI成人短剧"},
	{ID: "ai-manju", Name: "AI成人漫剧"},
	{ID: "ai-huanlian", Name: "AI换脸"},
	{ID: "ai-mogai", Name: "AI魔改"},
	{ID: "chigua", Name: "黄果吃瓜"},
}

func nativeCatalogKey(source, category string) string {
	source = canonicalProviderSource(source)
	if category = strings.TrimSpace(category); category != "" {
		return source + "|" + category
	}
	return source
}

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			if category == genre.key {
				return true
			}
		}
	case sourceHuangguoAI:
		for _, entry := range nativeAICategories {
			if category == entry.ID {
				return true
			}
		}
	case sourceCloudFront:
		return strings.TrimSpace(category) == category
	case sourceHuangju:
		return category == huangjuNewestCategory || validHuangjuID(category) && !strings.HasPrefix(category, "@")
	case sourceYeguo:
		return validYeguoCategory(category)
	}
	if isDuanjuProviderSource(source) {
		return validDuanjuCategory(source, category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	source = canonicalProviderSource(source)
	all := []nativeCategory{{Name: "全部"}}
	switch source {
	case sourceHongguo:
		for _, genre := range hongguoAppGenres {
			all = append(all, nativeCategory{ID: genre.key, Name: genre.name})
		}
		return all, nil
	case sourceHuangguoAI:
		return append(all, nativeAICategories...), nil
	case sourceHuangdou:
		return all, nil
	}
	engine.mu.Lock()
	cached := append([]nativeCategory{}, engine.categoryOptions[source]...)
	engine.mu.Unlock()
	if len(cached) > 1 && !force {
		return cached, nil
	}
	d := engine.downloader
	var err error
	switch source {
	case sourceCloudFront:
		var tabs legacyTabList
		err = d.fetchAPI(ctx, "/api/app/playlet-tab/all", nil, &tabs)
		for _, tab := range tabs {
			if validNativeCategory(source, tab.ID) && tab.ID != "" && tab.Name != "" {
				all = append(all, nativeCategory{ID: tab.ID, Name: tab.Name})
			}
		}
	case sourceHuangju:
		var categories []nativeCategory
		categories, err = d.fetchHuangjuCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceYeguo:
		var categories []nativeCategory
		categories, err = d.fetchYeguoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	default:
		if isDuanjuProviderSource(source) {
			var categories []nativeCategory
			categories, err = d.fetchDuanjuCategories(ctx, source)
			if err == nil {
				all = append(all, categories...)
			}
			break
		}
		return nil, errors.New("请选择有效站源")
	}
	if err != nil {
		return nil, err
	}
	if len(all) == 1 {
		return nil, errors.New("站源暂未返回内容分类，请稍后重试")
	}
	engine.mu.Lock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[source] = all
	engine.writeCatalogDiskLocked()
	engine.mu.Unlock()
	return all, nil
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func (d *Downloader) fetchHuangguoAICatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	categories := nativeAICategories
	if category != "" {
		for _, entry := range categories {
			if entry.ID == category {
				categories = []nativeCategory{entry}
				break
			}
		}
	}
	type categoryResult struct {
		items []Drama
		err   error
	}
	results := make([]categoryResult, len(categories))
	slots := make(chan struct{}, 2)
	var group sync.WaitGroup
	for index, entry := range categories {
		group.Add(1)
		go func(index int, entry nativeCategory) {
			defer group.Done()
			select {
			case slots <- struct{}{}:
				defer func() { <-slots }()
			case <-ctx.Done():
				results[index].err = ctx.Err()
				return
			}
			baseURL := strings.TrimRight(d.providerBaseURL(sourceHuangguoAI), "/")
			var address string
			if page <= 1 {
				address = baseURL + "/" + entry.ID + "/"
			} else {
				address = fmt.Sprintf("%s/%s/%d/", baseURL, entry.ID, page)
			}
			body, err := d.fetchProviderText(ctx, address, d.providerBaseURL(sourceHuangguoAI)+"/")
			if err == nil {
				results[index].items = parseHuangguoAIDramaCards(body, address, entry.Name)
			}
			if err != nil {
				results[index].err = fmt.Errorf("%s: %w", entry.Name, err)
			}
		}(index, entry)
	}
	group.Wait()
	var items []Drama
	var failures []error
	more := false
	for _, result := range results {
		items = append(items, result.items...)
		more = more || len(result.items) >= 30 || result.err != nil
		if result.err != nil {
			failures = append(failures, result.err)
		}
	}
	return items, more, errors.Join(failures...)
}
