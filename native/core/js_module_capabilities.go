package core

// 站源模块的可选能力（上游 module_capabilities.go 的对齐实现）。
//
// 规则：模块导出了对应函数即由模块提供；没导出则返回 errModuleCapabilityUnsupported，
// 核心据此继续走内置实现。这样内置红果的推荐、弹幕、封面与元数据在被模块
// 接管后也不会丢功能：模块不提供的那部分仍由内置实现兜底。
//
// 能力接口放在 core 包内（不污染 provider 包的公共接口）：模块 Provider 实现在
// core，核心调用点也在 core，类型断言走私有接口即可。

import (
	"context"
	"encoding/json"
	"errors"
	"net/url"
	"strings"

	"duanjuapp/native/provider"
)

// errModuleCapabilityUnsupported 表示模块没有提供该能力。
var errModuleCapabilityUnsupported = errors.New("模块未提供该能力")

// moduleSuggester 搜索联想。
type moduleSuggester interface {
	ModuleSuggestions(ctx context.Context, host provider.Host, query string) ([]string, error)
}

// moduleDirectSuggester 带直达播放目标的搜索建议（真果·鉴专属 suggest action）。
type moduleDirectSuggester interface {
	ModuleDirectSuggestions(ctx context.Context, host provider.Host, query string) ([]nativeSuggestion, error)
}

// moduleRoutesProvider 播放线路面板：模块按播放任务给出完整线路表。
type moduleRoutesProvider interface {
	ModuleRoutes(ctx context.Context, host provider.Host, task Task) ([]providerMedia, error)
}

// moduleHomeProvider 远端首页板块与追剧周表：返回已按 Dart 契约组装好的 JSON，
// Go 侧原样透传，避免逐字段对齐 nativeDrama 的漂移风险。
type moduleHomeProvider interface {
	ModuleHomeFeed(ctx context.Context, host provider.Host, force bool) (json.RawMessage, error)
	ModuleHomeSection(ctx context.Context, host provider.Host, sectionID string, page int) (json.RawMessage, error)
	ModuleHomeCalendar(ctx context.Context, host provider.Host, force bool) (json.RawMessage, error)
}

// moduleSkipPresetProvider 社区跳过片头片尾预设（真果·鉴）。
type moduleSkipPresetProvider interface {
	ModuleSkipPreset(ctx context.Context, host provider.Host, task Task) (introSec, outroSec int, ok bool)
}

// moduleDanmakuProvider 弹幕：先取弹幕标识（系列/单集），再取弹幕内容。
type moduleDanmakuProvider interface {
	ModuleDanmakuIDs(ctx context.Context, host provider.Host, task Task) (string, string, bool)
	ModuleDanmaku(ctx context.Context, host provider.Host, series, video string, startMS, durationMS int64) (hongguoDanmakuPage, error)
}

// moduleCoverProvider 封面地址（模块可按剧集给出更准的封面）。
type moduleCoverProvider interface {
	ModuleCoverAddress(ctx context.Context, host provider.Host, drama provider.Drama, sourceID string) (string, error)
}

// moduleMetadataProvider 补充元数据（上线日期、评分、VIP 标记等）。
type moduleMetadataProvider interface {
	ModuleNeedsExtraMetadata(ctx context.Context, host provider.Host, drama provider.Drama) (bool, error)
	ModuleExtraMetadata(ctx context.Context, host provider.Host, drama provider.Drama, sourceID string) (provider.Drama, error)
}

// moduleRankingProvider 榜单条目。
type moduleRankingProvider interface {
	ModuleRankingPage(ctx context.Context, host provider.Host, board string, page int) ([]Drama, error)
}

// moduleMediaAuthorizer 播放凭证（部分站源要给媒体请求附加自定义头）。
type moduleMediaAuthorizer interface {
	AuthorizesMedia(address *url.URL) bool
	ModuleMediaAuthorization(ctx context.Context, host provider.Host, address, referer string) (string, string, error)
	RejectMediaAuthorization(address *url.URL, value string)
}

// moduleRecommender 推荐位：按题材拉一页推荐，用游标续页。
type moduleRecommender interface {
	ModuleRecommendations(ctx context.Context, host provider.Host, genre string, cursor json.RawMessage, seen []string) (moduleRecommendationPage, error)
}

