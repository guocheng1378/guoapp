package core

// 内置（bundled）站源模块：随应用打包的模块，首次启动自动安装到数据目录，
// 版本更高时自动升级，用户卸载后记忆不再自动装回（对齐上游 module_bundled.go）。
//
// 两种内置布局：
//
//	bundled/<id>/manifest.json + main.js   上游同款：一模块一目录
//	bundled/sites.json + bundled/impl/*.js 模块族：一份实现 + 多站点清单
//
// 模块族用于「同一套协议、多个站点」的批量内置源（maccms 系采集站即属此类）：
// 站点参数（基址、分类、type_id 等）写进清单的 config 段，脚本运行时取用。

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
)

// jsBundledRemovedFile 记录被用户卸载的内置模块，重启后不再自动装回。
const jsBundledRemovedFile = ".bundled-removed.json"

// emptyBundledFS 是「安装包不内置任何模块」时的空文件系统：所有 Open 都返回
// 不存在，读取逻辑据此返回空模块表。
type emptyBundledFS struct{}

func (emptyBundledFS) Open(string) (fs.File, error) { return nil, fs.ErrNotExist }

// bundledJSModulesFS 默认是空的——模块改由在线仓库分发，安装包不再内嵌。
// 测试里可用 `withBundledFS(os.DirFS("bundled"))` 临时挂上源码目录，
// 以便继续验证各模块的清单与脚本（源码仍留在仓库，只是不进二进制）。
var bundledJSModulesFS fs.FS = emptyBundledFS{}

// withBundledFS 在测试期间临时把内置模块文件系统挂到源码目录。
func withBundledFS(next fs.FS) (restore func()) {
	previous := bundledJSModulesFS
	bundledJSModulesFS = next
	return func() { bundledJSModulesFS = previous }
}

// bundledJSModule 是一个内置模块的清单与脚本。
type bundledJSModule struct {
	manifest JSModuleManifest
	raw      []byte
	code     []byte
}

// bundledSiteFile 是模块族清单文件（bundled/sites.json）。
type bundledSiteFile struct {
	Modules []bundledSite `json:"modules"`
}

// bundledSite 是模块族里的一个站点。
type bundledSite struct {
	ID                 string         `json:"id"`
	Name               string         `json:"name"`
	Version            string         `json:"version"`
	Description        string         `json:"description"`
	Base               string         `json:"base"`
	Category           string         `json:"category"`
	Adult              bool           `json:"adult"`
	RequiresAllSources bool           `json:"requiresAllSources"`
	Aliases            []string       `json:"aliases"`
	Hosts              []string       `json:"hosts"`
	Referer            string         `json:"referer"`
	Implementation     string         `json:"implementation"`
	Capabilities       []string       `json:"capabilities"`
	Config             map[string]any `json:"config"`
}

// readBundledJSModules 读取全部内置模块，返回模块表与失败原因。
func readBundledJSModules() (map[string]bundledJSModule, []error) {
	modules := map[string]bundledJSModule{}
	var failures []error

	// 1) 模块族：一份实现 + 多站点。
	if raw, err := fs.ReadFile(bundledJSModulesFS, "sites.json"); err == nil {
		var sites bundledSiteFile
		if err := json.Unmarshal(raw, &sites); err != nil {
			failures = append(failures, errors.New("内置站点清单无法解析"))
		} else {
			for _, site := range sites.Modules {
				module, err := bundledSiteModule(site)
				if err != nil {
					failures = append(failures, err)
					continue
				}
				modules[site.ID] = module
			}
		}
	}

	// 2) 上游同款的一模块一目录。
	entries, err := fs.ReadDir(bundledJSModulesFS, ".")
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			// 安装包不内置模块：空文件系统不是错误，正常返回空表。
			return modules, failures
		}
		return modules, []error{err}
	}
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), "_") || entry.Name() == "impl" {
			continue
		}
		module, err := bundledDirModule(entry.Name())
		if err != nil {
			failures = append(failures, err)
			continue
		}
		modules[module.manifest.ID] = module
	}
	return modules, failures
}

