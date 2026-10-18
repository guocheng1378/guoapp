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