// moduleRecommendationPage 是模块返回的推荐页。
type moduleRecommendationPage struct {
	Dramas  []Drama         `json:"dramas"`
	Cursor  json.RawMessage `json:"cursor"`
	HasMore bool            `json:"hasMore"`
}

// SearchPageWithWarning 带警告的搜索：模块导出 searchWithWarning 时生效。
// 返回的 warning 会透到搜索结果的 Warning 字段，让用户看到「部分结果失败」。
func (p *jsModuleProvider) SearchPageWithWarning(ctx context.Context, host provider.Host, query string, page int) ([]provider.Drama, bool, string, error) {
	if !p.runtime.hasExport("searchWithWarning") {
		return nil, false, "", errModuleCapabilityUnsupported
	}
	var result struct {
		Items    []provider.Drama `json:"items"`
		HasMore  bool             `json:"hasMore"`
		Warning  string           `json:"warning"`
		ErrorMsg string           `json:"error"`
	}
	if err := p.runtime.call(ctx, host, "searchWithWarning", &result, page, query); err != nil {
		return nil, false, "", err
	}
	if strings.TrimSpace(result.ErrorMsg) != "" {
		return nil, false, "", errors.New(strings.TrimSpace(result.ErrorMsg))
	}
	return result.Items, result.HasMore, strings.TrimSpace(result.Warning), nil
}

// ModuleSuggestions 搜索联想：模块导出 suggestions 时生效。
func (p *jsModuleProvider) ModuleSuggestions(ctx context.Context, host provider.Host, query string) ([]string, error) {
	if !p.runtime.hasExport("suggestions") {
		return nil, errModuleCapabilityUnsupported
	}
	var names []string
	if err := p.runtime.call(ctx, host, "suggestions", &names, query); err != nil {
		return nil, err
	}
	return names, nil
}

// ModuleDirectSuggestions 带直达目标的建议：模块导出 suggestDirect 时生效。
func (p *jsModuleProvider) ModuleDirectSuggestions(ctx context.Context, host provider.Host, query string) ([]nativeSuggestion, error) {
	if !p.runtime.hasExport("suggestDirect") {
		return nil, errModuleCapabilityUnsupported
	}
	var items []nativeSuggestion
	if err := p.runtime.call(ctx, host, "suggestDirect", &items, query); err != nil {
		return nil, err
	}
	return items, nil
}

// ModuleSkipPreset 跳过预设：模块导出 skipPreset 时生效。
func (p *jsModuleProvider) ModuleSkipPreset(ctx context.Context, host provider.Host, task Task) (int, int, bool) {
	if !p.runtime.hasExport("skipPreset") {
		return 0, 0, false
	}
	var preset struct {
		IntroSec  float64 `json:"introSec"`
		OutroSec  float64 `json:"outroSec"`
	}
	if err := p.runtime.call(ctx, host, "skipPreset", &preset, task); err != nil {
		return 0, 0, false
	}
	if preset.IntroSec <= 0 && preset.OutroSec <= 0 {
		return 0, 0, false
	}
	return int(preset.IntroSec + 0.5), int(preset.OutroSec + 0.5), true
}

// ModuleHomeFeed 首页板块：模块导出 homeFeed 时生效。
func (p *jsModuleProvider) ModuleHomeFeed(ctx context.Context, host provider.Host, force bool) (json.RawMessage, error) {
	if !p.runtime.hasExport("homeFeed") {
		return nil, errModuleCapabilityUnsupported
	}
	var raw json.RawMessage
	if err := p.runtime.call(ctx, host, "homeFeed", &raw, force); err != nil {
		return nil, err
	}
	return raw, nil
}

// ModuleHomeSection 板块翻页：模块导出 homeSection 时生效。
func (p *jsModuleProvider) ModuleHomeSection(ctx context.Context, host provider.Host, sectionID string, page int) (json.RawMessage, error) {
	if !p.runtime.hasExport("homeSection") {
		return nil, errModuleCapabilityUnsupported
	}
	var raw json.RawMessage
	if err := p.runtime.call(ctx, host, "homeSection", &raw, sectionID, page); err != nil {
		return nil, err
	}
	return raw, nil
}

