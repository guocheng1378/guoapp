package provider

import (
	"sort"
	"strings"
	"sync"
)

var (
	registryMu   sync.RWMutex
	registry     = map[string]Provider{}
	implemented  = map[string]bool{}
	aliasIndex   = map[string]string{}
	hostIndex    = map[string]string{}
	suffixHosts  []suffixHost
	activeConfig Config
)

type suffixHost struct {
	id     string
	suffix string
}

type specProvider struct {
	spec Spec
}

func (p specProvider) Spec() Spec { return p.spec }

func init() {
	for _, entry := range sourceEntries {
		registry[entry.spec.ID] = specProvider{spec: entry.spec}
		for _, alias := range entry.aliases {
			aliasIndex[strings.ToLower(strings.TrimSpace(alias))] = entry.spec.ID
		}
		for _, host := range entry.hosts {
			host = strings.ToLower(strings.TrimSpace(host))
			if strings.HasPrefix(host, ".") {
				suffixHosts = append(suffixHosts, suffixHost{id: entry.spec.ID, suffix: host})
				continue
			}
			hostIndex[host] = entry.spec.ID
		}
	}
}

func Register(p Provider) {
	if p == nil {
		return
	}
	spec := p.Spec()
	if spec.ID == "" {
		return
	}
	registryMu.Lock()
	defer registryMu.Unlock()
	registry[spec.ID] = p
	implemented[spec.ID] = true
}

func IsRegistered(id string) bool {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return implemented[canonicalLocked(id)]
}

func RegisterAliases(id string, aliases ...string) {
	registryMu.Lock()
	defer registryMu.Unlock()
	for _, alias := range aliases {
		key := strings.ToLower(strings.TrimSpace(alias))
		if key != "" {
			aliasIndex[key] = id
		}
	}
}

func RegisterHosts(id string, hosts ...string) {
	registryMu.Lock()
	defer registryMu.Unlock()
	for _, host := range hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" {
			continue
		}
		if strings.HasPrefix(host, ".") {
			suffixHosts = append(suffixHosts, suffixHost{id: id, suffix: host})
			continue
		}
		hostIndex[host] = id
	}
}

func canonicalLocked(source string) string {
	key := strings.ToLower(strings.TrimSpace(source))
	if canonical, found := aliasIndex[key]; found {
		return canonical
	}
	return strings.TrimSpace(source)
}

func Canonical(source string) string {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return canonicalLocked(source)
}

func Get(id string) (Provider, bool) {
	registryMu.RLock()
	defer registryMu.RUnlock()
	p, found := registry[canonicalLocked(id)]
	return p, found
}

func SpecOf(source string) (Spec, bool) {
	p, found := Get(source)
	if !found {
		return Spec{}, false
	}
	return p.Spec(), true
}

func All() []Provider {
	registryMu.RLock()
	defer registryMu.RUnlock()
	list := make([]Provider, 0, len(registry))
	for _, p := range registry {
		list = append(list, p)
	}
	sort.Slice(list, func(i, j int) bool { return list[i].Spec().ID < list[j].Spec().ID })
	return list
}

func KnownSource(source string) bool {
	_, found := Get(source)
	return found
}

func DuanjuSource(source string) bool {
	spec, found := SpecOf(source)
	return found && spec.Family == FamilyDuanju
}

func ForHost(host string) string {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return ""
	}
	registryMu.RLock()
	defer registryMu.RUnlock()
	if id, found := hostIndex[host]; found {
		return id
	}
	for _, entry := range suffixHosts {
		if strings.HasSuffix(host, entry.suffix) {
			return entry.id
		}
	}
	return ""
}

func Configure(cfg Config) {
	registryMu.Lock()
	defer registryMu.Unlock()
	activeConfig = cfg
}

func AllSourcesEnabled() bool {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return activeConfig.AllSources
}

func ConfiguredHost(source string) string {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return activeConfig.Hosts[canonicalLocked(source)]
}

func Available(source string) bool {
	registryMu.RLock()
	defer registryMu.RUnlock()
	p, found := registry[canonicalLocked(source)]
	if !found {
		return false
	}
	return !p.Spec().RequiresAllSources || activeConfig.AllSources
}

// CustomIDPrefix 是用户自定义站源的 ID 前缀。自定义源经 config.source
// 的 customSources 段动态注册（maccms 点播源），卸载/清空走 UnregisterCustom，
// 该函数只允许移除带此前缀的 ID，防止误卸内置 provider。
const CustomIDPrefix = "custom-"

func IsCustomSourceID(id string) bool {
	return strings.HasPrefix(strings.TrimSpace(id), CustomIDPrefix)
}

// AliasOwner 返回别名归属的站源 id；别名未被登记时返回空串。
// 运行时注册的模块用它判断别名是否已被别的站源占用。
func AliasOwner(alias string) string {
	registryMu.RLock()
	defer registryMu.RUnlock()
	return aliasIndex[strings.ToLower(strings.TrimSpace(alias))]
}

// Unregister 移除一个运行时注册的 provider（站源模块卸载/测试清理用）。
// 只删注册表项，不动内置源表（sourceEntries）：内置源被误删后本次进程内
// 无法恢复，所以调用方必须先确认该 id 属于可卸载的模块。
// 顺带清掉该 id 占用的别名与域名归属，避免卸载后别名仍指向已不存在的源。
func Unregister(id string) bool {
	registryMu.Lock()
	defer registryMu.Unlock()
	key := canonicalLocked(id)
	if _, found := registry[key]; !found {
		return false
	}
	delete(registry, key)
	delete(implemented, key)
	for alias, owner := range aliasIndex {
		if owner == key {
			delete(aliasIndex, alias)
		}
	}
	for host, owner := range hostIndex {
		if owner == key {
			delete(hostIndex, host)
		}
	}
	// 域名后缀是切片索引（按注册顺序 append），重注册同一个模块前必须清掉
	// 它旧的后缀归属，否则单模块热重载会让后缀条目不断累积。
	kept := suffixHosts[:0]
	for _, entry := range suffixHosts {
		if entry.id != key {
			kept = append(kept, entry)
		}
	}
	suffixHosts = kept
	return true
}

// UnregisterCustom 移除一个动态注册的自定义站源。只接受 custom- 前缀的
// ID（内置源一律拒绝），返回是否确有移除。已不存在的 ID 幂等返回 false。
func UnregisterCustom(id string) bool {
	if !IsCustomSourceID(id) {
		return false
	}
	registryMu.Lock()
	defer registryMu.Unlock()
	if _, found := registry[id]; !found {
		return false
	}
	delete(registry, id)
	delete(implemented, id)
	return true
}
