package core

import (
	"context"
	"duanjuapp/native/provider"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

type nativeCategory = provider.CatalogCategory

// 黄果 AI 站点 2026-11 的 edge 接口按 slug 取分类，真网实测：
//
//	/api/home 的 cate_rec 只有「短剧」「漫剧」两类（数字 id 24/25）；
//	/api/videos/category/{slug} 仅 ai-duanju / ai-manju 稳定返回；
//	chigua 明确返回「分类不存在」，ai-huanlian / ai-mogai 常见 410。
//
// 名称与上游 a93d452 后的真值对齐（不带「成人」字样），也和 Dart
// categoryName() 归一化后的 chip 名一致，避免菜单名与卡片分类名错位。
var nativeAICategories = []nativeCategory{
	{ID: "ai-duanju", Name: "AI 短剧"},
	{ID: "ai-manju", Name: "AI 漫剧"},
	{ID: "ai-huanlian", Name: "AI 换脸"},
	{ID: "ai-mogai", Name: "AI 魔改"},
}

// normalizeNativeSort 归一化客户端排序枚举名（heat/views/date）。
// 仅白名单内的值参与缓存键与服务端请求，空串与其他值一律视为源站顺序。
func normalizeNativeSort(sort string) string {
	switch sort = strings.ToLower(strings.TrimSpace(sort)); sort {
	case "heat", "views", "date":
		return sort
	}
	return ""
}

func nativeCatalogKey(source, category, sort string) string {
	source = canonicalProviderSource(source)
	key := source
	if category = strings.TrimSpace(category); category != "" {
		key += "|" + category
	}
	if sort != "" {
		key += "|sort:" + sort
	}
	return key
}

// huangdouModuleCategoryPattern 对齐黄豆 H5 模块 validCategory 的复合分类 id：
// f|{cat_id}|{order}|{source}。模块自己会再校验一遍，这里挡住注入与超长值。
var huangdouModuleCategoryPattern = regexp.MustCompile(`^f\|[0-9]{1,10}\|[a-z:._-]{0,32}\|[a-z0-9:._-]{0,32}$`)

func validNativeCategory(source, category string) bool {
	if category == "" {
		return true
	}
	// 黄豆由 JS 模块接管时分类 id 是 f|... 复合格式，通用规则会把 | 判非法。
	// 仅对该模块接管的源放行，且用同规格正则约束；模块未接管仍走下面的通用校验。
	if source == sourceHuangdou && moduleDeclaresCapability(source, "catalog") {
		return category == "@new" || category == "@hot" || huangdouModuleCategoryPattern.MatchString(category)
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	switch source {
	case sourceHongguo:
		if hongguoTagPattern.MatchString(category) {
			return true
		}
		// 听书/小说播放链路不可用，校验直接拒绝（入口也已从分类栏剔除）。
		if hongguoAudioCategories[category] {
			return false
		}
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
	case sourceHeitao:
		return validHeitaoCategory(category)
	case sourceHanxiaoquan:
		// 分类栏给出数字 id（1=最新韩剧/2=韩国电影/3=韩国综艺/4=韩国动漫），
		// 必须与 fetchHanxiaoquanCategories 的返回值一致。
		return category == "all" || validHeitaoCategory(category)
	case sourceJinguoduanju:
		return validJinguoDuanjuCategory(category)
	case sourceBeabox:
		return validBeaboxCategory(category)
	}
	if isDuanjuProviderSource(source) {
		return validDuanjuCategory(source, category)
	}
	return false
}

func (engine *nativeEngine) nativeCategories(ctx context.Context, source string, force bool) ([]nativeCategory, error) {
	engine.ensureLoaded()
	source = canonicalProviderSource(source)
	all := []nativeCategory{{Name: "全部"}}
	switch source {
	case sourceHongguo:
		// 先看缓存：红果分类要初始化 JS 运行时，重复取会明显变慢。
		engine.mu.Lock()
		cachedHongguo := append([]nativeCategory{}, engine.categoryOptions[source]...)
		engine.mu.Unlock()
		if len(cachedHongguo) > 1 && !force {
			return cachedHongguo, nil
		}
		// 红果内嵌 JS 模块优先提供分类；失败回落静态 hongguoAppGenres。
		// 听书/小说（listen/novel）播放链路不可用，从分类栏剔除。
		var hongguoCats []nativeCategory
		if module, jsErr := engine.downloader.hongguoJS(); jsErr == nil {
			if cats, jsErr := module.categories(); jsErr == nil && len(cats) > 0 {
				hongguoCats = []nativeCategory{{Name: "全部"}}
				for _, cat := range cats {
					if hongguoAudioCategories[cat.ID] {
						continue
					}
					hongguoCats = append(hongguoCats, nativeCategory{ID: cat.ID, Name: cat.Name})
				}
			}
		}
		if len(hongguoCats) == 0 {
			for _, genre := range hongguoAppGenres {
				hongguoCats = append(hongguoCats, nativeCategory{ID: genre.key, Name: genre.name})
			}
			hongguoCats = engine.hongguoCategories(ctx, append([]nativeCategory{{Name: "全部"}}, hongguoCats...), force)
		}
		engine.mu.Lock()
		if engine.categoryOptions == nil {
			engine.categoryOptions = map[string][]nativeCategory{}
		}
		engine.categoryOptions[source] = hongguoCats
		engine.writeCatalogDiskLocked()
		engine.mu.Unlock()
		return hongguoCats, nil
	case sourceHuangguoAI:
		return append(all, nativeAICategories...), nil
	case sourceHuangdou:
		// 黄豆由 JS 模块接管后走通用 duanju 分类路径拿站点真实分类
		// （最新/热门/黄豆原创/UP原创）；模块未接管时保持旧的静态「全部」。
		if !moduleDeclaresCapability(source, "catalog") {
			return all, nil
		}
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
	case sourceHeitao:
		var categories []nativeCategory
		categories, err = d.fetchHeitaoCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceHanxiaoquan:
		all = append(all, d.fetchHanxiaoquanCategories()...)
	case sourceJinguoduanju:
		var categories []nativeCategory
		categories, err = d.fetchJinguoDuanjuCategories(ctx)
		if err == nil {
			all = append(all, categories...)
		}
	case sourceBeabox:
		all = append(all, d.fetchBeaboxCategories()...)
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

// hongguoCategories 在内置题材（全部 + hongguoAppGenres）基础上叠加站点真实
// 题材标签（tag:cate_*）。拉取失败时退回已缓存或纯内置分类，不影响首页加载。
func (engine *nativeEngine) hongguoCategories(ctx context.Context, genres []nativeCategory, force bool) []nativeCategory {
	engine.mu.Lock()
	cached := append([]nativeCategory{}, engine.categoryOptions[sourceHongguo]...)
	engine.mu.Unlock()
	if len(cached) > len(genres) && !force {
		return cached
	}
	tags, err := engine.downloader.fetchHongguoTagCategories(ctx)
	if err != nil {
		if len(cached) > len(genres) {
			return cached
		}
		return genres
	}
	all := append(append([]nativeCategory{}, genres...), tags...)
	engine.mu.Lock()
	if engine.categoryOptions == nil {
		engine.categoryOptions = map[string][]nativeCategory{}
	}
	engine.categoryOptions[sourceHongguo] = all
	engine.writeCatalogDiskLocked()
	engine.mu.Unlock()
	return all
}

var categoryAnchorPattern = regexp.MustCompile(`(?is)<a\b([^>]*)>(.*?)</a>`)
var categoryTextPattern = regexp.MustCompile(`(?s)<[^>]*>`)

func (d *Downloader) fetchHuangguoAICatalogPage(ctx context.Context, page int, category string) ([]Drama, bool, error) {
	// 只请求用户点选的那一个分类。旧实现在 category 未命中写死表时回退成
	// 「并发请求全部分类」，于是点「AI 短剧」会拿到别类混合内容；同时把
	// 站点已下线的 chigua 也一起请求，一次失败就 errors.Join 让整个目录
	// 报错。映射关系以站点 slug 为准，不再靠本地表猜。
	categories := nativeAICategories
	if category != "" {
		name := ""
		for _, entry := range nativeAICategories {
			if entry.ID == category {
				name = entry.Name
				break
			}
		}
		if name == "" {
			name = provider.SanitizeText(category)
		}
		categories = []nativeCategory{{ID: category, Name: name}}
	}
	type categoryResult struct {
		items []Drama
		more  bool
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
			path := fmt.Sprintf("/api/videos/category/%s?sort=hot&page=%d&size=24", url.PathEscape(entry.ID), page)
			var body json.RawMessage
			err := d.huangguoAIAPI(ctx, path, &body)
			if err == nil {
				results[index].items = parseHuangguoAIJSONCards(body, d.providerBaseURL(sourceHuangguoAI)+"/", entry.Name)
				var envelope struct {
					Pagination struct {
						Pages int `json:"pages"`
					} `json:"pagination"`
				}
				if json.Unmarshal(body, &envelope) == nil {
					results[index].more = page < envelope.Pagination.Pages
				} else {
					results[index].more = len(results[index].items) >= 24
				}
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
	succeeded := false
	for _, result := range results {
		items = append(items, result.items...)
		if result.err != nil {
			failures = append(failures, result.err)
			// 失败分类不能撑起 hasMore：否则一个 410/下线分类会让上拉
			// 永远重发同一页，表现为「循环重复」。
			continue
		}
		succeeded = true
		more = more || result.more
	}
	if !succeeded {
		return nil, false, errors.Join(failures...)
	}
	return items, more, nil
}