// ModuleHomeCalendar 追剧周表：模块导出 homeCalendar 时生效。
func (p *jsModuleProvider) ModuleHomeCalendar(ctx context.Context, host provider.Host, force bool) (json.RawMessage, error) {
	if !p.runtime.hasExport("homeCalendar") {
		return nil, errModuleCapabilityUnsupported
	}
	var raw json.RawMessage
	if err := p.runtime.call(ctx, host, "homeCalendar", &raw, force); err != nil {
		return nil, err
	}
	return raw, nil
}

// ModuleRoutes 播放线路：模块导出 routes 时生效。
func (p *jsModuleProvider) ModuleRoutes(ctx context.Context, host provider.Host, task Task) ([]providerMedia, error) {
	if !p.runtime.hasExport("routes") {
		return nil, errModuleCapabilityUnsupported
	}
	var lines []providerMedia
	if err := p.runtime.call(ctx, host, "routes", &lines, task); err != nil {
		return nil, err
	}
	// 只保留 http(s) 直链，避免模块返回票据/网页线污染线路面板。
	kept := make([]providerMedia, 0, len(lines))
	for _, line := range lines {
		if strings.HasPrefix(line.URL, "http://") || strings.HasPrefix(line.URL, "https://") {
			kept = append(kept, line)
		}
	}
	return kept, nil
}

// ModuleDanmakuIDs 取弹幕标识：模块导出 danmakuIds 时生效。
func (p *jsModuleProvider) ModuleDanmakuIDs(ctx context.Context, host provider.Host, task Task) (string, string, bool) {
	if !p.runtime.hasExport("danmakuIds") {
		return "", "", false
	}
	var ids struct {
		Series string `json:"series"`
		Video  string `json:"video"`
	}
	if err := p.runtime.call(ctx, host, "danmakuIds", &ids, task); err != nil {
		return "", "", false
	}
	if ids.Series == "" || ids.Video == "" {
		return "", "", false
	}
	return ids.Series, ids.Video, true
}

// ModuleDanmaku 取弹幕：模块导出 danmaku 时生效。
func (p *jsModuleProvider) ModuleDanmaku(ctx context.Context, host provider.Host, series, video string, startMS, durationMS int64) (hongguoDanmakuPage, error) {
	if !p.runtime.hasExport("danmaku") {
		return hongguoDanmakuPage{}, errModuleCapabilityUnsupported
	}
	var page hongguoDanmakuPage
	if err := p.runtime.call(ctx, host, "danmaku", &page, series, video, startMS, durationMS); err != nil {
		return hongguoDanmakuPage{}, err
	}
	return page, nil
}

// ModuleCoverAddress 取封面地址：模块导出 coverAddress 时生效。
func (p *jsModuleProvider) ModuleCoverAddress(ctx context.Context, host provider.Host, drama provider.Drama, sourceID string) (string, error) {
	if !p.runtime.hasExport("coverAddress") {
		return "", errModuleCapabilityUnsupported
	}
	var address string
	if err := p.runtime.call(ctx, host, "coverAddress", &address, drama, sourceID); err != nil {
		return "", err
	}
	return strings.TrimSpace(address), nil
}

// ModuleNeedsExtraMetadata 是否需要补充元数据：模块导出 needsExtraMetadata 时生效。
func (p *jsModuleProvider) ModuleNeedsExtraMetadata(ctx context.Context, host provider.Host, drama provider.Drama) (bool, error) {
	if !p.runtime.hasExport("needsExtraMetadata") {
		return false, errModuleCapabilityUnsupported
	}
	var needed bool
	if err := p.runtime.call(ctx, host, "needsExtraMetadata", &needed, drama); err != nil {
		return false, err
	}
	return needed, nil
}

// ModuleExtraMetadata 补充元数据：模块导出 extraMetadata 时生效。
func (p *jsModuleProvider) ModuleExtraMetadata(ctx context.Context, host provider.Host, drama provider.Drama, sourceID string) (provider.Drama, error) {
	if !p.runtime.hasExport("extraMetadata") {
		return drama, errModuleCapabilityUnsupported
	}
	var patch provider.Drama
	if err := p.runtime.call(ctx, host, "extraMetadata", &patch, drama, sourceID); err != nil {
		return drama, err
	}
	if patch.ID == "" {
		return drama, nil
	}
	return patch, nil
}

