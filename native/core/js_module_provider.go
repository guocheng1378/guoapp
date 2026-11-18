package core

// 把 JS 模块包装成 provider.Provider，并提供 zip 安装 / 目录扫描 / 注册 / 卸载。
//
// 模块的可选能力按导出情况装配：导出了 resolveMedia 才实现 MediaResolver
// （否则走核心通用的「章节播放页解析」链路），导出了 catalogPageSorted
// 才实现 CatalogSorter（否则客户端按字段兜底排序）。

import (
	"archive/zip"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"duanjuapp/native/provider"
)

// jsModuleRootPath 是模块根目录（<数据目录>/modules），由 newNativeEngine 设置。
var jsModuleRootPath string

type jsModuleProvider struct {
	manifest JSModuleManifest
	runtime  *jsModuleRuntime
}

// jsModuleMediaProvider 是导出了 resolveMedia 的模块。
type jsModuleMediaProvider struct{ *jsModuleProvider }

// jsModuleSortedProvider 是导出了服务端排序的模块。
type jsModuleSortedProvider struct{ *jsModuleProvider }

// jsModuleMediaSortedProvider 同时导出取流与服务端排序的模块。
type jsModuleMediaSortedProvider struct{ *jsModuleProvider }

type jsModulePage struct {
	Items   []provider.Drama `json:"items"`
	HasMore bool             `json:"hasMore"`
	Warning string           `json:"warning"`
}

type jsModuleDetail struct {
	Drama    provider.Drama     `json:"drama"`
	Chapters []provider.Chapter `json:"chapters"`
}

type jsModuleMedia struct {
	URL        string          `json:"url"`
	Referer    string          `json:"referer"`
	Playlist   string          `json:"playlist"`
	HLSKey     []byte          `json:"hlsKey"`
	CENCKey    []byte          `json:"cencKey"`
	Quality    int             `json:"quality"`
	DurationMS int64           `json:"durationMs"`
	Variants   []jsModuleMedia `json:"variants"`
}

func (media jsModuleMedia) providerMedia() provider.Media {
	converted := provider.Media{
		URL: media.URL, Referer: media.Referer, Playlist: media.Playlist,
		HLSKey: media.HLSKey, CENCKey: media.CENCKey, Quality: media.Quality,
		Duration: time.Duration(media.DurationMS) * time.Millisecond,
	}
	for _, variant := range media.Variants {
		converted.Variants = append(converted.Variants, variant.providerMedia())
	}
	return converted
}

func (p *jsModuleProvider) Spec() provider.Spec {
	category := provider.CategoryShortDrama
	switch strings.ToLower(strings.TrimSpace(p.manifest.Category)) {
	case "video":
		category = provider.CategoryVideo
	case "adult":
		category = provider.CategoryAdult
	}
	return provider.Spec{
		ID:       p.manifest.ID,
		Name:     p.manifest.displayName(),
		Base:     p.manifest.baseURL(),
		Referer:  p.manifest.Referer,
		Category: category,
		Family:   provider.FamilyDuanju,
		Searcher: !p.manifest.DisableSearch,
		Paged:    !p.manifest.DisablePaging,
		// 模块族里的站源与内置源一样受变体门控：单源变体不出现。
		RequiresAllSources: p.manifest.RequiresAllSources,
	}
}

func (p *jsModuleProvider) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	var raw json.RawMessage
	if err := p.runtime.call(ctx, host, "categories", &raw, false); err != nil {
		return nil, err
	}
	var list []provider.CatalogCategory
	if json.Unmarshal(raw, &list) == nil {
		return list, nil
	}
	var partial struct {
		Items []provider.CatalogCategory `json:"items"`
	}
	if err := json.Unmarshal(raw, &partial); err != nil {
		return nil, err
	}
	return partial.Items, nil
}

func (p *jsModuleProvider) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	if strings.TrimSpace(query) != "" {
		items, searchErr := p.Search(ctx, host, query)
		return items, false, searchErr
	}
	var result jsModulePage
	if err := p.runtime.call(ctx, host, "catalogPage", &result, page, category); err != nil {
		return nil, false, err
	}
	if result.Warning != "" {
		return result.Items, result.HasMore, errors.New(result.Warning)
	}
	return result.Items, result.HasMore, nil
}

func (p *jsModuleProvider) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	var result jsModuleDetail
	if err := p.runtime.call(ctx, host, "detail", &result, sourceID); err != nil {
		return provider.Drama{}, nil, err
	}
	return result.Drama, result.Chapters, nil
}

func (p *jsModuleProvider) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	items, _, err := p.SearchPage(ctx, host, query, 1)
	return items, err
}