// bundledSiteModule 把模块族里的一个站点合成为内置模块。
func bundledSiteModule(site bundledSite) (bundledJSModule, error) {
	manifest := JSModuleManifest{
		ID: strings.TrimSpace(site.ID), Name: strings.TrimSpace(site.Name),
		Version: strings.TrimSpace(site.Version), Description: strings.TrimSpace(site.Description),
		API: jsModuleAPIVersion, Runtime: jsModuleRuntimeJS,
		Hosts: site.Hosts, Capabilities: site.Capabilities,
		Adult: &site.Adult, Category: site.Category, Base: site.Base, Referer: site.Referer,
		Aliases: site.Aliases, RequiresAllSources: site.RequiresAllSources,
		Implementation: site.Implementation, Config: site.Config,
	}
	manifest.normalize(manifest.ID)
	if err := manifest.validate(); err != nil {
		return bundledJSModule{}, errors.New("内置模块 " + site.ID + " 的清单无效：" + err.Error())
	}
	code, err := bundledImplementation(manifest.Implementation)
	if err != nil {
		return bundledJSModule{}, err
	}
	raw, err := json.MarshalIndent(manifest, "", "  ")
	if err != nil {
		return bundledJSModule{}, err
	}
	return bundledJSModule{manifest: manifest, raw: raw, code: code}, nil
}

// bundledDirModule 读取一模块一目录的内置模块。
func bundledDirModule(id string) (bundledJSModule, error) {
	// 清单与脚本都必须从 embed FS 读：打包后磁盘上没有 bundled/<id> 相对路径，
	// 走 os.ReadFile 会让所有内置目录模块在运行时读不到清单。
	raw, err := fs.ReadFile(bundledJSModulesFS, path.Join(id, jsModuleManifestFile))
	if err != nil {
		raw, err = fs.ReadFile(bundledJSModulesFS, path.Join(id, jsModuleLegacyManifestFile))
	}
	if err != nil {
		// 内置目录没有清单：不是模块目录，跳过而不是报错。
		return bundledJSModule{}, errors.New("内置模块 " + id + " 缺少清单")
	}
	if len(raw) > jsModuleManifestBytes {
		return bundledJSModule{}, errors.New("内置模块 " + id + " 的清单过大")
	}
	var manifest JSModuleManifest
	if err := json.Unmarshal(raw, &manifest); err != nil {
		return bundledJSModule{}, errors.New("内置模块 " + id + " 的清单无法解析：" + err.Error())
	}
	manifest.normalize(id)
	if err := manifest.validate(); err != nil {
		return bundledJSModule{}, errors.New("内置模块 " + id + " 的清单无效：" + err.Error())
	}
	code, err := fs.ReadFile(bundledJSModulesFS, path.Join(id, manifest.mainFile()))
	if err != nil {
		code, err = bundledImplementation(manifest.Implementation)
		if err != nil {
			return bundledJSModule{}, err
		}
	}
	return bundledJSModule{manifest: manifest, raw: raw, code: code}, nil
}

// bundledImplementation 读取共享实现脚本。
func bundledImplementation(name string) ([]byte, error) {
	name = strings.TrimSpace(name)
	if name == "" {
		return nil, errors.New("内置模块缺少实现脚本")
	}
	if strings.ContainsAny(name, "/\\") || strings.Contains(name, "..") {
		return nil, errors.New("内置模块实现名无效：" + name)
	}
	code, err := fs.ReadFile(bundledJSModulesFS, path.Join("impl", name+".js"))
	if err != nil {
		return nil, errors.New("内置模块实现缺失：" + name)
	}
	return code, nil
}

// jsModuleBundledEnabled 控制引擎启动时是否装配内置模块。
// 测试里关掉：内置模块会改写全局 provider 注册表（接管内置采集站），
// 让依赖内置 Go 实现的既有用例失去被测对象。
var jsModuleBundledEnabled = true

