package core

import (
	"context"
	"fmt"
	"time"
)

// 远端主页板块：App 不再内置首页板块清单，整份结构与顺序都来自站点
// /v1/feed/home（见 provider_dongpiandi_home.go 的真值注释）。

// nativeHomeSection 是给 UI 的一个首页区块：标题/副标题/顺序来自站点，
// items 是该区块的预览卡片（站点每块给 12 条）。
type nativeHomeSection struct {
	ID       string `json:"id"`
	Title    string `json:"title"`
	Subtitle string `json:"subtitle"`
	Type     string `json:"type"`
	Role     string `json:"role"`
	Priority int    `json:"priority"`
	Count    int    `json:"count"`
	// MoreLabel 是站点的「查看更多 / 查看完整榜单」文案；hasMore 表示该
	// 区块确实给了 browse 请求描述，可以点进去看完整榜单。
	MoreLabel string        `json:"moreLabel,omitempty"`
	HasMore   bool          `json:"hasMore"`
	Items     []nativeDrama `json:"items"`
	ExpiresAt int64         `json:"expiresAt,omitempty"`
}

func (engine *nativeEngine) nativeHomeFeed(ctx context.Context, input nativeInput) (any, error) {
	if canonicalProviderSource(input.Source) != sourceDongpiandi {
		return nil, fmt.Errorf("当前站源不支持主页板块")
	}
	sections, err := cachedDongpiandiHome(ctx, input.Force)
	if err != nil {
		return nil, err
	}
	out := make([]nativeHomeSection, 0, len(sections))
	for _, section := range sections {
		items := make([]nativeDrama, 0, len(section.Cards))
		for _, card := range section.Cards {
			drama := nativeNormalize(dongpiandiDramaFromCard(card))
			if drama.Title == "" {
				continue
			}
			items = append(items, drama)
		}
		if len(items) == 0 {
			continue
		}
		out = append(out, nativeHomeSection{
			ID:        section.ID,
			Title:     section.Title,
			Subtitle:  section.Subtitle,
			Type:      section.Type,
			Role:      section.Role,
			Priority:  section.Priority,
			Count:     len(items),
			MoreLabel: section.Browse.Label,
			HasMore:   len(section.Browse.Params) > 0 || section.Browse.Path != "",
			Items:     items,
		})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("没有可用的板块")
	}
	return map[string]any{"items": out, "expiresAt": dongpiandiHomeExpiryUnix()}, nil
}

// nativeHomeSection 拉某个板块的完整榜单（点击「查看更多」），
// input.Category 是板块 id，input.Page 从 1 开始。
func (engine *nativeEngine) nativeHomeSection(ctx context.Context, input nativeInput) (any, error) {
	if canonicalProviderSource(input.Source) != sourceDongpiandi {
		return nil, fmt.Errorf("当前站源不支持主页板块")
	}
	page := max(1, input.Page)
	d := engine.downloader
	if d == nil {
		return nil, fmt.Errorf("核心未就绪")
	}
	items, more, err := d.fetchDongpiandiSectionPage(ctx, input.Category, page)
	if err != nil {
		return nil, err
	}
	out := make([]nativeDrama, 0, len(items))
	for _, drama := range items {
		normalized := nativeNormalize(drama)
		if normalized.Title == "" {
			continue
		}
		out = append(out, normalized)
	}
	return map[string]any{"items": out, "hasMore": more, "page": page}, nil
}

func dongpiandiHomeExpiryUnix() int64 {
	dongpiandiHomeCache.mu.Lock()
	defer dongpiandiHomeCache.mu.Unlock()
	if dongpiandiHomeCache.until.IsZero() {
		return 0
	}
	return dongpiandiHomeCache.until.Add(1 * time.Minute).UnixMilli()
}