// SearchPage 是分页搜索：与目录同源的分页搜索源保持一致的上拉加载语义。
func (p *jsModuleProvider) SearchPage(ctx context.Context, host provider.Host, query string, page int) ([]provider.Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	var result jsModulePage
	if err := p.runtime.call(ctx, host, "search", &result, page, query); err != nil {
		return nil, false, err
	}
	return result.Items, result.HasMore, nil
}

// resolveMedia 取流（仅导出了 resolveMedia 的模块走这里）。
func (p *jsModuleProvider) resolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	var media jsModuleMedia
	if err := p.runtime.call(ctx, host, "resolveMedia", &media, task); err != nil {
		return provider.Media{}, err
	}
	if media.URL == "" {
		return provider.Media{}, errors.New("模块未返回播放地址")
	}
	return media.providerMedia(), nil
}

// ResolveMedia 取流接口（导出了 resolveMedia 的模块才装配这个类型）。
func (p *jsModuleMediaProvider) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	return p.resolveMedia(ctx, host, task)
}

// ResolveMedia 取流接口（导出了 resolveMedia 与服务端排序的模块）。
func (p *jsModuleMediaSortedProvider) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	return p.resolveMedia(ctx, host, task)
}

// catalogPageSorted 服务端排序（仅导出了 catalogPageSorted 的模块走这里）。
func (p *jsModuleProvider) catalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]provider.Drama, bool, error) {
	var result jsModulePage
	if err := p.runtime.call(ctx, host, "catalogPageSorted", &result, page, category, sort); err != nil {
		return nil, false, err
	}
	return result.Items, result.HasMore, nil
}

// CatalogPageSorted 服务端排序接口。
func (p *jsModuleSortedProvider) CatalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]provider.Drama, bool, error) {
	return p.catalogPageSorted(ctx, host, page, category, sort)
}

// CatalogPageSorted 服务端排序接口。
func (p *jsModuleMediaSortedProvider) CatalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]provider.Drama, bool, error) {
	return p.catalogPageSorted(ctx, host, page, category, sort)
}

// ---- 安装 / 扫描 / 注册 ----

// readJSModuleManifest 读取一个已安装模块的清单。
func readJSModuleManifest(root, id string) (JSModuleManifest, error) {
	manifest, _, err := readJSModuleManifestFile(filepath.Join(root, id))
	if err != nil {
		return manifest, err
	}
	manifest.normalize(id)
	if err := manifest.validate(); err != nil {
		return manifest, err
	}
	return manifest, nil
}

// ScanJSModules 列出已安装模块。
func ScanJSModules(root string) ([]JSModuleManifest, error) {
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	manifests := []JSModuleManifest{}
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		manifest, manifestErr := readJSModuleManifest(root, entry.Name())
		if manifestErr != nil {
			continue
		}
		manifests = append(manifests, manifest)
	}
	sort.Slice(manifests, func(i, j int) bool { return manifests[i].ID < manifests[j].ID })
	return manifests, nil
}

// InstallJSModuleZip 把模块 zip 解压到 <root>/<id>/，返回模块 ID。
// 防 zip slip：任何越出目标目录的条目都拒绝。
func InstallJSModuleZip(d *Downloader, zipPath string) (string, error) {
	raw, err := os.ReadFile(zipPath)
	if err != nil {
		return "", fmt.Errorf("模块包无法读取: %w", err)
	}
	return installJSModulePackage(raw)
}

// installJSModulePackage 解压并安装一个模块包。
func installJSModulePackage(raw []byte) (string, error) {
	reader, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return "", fmt.Errorf("模块包无法打开: %w", err)
	}
	root := jsModuleRootPath
	if root == "" {
		return "", errors.New("模块目录未初始化")
	}
	// 先解压到临时目录，读完 manifest 确定 id 再落位。
	staging, err := os.MkdirTemp(root, ".staging-")
	if err != nil {
		return "", err
	}
	defer os.RemoveAll(staging)
	cleanRoot := filepath.Clean(staging)
	for _, file := range reader.File {
		target := filepath.Join(staging, file.Name)
		if !strings.HasPrefix(filepath.Clean(target), cleanRoot+string(os.PathSeparator)) && filepath.Clean(target) != cleanRoot {
			return "", fmt.Errorf("模块包含非法路径: %s", file.Name)
		}
		if file.FileInfo().IsDir() {
			if err := os.MkdirAll(target, 0o700); err != nil {
				return "", err
			}
			continue
		}
		if file.UncompressedSize64 > jsModuleEntryBytes {
			return "", fmt.Errorf("模块文件过大: %s", file.Name)
		}
		if err := os.MkdirAll(filepath.Dir(target), 0o700); err != nil {
			return "", err
		}
		source, err := file.Open()
		if err != nil {
			return "", err
		}
		destination, err := os.Create(target)
		if err != nil {
			source.Close()
			return "", err
		}
		_, copyErr := io.Copy(destination, io.LimitReader(source, jsModuleEntryBytes))
		destination.Close()
		source.Close()
		if copyErr != nil {
			return "", copyErr
		}
	}
	// 兼容「zip 里多一层目录」：找清单。
	manifestPath, err := findJSModuleManifest(staging)
	if err != nil {
		return "", err
	}
	var manifest JSModuleManifest
	data, err := os.ReadFile(manifestPath)
	if err != nil {
		return "", err
	}
	if err := json.Unmarshal(data, &manifest); err != nil {
		return "", fmt.Errorf("清单无法解析: %w", err)
	}
	manifest.normalize(filepath.Base(manifestPath))
	if strings.TrimSpace(manifest.ID) == "" {
		return "", errors.New("清单缺少 id")
	}
	if err := manifest.validate(); err != nil {
		return "", err
	}
	source := filepath.Dir(manifestPath)
	target := filepath.Join(root, manifest.ID)
	if err := os.RemoveAll(target); err != nil {
		return "", err
	}
	if err := os.Rename(source, target); err != nil {
		return "", err
	}
	return manifest.ID, nil
}