// providerDramaFromNative 把核心归一化的剧集转成模块生态通用的 Drama 形状。
func providerDramaFromNative(drama nativeDrama) provider.Drama {
	return provider.Drama{
		ID:            drama.ID,
		Source:        drama.Source,
		SourceID:      drama.SourceID,
		Title:         drama.Title,
		Name:          drama.Title,
		Desc:          drama.Description,
		Intro:         drama.Description,
		Cover:         drama.Cover,
		CoverURL:      drama.Cover,
		Episodes:      drama.Episodes,
		Category:      drama.Category,
		CategoryName:  drama.Category,
		VIP:           drama.VIP,
		Heat:          drama.Heat,
		Views:         drama.Views,
		OnlineDate:    drama.OnlineDate,
		Area:          drama.Area,
		Year:          drama.Year,
		Duration:      drama.Duration,
		Score:         drama.Score,
		Tags:          drama.Tags,
		Actors:        drama.Actors,
		ReleaseStatus: drama.ReleaseStatus,
		ContentKind:   drama.ContentKind,
	}
}

// ModuleRankingPage 取榜单条目：模块导出 rankingPage 时生效。
func (p *jsModuleProvider) ModuleRankingPage(ctx context.Context, host provider.Host, board string, page int) ([]Drama, error) {
	if !p.runtime.hasExport("rankingPage") {
		return nil, errModuleCapabilityUnsupported
	}
	var items []Drama
	if err := p.runtime.call(ctx, host, "rankingPage", &items, board, page); err != nil {
		return nil, err
	}
	return items, nil
}

// ModuleRecommendations 取一页推荐：模块导出 recommendations 时生效。
func (p *jsModuleProvider) ModuleRecommendations(ctx context.Context, host provider.Host, genre string, cursor json.RawMessage, seen []string) (moduleRecommendationPage, error) {
	if !p.runtime.hasExport("recommendations") {
		return moduleRecommendationPage{}, errModuleCapabilityUnsupported
	}
	var page moduleRecommendationPage
	if err := p.runtime.call(ctx, host, "recommendations", &page, genre, cursor, seen); err != nil {
		return moduleRecommendationPage{}, err
	}
	return page, nil
}

// ModuleMediaAuthorization 取播放凭证：模块导出 mediaAuthorization 时生效。
func (p *jsModuleProvider) ModuleMediaAuthorization(ctx context.Context, host provider.Host, address, referer string) (string, string, error) {
	if !p.runtime.hasExport("mediaAuthorization") {
		return "", "", errModuleCapabilityUnsupported
	}
	var result struct {
		Header string `json:"header"`
		Value  string `json:"value"`
	}
	if err := p.runtime.call(ctx, host, "mediaAuthorization", &result, address, referer); err != nil {
		return "", "", err
	}
	header := strings.TrimSpace(result.Header)
	value := strings.TrimSpace(result.Value)
	if header == "" || strings.ContainsAny(header+value, "\r\n") {
		return "", "", errors.New("模块返回的播放凭证无效")
	}
	return header, value, nil
}

// AuthorizesMedia 报告该模块是否要为这个媒体地址签发凭证：主机属于本模块，
// 且路径命中 mediaAuthPaths 前缀。没声明路径时即使导出 mediaAuthorization 也
// 不接管，避免误伤 CDN 上其他来源的媒体。
func (p *jsModuleProvider) AuthorizesMedia(address *url.URL) bool {
	if p == nil || address == nil || len(p.manifest.MediaAuthPaths) == 0 {
		return false
	}
	if !p.runtime.hasExport("mediaAuthorization") {
		return false
	}
	host := strings.ToLower(address.Hostname())
	owned := false
	for _, declared := range p.manifest.Hosts {
		declared = strings.ToLower(strings.TrimSpace(declared))
		if declared == host {
			owned = true
			break
		}
		if suffix, ok := strings.CutPrefix(declared, "."); ok && strings.HasSuffix(host, suffix) {
			owned = true
			break
		}
	}
	if !owned {
		return false
	}
	for _, prefix := range p.manifest.MediaAuthPaths {
		if prefix != "" && strings.HasPrefix(address.Path, prefix) {
			return true
		}
	}
	return false
}