// installBundledJSModules 把内置模块写进数据目录：未安装或版本更高时写入。
// 被用户卸载过的内置模块不再自动装回。返回实际安装的模块 id。
func installBundledJSModules(root string) ([]string, []error) {
	modules, failures := readBundledJSModules()
	removed := removedBundledJSModules(root)
	installed := []string{}
	for id, module := range modules {
		if removed[id] {
			continue
		}
		if current, _, err := readJSModuleManifestFile(filepath.Join(root, id)); err == nil {
			current.normalize(id)
			if !newerModuleVersion(module.manifest.Version, current.Version) {
				continue
			}
		}
		if err := writeJSModuleDir(root, module.manifest.ID, module.raw, module.code); err != nil {
			failures = append(failures, err)
			continue
		}
		installed = append(installed, module.manifest.ID)
	}
	sort.Strings(installed)
	return installed, failures
}

// writeJSModuleDir 原子写入一个模块目录。
func writeJSModuleDir(root, id string, manifest, code []byte) error {
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	staging := filepath.Join(root, "."+id+".installing")
	if err := os.RemoveAll(staging); err != nil {
		return err
	}
	if err := os.MkdirAll(staging, 0o700); err != nil {
		return err
	}
	defer os.RemoveAll(staging)
	if err := os.WriteFile(filepath.Join(staging, jsModuleManifestFile), manifest, 0o600); err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(staging, jsModuleEntryFile), code, 0o600); err != nil {
		return err
	}
	target := filepath.Join(root, id)
	if err := os.RemoveAll(target); err != nil {
		return err
	}
	return os.Rename(staging, target)
}

// removedBundledJSModules 读取被卸载的内置模块名单。
func removedBundledJSModules(root string) map[string]bool {
	removed := map[string]bool{}
	raw, err := os.ReadFile(filepath.Join(root, jsBundledRemovedFile))
	if err != nil {
		return removed
	}
	var ids []string
	if json.Unmarshal(raw, &ids) == nil {
		for _, id := range ids {
			removed[id] = true
		}
	}
	return removed
}

// markBundledJSModuleRemoved 记录/撤销「内置模块已被卸载」。
func markBundledJSModuleRemoved(root, id string, removed bool) error {
	set := removedBundledJSModules(root)
	if set[id] == removed {
		return nil
	}
	if removed {
		set[id] = true
	} else {
		delete(set, id)
	}
	ids := make([]string, 0, len(set))
	for name := range set {
		ids = append(ids, name)
	}
	sort.Strings(ids)
	raw, err := json.Marshal(ids)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(root, 0o700); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(root, jsBundledRemovedFile), raw, 0o600)
}

// newerModuleVersion 比较两个三段版本号，candidate 是否比 current 新。
func newerModuleVersion(candidate, current string) bool {
	parse := func(version string) []int {
		parts := strings.Split(strings.TrimSpace(version), ".")
		if len(parts) != 3 {
			return nil
		}
		numbers := make([]int, 3)
		for index, part := range parts {
			number, err := strconv.Atoi(strings.TrimSpace(part))
			if err != nil || number < 0 {
				return nil
			}
			numbers[index] = number
		}
		return numbers
	}
	next, installed := parse(candidate), parse(current)
	return next != nil && installed != nil && slices.Compare(next, installed) > 0
}

// bundledJSIndexEntries 把内置模块转成在线商店条目（内置源不在商店里重复出现）。
func bundledJSIndexEntries() []moduleIndexEntry {
	modules, _ := readBundledJSModules()
	entries := make([]moduleIndexEntry, 0, len(modules))
	for _, module := range modules {
		entries = append(entries, moduleIndexEntry{
			ID: module.manifest.ID, Name: module.manifest.displayName(), Version: module.manifest.Version,
			Description: module.manifest.Description, API: module.manifest.API, Adult: module.manifest.adult(),
			Category: strings.TrimSpace(module.manifest.Category),
			Bundled:  true,
		})
	}
	sort.Slice(entries, func(a, b int) bool { return entries[a].ID < entries[b].ID })
	return entries
}