func findJSModuleManifest(dir string) (string, error) {
	var found string
	err := filepath.Walk(dir, func(path string, info os.FileInfo, walkErr error) error {
		if walkErr != nil || info == nil || info.IsDir() {
			return nil
		}
		name := strings.ToLower(filepath.Base(path))
		if (name == jsModuleManifestFile || name == jsModuleLegacyManifestFile) && found == "" {
			found = path
		}
		return nil
	})
	if err != nil {
		return "", err
	}
	if found == "" {
		return "", errors.New("模块包缺少清单")
	}
	return found, nil
}

// nativeJSModuleList 供 Dart 侧列出已安装模块。
func (engine *nativeEngine) nativeJSModuleList() []map[string]any {
	root := filepath.Join(engine.directory, "modules")
	manifests, _ := ScanJSModules(root)
	bundled := map[string]bool{}
	for _, entry := range bundledJSIndexEntries() {
		bundled[entry.ID] = true
	}
	out := make([]map[string]any, 0, len(manifests))
	for _, manifest := range manifests {
		out = append(out, map[string]any{
			"id": manifest.ID, "name": manifest.displayName(), "version": manifest.Version,
			"description": manifest.Description, "hosts": manifest.Hosts,
			"capabilities": manifest.Capabilities, "rankings": manifest.Rankings, "adult": manifest.adult(),
			"category": manifest.Category, "aliases": manifest.Aliases,
			"api": manifest.API, "bundled": bundled[manifest.ID], "installed": true,
			"requiresAllSources": manifest.RequiresAllSources,
		})
	}
	return out
}

// nativeJSModuleInstall 安装一个模块 zip 并立刻注册（不用重启）。
func (engine *nativeEngine) nativeJSModuleInstall(ctx context.Context, zipPath string) (any, error) {
	if strings.TrimSpace(zipPath) == "" {
		return nil, errors.New("缺少模块包路径")
	}
	root := filepath.Join(engine.directory, "modules")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	jsModuleRootPath = root
	id, err := InstallJSModuleZip(engine.downloader, zipPath)
	if err != nil {
		return nil, err
	}
	if err := reloadJSModule(engine.downloader, root, id); err != nil {
		return nil, err
	}
	return map[string]any{"id": id, "installed": true}, nil
}

// nativeJSModuleInstallOnline 从在线仓库安装一个模块（索引 → 下载 → 校验 → 安装）。
func (engine *nativeEngine) nativeJSModuleInstallOnline(ctx context.Context, id string) (any, error) {
	id = strings.TrimSpace(id)
	if !jsModuleIDPattern.MatchString(id) {
		return nil, errors.New("模块标识无效")
	}
	root := filepath.Join(engine.directory, "modules")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	jsModuleRootPath = root
	raw, err := engine.indexedModulePackage(ctx, id)
	if err != nil {
		return nil, err
	}
	installed, err := installJSModulePackage(raw)
	if err != nil {
		return nil, err
	}
	// 在线安装等于重新装回：清掉「已卸载」记忆。
	if err := markBundledJSModuleRemoved(root, installed, false); err != nil {
		return nil, err
	}
	if err := reloadJSModule(engine.downloader, root, installed); err != nil {
		return nil, err
	}
	return map[string]any{"id": installed, "installed": true}, nil
}

