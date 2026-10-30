package core

import (
	"fmt"
	"regexp"
	"strings"

	"duanjuapp/native/provider"
	"duanjuapp/native/sources/maccmsapi"
)

// 自定义 maccms 点播源（用户在本机添加，经 config.source 的 customSources
// 段下发动态注册）。Go 侧是权威校验：ID 必须是 custom- 前缀（由 Dart 依
// URL 摘要生成，天然不与内置源冲突，仍防御性复检）、名称非空、地址为合法
// 根地址、分类限定三枚举、typeID 为可选安全短串、总数上限 16。任一条目
// 非法即整体拒绝（保持现状），与 sourceConfig 其它段的整段语义一致。
// 空列表合法，语义为清空全部自定义源。自定义源只存在于进程内，Dart 每次
// 启动都会重发全量，无需落盘。

const customSourceLimit = 16

var customSourceIDPattern = regexp.MustCompile(`^custom-[a-z0-9]{4,40}$`)

var customSourceTypeIDPattern = regexp.MustCompile(`^[0-9A-Za-z_-]{0,32}$`)

type customSourceSpec struct {
	id       string
	name     string
	base     string
	category provider.Category
	typeID   string
}

// applyCustomSources 校验并注册自定义源，返回生效 ID 列表（保持输入顺序）。
// 相对当前已注册的自定义源做差量：新增/变更 Register（同 ID 覆盖），
// 消失的 UnregisterCustom。
func applyCustomSources(list []any) ([]string, error) {
	if len(list) > customSourceLimit {
		return nil, fmt.Errorf("自定义源超过上限 %d", customSourceLimit)
	}
	specs := make([]customSourceSpec, 0, len(list))
	seen := map[string]bool{}
	for _, raw := range list {
		spec, ok := parseCustomSourceSpec(raw)
		if !ok {
			return nil, fmt.Errorf("自定义源条目非法")
		}
		if seen[spec.id] {
			return nil, fmt.Errorf("自定义源 ID 重复: %s", spec.id)
		}
		seen[spec.id] = true
		specs = append(specs, spec)
	}
	desired := make(map[string]customSourceSpec, len(specs))
	for _, spec := range specs {
		desired[spec.id] = spec
	}
	for _, id := range registeredCustomSourceIDs() {
		if _, keep := desired[id]; !keep {
			provider.UnregisterCustom(id)
		}
	}
	ids := make([]string, 0, len(specs))
	for _, spec := range specs {
		provider.Register(maccmsapi.New(spec.providerSpec(), spec.typeID))
		ids = append(ids, spec.id)
	}
	return ids, nil
}

// registeredCustomSourceIDs 列出当前已注册的自定义源 ID。
func registeredCustomSourceIDs() []string {
	var out []string
	for _, p := range provider.All() {
		if provider.IsCustomSourceID(p.Spec().ID) {
			out = append(out, p.Spec().ID)
		}
	}
	return out
}

// customSourceSpecToProviderSpec 把校验后的自定义源转成 maccms Spec：
// Kind 沿用内置 maccms 族；Family 走短剧族（isHuangguoProviderSource 等
// 门控按 Family 放行）；RequiresAllSources=false 免变体门控（单源变体
// 也可使用自定义源）。
func (spec customSourceSpec) providerSpec() provider.Spec {
	return provider.Spec{
		ID:                 spec.id,
		Name:               spec.name,
		Base:               spec.base,
		Kind:               "maccms",
		Category:           spec.category,
		Family:             provider.FamilyDuanju,
		Searcher:           true,
		Paged:              true,
		RequiresAllSources: false,
	}
}

// parseCustomSourceSpec 解析并校验单条自定义源。字段：
//
//	{"id": "custom-xxxx", "name": "我的源", "url": "https://host",
//	 "category": "shortDrama|video|adult", "typeId": "1"}
//
// category 可省略（默认 shortDrama）；typeId 可省略（拉源站分类）。
func parseCustomSourceSpec(raw any) (customSourceSpec, bool) {
	entry, ok := raw.(map[string]any)
	if !ok {
		return customSourceSpec{}, false
	}
	id, ok := entry["id"].(string)
	if !ok {
		return customSourceSpec{}, false
	}
	id = strings.ToLower(strings.TrimSpace(id))
	if !customSourceIDPattern.MatchString(id) {
		return customSourceSpec{}, false
	}
	// 防御性复检：即使 ID 模式匹配，也不允许覆盖非 custom- 前缀的内置源。
	if existing, found := provider.SpecOf(id); found && !provider.IsCustomSourceID(existing.ID) {
		return customSourceSpec{}, false
	}
	name, ok := entry["name"].(string)
	if !ok {
		return customSourceSpec{}, false
	}
	name = sanitizeCustomSourceName(name)
	if name == "" || len([]rune(name)) > 32 {
		return customSourceSpec{}, false
	}
	base, ok := entry["url"].(string)
	if !ok {
		return customSourceSpec{}, false
	}
	base = strings.TrimSuffix(strings.TrimSpace(base), "/")
	if !validSourceBaseURL(base) {
		return customSourceSpec{}, false
	}
	category := provider.CategoryShortDrama
	if rawCategory, present := entry["category"]; present && rawCategory != nil {
		text, ok := rawCategory.(string)
		if !ok {
			return customSourceSpec{}, false
		}
		switch provider.Category(strings.TrimSpace(text)) {
		case provider.CategoryShortDrama, provider.CategoryVideo, provider.CategoryAdult:
			category = provider.Category(strings.TrimSpace(text))
		default:
			return customSourceSpec{}, false
		}
	}
	typeID := ""
	if rawTypeID, present := entry["typeId"]; present && rawTypeID != nil {
		text, ok := rawTypeID.(string)
		if !ok {
			return customSourceSpec{}, false
		}
		typeID = strings.TrimSpace(text)
		if !customSourceTypeIDPattern.MatchString(typeID) {
			return customSourceSpec{}, false
		}
	}
	return customSourceSpec{
		id:       id,
		name:     name,
		base:     base,
		category: category,
		typeID:   typeID,
	}, true
}

// sanitizeCustomSourceName 清理名称里的控制字符与首尾空白。
func sanitizeCustomSourceName(text string) string {
	var builder strings.Builder
	for _, r := range text {
		if r < 0x20 || r == 0x7f {
			continue
		}
		builder.WriteRune(r)
	}
	return strings.TrimSpace(builder.String())
}