// RejectMediaAuthorization 在凭证被源站拒绝（401/403）时通知模块作废旧值，
// 下一次请求会重新签发。模块没导出回调时静默忽略。
func (p *jsModuleProvider) RejectMediaAuthorization(address *url.URL, value string) {
	if p == nil || p.runtime == nil || !p.runtime.hasExport("rejectMediaAuthorization") {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), jsModuleFetchTimeout)
	defer cancel()
	var ignored any
	_ = p.runtime.call(ctx, nil, "rejectMediaAuthorization", &ignored, address.String(), value)
}

// capabilityExports 把能力名映射到判定所需的导出函数（上游 ProvidesCapability
// 的轻量版）。一个能力只要声明或导出了任一函数就算提供：内置模块清单常只写
// catalog/detail/search，若严格按声明门控会误伤它们实际实现的能力。
func capabilityExports(name string) []string {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "suggestions":
		return []string{"suggestions"}
	case "suggest":
		return []string{"suggestDirect"}
	case "routes":
		return []string{"routes"}
	case "homefeed":
		return []string{"homeFeed", "homeSection"}
	case "calendar":
		return []string{"homeCalendar"}
	case "skippreset":
		return []string{"skipPreset"}
	case "recommendations":
		return []string{"recommendations"}
	case "danmaku":
		return []string{"danmakuIds", "danmaku"}
	case "cover":
		return []string{"coverAddress"}
	case "metadata":
		return []string{"needsExtraMetadata", "extraMetadata"}
	case "rankings":
		return []string{"rankingPage"}
	case "mediaauth":
		return []string{"mediaAuthorization"}
	case "search":
		return []string{"searchWithWarning"}
	case "catalogstate":
		return []string{"catalogState", "restoreCatalogState"}
	default:
		return nil
	}
}

// ProvidesCapability 报告模块是否提供某项可选能力：清单声明或实际导出任一命中
// 即为提供。对齐上游在 provider 层暴露能力查询的思路，但保留「导出即能力」的
// 向后兼容，老模块无需改清单也能继续工作。
func (p *jsModuleProvider) ProvidesCapability(name string) bool {
	if p == nil || p.runtime == nil {
		return false
	}
	if p.manifest.capability(name) {
		return true
	}
	for _, export := range capabilityExports(name) {
		if p.runtime.hasExport(export) {
			return true
		}
	}
	return false
}

// moduleCapabilityProvider 返回该站源的模块能力实现（不是模块站源则 nil）。
// 注册时按导出组合装配了包装类型（取流/服务端排序），这里必须解包回基类，
// 否则带 resolveMedia 的模块会丢失弹幕/封面/推荐等可选能力。
func moduleCapabilityProvider(source string) any {
	entry, found := provider.Get(canonicalProviderSource(source))
	if !found {
		return nil
	}
	switch p := entry.(type) {
	case *jsModuleProvider:
		return p
	case *jsModuleMediaProvider:
		return p.jsModuleProvider
	case *jsModuleSortedProvider:
		return p.jsModuleProvider
	case *jsModuleMediaSortedProvider:
		return p.jsModuleProvider
	default:
		return nil
	}
}

// moduleDeclaresCapability 报告 source 对应的在线模块是否在 manifest 里**显式声明**了
// 某项主能力（catalog/detail/search/media）。这是主链路「模块优先、内置兜底」的门控：
// 只有清单明确声明的模块才接管 catalog/detail，其余（含从上游抄来但未验证的模块）
// 继续走 Go 直连，避免误伤。可选能力（弹幕/封面/榜单等）仍用 ProvidesCapability
// 的「导出即能力」语义；主能力用显式声明更保守。
func moduleDeclaresCapability(source, capability string) bool {
	providerModule := moduleCapabilityProvider(source)
	if providerModule == nil {
		return false
	}
	var manifest JSModuleManifest
	switch p := providerModule.(type) {
	case *jsModuleProvider:
		manifest = p.manifest
	default:
		return false
	}
	return manifest.capability(capability)
}