// nativeJSModuleUninstall 卸载一个模块：删目录、注销 provider、记住内置模块的卸载。
func (engine *nativeEngine) nativeJSModuleUninstall(id string) (any, error) {
	id = strings.TrimSpace(id)
	if !jsModuleIDPattern.MatchString(id) {
		return nil, errors.New("模块标识无效")
	}
	root := filepath.Join(engine.directory, "modules")
	if err := os.RemoveAll(filepath.Join(root, id)); err != nil {
		return nil, err
	}
	if err := markBundledJSModuleRemoved(root, id, true); err != nil {
		return nil, err
	}
	provider.Unregister(id)
	engine.invalidateSourceCatalog(id)
	return map[string]any{"id": id, "installed": false}, nil
}

// jsModuleFreeHosts 过滤掉已被别的站源占用的域名：模块不得抢走既有站源的
// 域名归属，否则按域名反查站源会指向错误的源。
func jsModuleFreeHosts(manifest JSModuleManifest) []string {
	free := make([]string, 0, len(manifest.Hosts))
	for _, host := range manifest.Hosts {
		host = strings.ToLower(strings.TrimSpace(host))
		if host == "" {
			continue
		}
		if owner := provider.ForHost(host); owner != "" && owner != manifest.ID {
			continue
		}
		free = append(free, host)
	}
	return free
}

// jsModuleFreeAliases 过滤掉已被别的站源占用的别名。
func jsModuleFreeAliases(manifest JSModuleManifest) []string {
	free := make([]string, 0, len(manifest.Aliases))
	for _, alias := range manifest.Aliases {
		alias = strings.TrimSpace(alias)
		if alias == "" {
			continue
		}
		if owner := provider.AliasOwner(alias); owner != "" && owner != manifest.ID {
			continue
		}
		free = append(free, alias)
	}
	return free
}

// registerJSModuleOne 加载并注册单个模块（清单已归一且校验过）。
func registerJSModuleOne(d *Downloader, root string, manifest JSModuleManifest) error {
	script, err := os.ReadFile(filepath.Join(root, manifest.ID, manifest.mainFile()))
	if err != nil {
		return err
	}
	runtime, err := newJSModuleRuntime(d, manifest, string(script))
	if err != nil {
		return err
	}
	base := &jsModuleProvider{manifest: manifest, runtime: runtime}
	hasMedia := runtime.hasExport("resolveMedia")
	hasSorted := runtime.hasExport("catalogPageSorted")
	switch {
	case hasMedia && hasSorted:
		provider.Register(&jsModuleMediaSortedProvider{base})
	case hasMedia:
		provider.Register(&jsModuleMediaProvider{base})
	case hasSorted:
		provider.Register(&jsModuleSortedProvider{base})
	default:
		provider.Register(base)
	}
	if len(manifest.Hosts) > 0 {
		provider.RegisterHosts(manifest.ID, jsModuleFreeHosts(manifest)...)
	}
	if len(manifest.HostSuffixes) > 0 {
		provider.RegisterHosts(manifest.ID, manifest.HostSuffixes...)
	}
	if len(manifest.Aliases) > 0 {
		provider.RegisterAliases(manifest.ID, jsModuleFreeAliases(manifest)...)
	}
	return nil
}

// reloadJSModule 只重载一个模块：先注销旧 provider（连带清它的域名/别名/后缀
// 归属），再从磁盘重新加载。安装或更新单个模块走这里，不动其余站源，也不
// 让全量重注册把 suffixHosts 反复追加（对齐上游 reloadModuleLocked）。
func reloadJSModule(d *Downloader, root, id string) error {
	jsModuleRootPath = root
	manifest, err := readJSModuleManifest(root, id)
	if err != nil {
		return err
	}
	provider.Unregister(id)
	if err := registerJSModuleOne(d, root, manifest); err != nil {
		return err
	}
	// 模块升级后 provider 是新的，但剧库里还是旧模块的缓存；不清的话
	// 首页命中 fresh 快照不会重新解析，表现为「更新完不刷新」。
	invalidateModuleCatalog(id)
	return nil
}

// invalidateModuleCatalog 清掉某模块站源的目录缓存（新装/升级/卸载共用）。
func invalidateModuleCatalog(id string) {
	nativeState.Lock()
	engine := nativeState.engine
	nativeState.Unlock()
	if engine != nil {
		engine.invalidateSourceCatalog(id)
	}
}

// RegisterJSModules 加载并注册所有已安装模块，返回注册成功的 ID。
func RegisterJSModules(d *Downloader, root string) ([]string, error) {
	jsModuleRootPath = root
	if err := os.MkdirAll(root, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return nil, err
	}
	manifests, err := ScanJSModules(root)
	if err != nil {
		return nil, err
	}
	registered := []string{}
	for _, manifest := range manifests {
		if err := registerJSModuleOne(d, root, manifest); err != nil {
			continue
		}
		registered = append(registered, manifest.ID)
	}
	return registered, nil
}
