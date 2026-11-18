package core

import (
	"context"
	"encoding/json"
	"errors"
	"time"
)

type nativeRecommendationState struct {
	Query   hongguoRecommendationQuery `json:"query"`
	// Cursor 是模块/通用站源的推荐游标（红果专用字段见 Query）。模块提供
	// 推荐能力时用游标续页，不再依赖红果的 offset/session 体系。
	Cursor  json.RawMessage `json:"cursor,omitempty"`
	Page    int             `json:"page"`
	HasMore bool            `json:"hasMore"`
}

func nativeRecommendationKey(source, genre string) string {
	return source + "|recommendation:" + genre
}

func (engine *nativeEngine) cachedRecommendations(source, genre string) (nativeCatalogResult, error) {
	if err := (hongguoRecommendationQuery{Genre: genre}).validate(); err != nil {
		return nativeCatalogResult{}, err
	}
	result := engine.nativeCached(nativeRecommendationKey(source, genre))
	engine.mu.Lock()
	_, found := engine.recommendations[source+"|"+genre]
	engine.mu.Unlock()
	if !found && len(result.Items) > 0 {
		result.Fresh, result.HasMore = false, false
		result.Warning = joinNativeWarnings(result.Warning, "推荐位置已失效，请刷新推荐")
	}
	return result, nil
}

// recommendationPage 是归一后的推荐页：红果专用字段与模块游标共用。
type recommendationPage struct {
	Dramas     []Drama
	NextOffset int
	SessionID  string
	CellID     string
	ShowType   string
	HasMore    bool
	Cursor     json.RawMessage
}

// fetchRecommendations 取一页推荐：模块站源优先由模块提供（用游标续页），
// 其余走内置实现（红果）。
func (engine *nativeEngine) fetchRecommendations(ctx context.Context, source string, state nativeRecommendationState) (recommendationPage, error) {
	if recommender, ok := moduleCapabilityProvider(source).(moduleRecommender); ok {
		page, err := recommender.ModuleRecommendations(ctx, engine.downloader.host(), state.Query.Genre, state.Cursor, state.Query.Seen)
		if !errors.Is(err, errModuleCapabilityUnsupported) {
			return recommendationPage{
				Dramas: page.Dramas, HasMore: page.HasMore, Cursor: page.Cursor,
				SessionID: state.Query.SessionID,
			}, err
		}
	}
	page, err := engine.downloader.fetchHongguoRecommendations(ctx, state.Query)
	if err != nil {
		return recommendationPage{}, err
	}
	return recommendationPage{
		Dramas: page.Dramas, NextOffset: page.NextOffset, SessionID: page.SessionID,
		CellID: page.CellID, ShowType: page.ShowType, HasMore: page.HasMore,
	}, nil
}

func (engine *nativeEngine) nativeRecommendations(ctx context.Context, input nativeInput) (nativeCatalogResult, error) {
	engine.ensureLoaded()
	genre := input.Category
	source := firstNonEmpty(input.Source, sourceHongguo)
	if err := (hongguoRecommendationQuery{Genre: genre}).validate(); err != nil {
		return nativeCatalogResult{}, err
	}
	unlock, err := engine.lockSourceCatalog(ctx, source)
	if err != nil {
		return nativeCatalogResult{}, err
	}
	defer unlock()
	if retried, err := engine.retryCatalogSave(); retried {
		cached, _ := engine.cachedRecommendations(source, genre)
		if err != nil || len(cached.Items) > 0 {
			return cached, nil
		}
	}
	cached, _ := engine.cachedRecommendations(source, genre)
	stateKey := source + "|" + genre
	engine.mu.Lock()
	state, found := engine.recommendations[stateKey]
	engine.mu.Unlock()
	if !input.Force && found && len(cached.Items) > 0 && (input.Command != "more" || !state.HasMore) {
		return cached, nil
	}
	if !input.Force && !found && len(cached.Items) > 0 {
		return cached, nil
	}
	if input.Force || !found {
		state = nativeRecommendationState{Query: hongguoRecommendationQuery{Genre: genre}, HasMore: true}
	}
	page, err := engine.fetchRecommendations(ctx, source, state)
	if err != nil {
		if len(cached.Items) == 0 || errors.Is(err, context.Canceled) {
			return nativeCatalogResult{}, err
		}
		cached.Fresh = false
		cached.Warning = joinNativeWarnings(cached.Warning, publicError(err).Error())
		return cached, nil
	}
	if err := ctx.Err(); err != nil {
		return nativeCatalogResult{}, err
	}
	engine.mu.Lock()
	defer engine.mu.Unlock()
	if engine.recommendations == nil {
		engine.recommendations = map[string]nativeRecommendationState{}
	}
	key := nativeRecommendationKey(source, genre)
	previous := engine.catalogs[key]
	if input.Force {
		previous = nil
	}
	seen := make(map[string]bool, len(previous))
	for _, drama := range previous {
		seen[drama.ID] = true
	}
	fresh := make([]nativeDrama, 0, len(page.Dramas))
	known := make(map[string]nativeDrama, len(engine.catalogs[source]))
	for _, drama := range engine.catalogs[source] {
		known[drama.ID] = drama
	}
	for _, drama := range page.Dramas {
		item := nativeNormalize(drama)
		if old, exists := known[item.ID]; exists {
			item = mergeNativeDrama(old, item)
		}
		if !seen[item.ID] {
			seen[item.ID] = true
			fresh = append(fresh, item)
		}
	}
	if len(fresh) == 0 && page.HasMore {
		return nativeCatalogResult{}, errors.New("暂时没有新的推荐，已保留上次位置；可重试或刷新推荐")
	}
	items := mergeNativeCatalog(previous, fresh)
	identifiers := make([]string, 0, min(540, len(items)))
	for _, drama := range items[max(0, len(items)-540):] {
		identifiers = append(identifiers, drama.ID)
	}
	session := page.SessionID
	if session == "" {
		session = state.Query.SessionID
	}
	state.Query = hongguoRecommendationQuery{Genre: genre, Offset: page.NextOffset, SessionID: session, CellID: page.CellID, ShowType: page.ShowType, Seen: identifiers}
	state.Cursor = page.Cursor
	state.Page++
	state.HasMore = page.HasMore
	engine.recommendations[stateKey] = state
	engine.catalogs[key] = items
	engine.catalogs[source] = mergeNativeCatalog(engine.catalogs[source], fresh)
	if source == sourceHongguo {
		engine.hongguoCatalog = engine.downloader.hongguoCatalogSnapshot()
	}
	engine.catalogStates[key] = nativeCatalogState{UpdatedAt: time.Now(), Page: state.Page, HasMore: state.HasMore}
	result := nativeCatalogResult{Items: append([]nativeDrama{}, items...), Page: state.Page, HasMore: state.HasMore, Fresh: true}
	if err := engine.writeCatalogDiskLocked(); err != nil {
		result.Fresh, result.Warning, result.saveError = false, err.Error(), err
	}
	return result, nil
}
