package core

// 站源模块的安装闭环（对齐上游 module_install.go）：
//
//	prepare(file|address|indexed)  → 下载/解包 → 冲突检查 → 令牌暂存 → 返回模块信息
//	install(token)                 → 凭令牌取回同一个包 → 再校验 → 落盘 → 热注册
//
// 为什么要两段式：用户要在安装前看到这个模块会访问哪些域名、提供哪些功能、
// 是否限制级、是否覆盖已装版本；令牌保证「预检的包」与「安装的包」是同一个，
// 避免中途被换包。

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"regexp"
	"strings"

	"duanjuapp/native/provider"
)

const (
	// modulePackageFolder 是预检后暂存安装包的目录（缓存目录下）。
	modulePackageFolder = "module-packages"
)

// modulePackageToken 是安装令牌：32 位小写十六进制。
var modulePackageToken = regexp.MustCompile(`^[0-9a-f]{32}$`)

// nativeModuleInfo 是模块管理页的一条模块信息。
type nativeModuleInfo struct {
	ID           string            `json:"id"`
	Name         string            `json:"name"`
	Version      string            `json:"version"`
	Description  string            `json:"description"`
	Hosts        []string          `json:"hosts,omitempty"`
	Capabilities []string          `json:"capabilities,omitempty"`
	Rankings     []JSModuleRanking `json:"rankings,omitempty"`
	Adult        bool              `json:"adult"`
	// Category 是模块登记的站源分类（shortDrama/video/adult），Dart 侧据此把
	// 模块归入首页对应的分组；缺了它非官方表模块会被一律当成短剧类。
	Category     string            `json:"category,omitempty"`
	Bundled      bool              `json:"bundled,omitempty"`
	Installed    bool              `json:"installed"`
	Previous     string            `json:"previous,omitempty"`
	UpdateTo     string            `json:"updateTo,omitempty"`
	Token        string            `json:"token,omitempty"`
	Error        string            `json:"error,omitempty"`
}

// moduleInfoOf 从清单生成模块信息。
func moduleInfoOf(manifest JSModuleManifest) nativeModuleInfo {
	return nativeModuleInfo{
		ID: manifest.ID, Name: manifest.displayName(), Version: manifest.Version,
		Description: manifest.Description, Hosts: manifest.Hosts,
		Capabilities: manifest.Capabilities, Rankings: manifest.Rankings, Adult: manifest.adult(),
		Category: strings.TrimSpace(manifest.Category),
	}
}

// moduleRoot 返回模块目录。
func (engine *nativeEngine) moduleRoot() string {
	if engine == nil {
		return jsModuleRootPath
	}
	return filepath.Join(engine.directory, "modules")
}

// moduleCacheRoot 返回可重建缓存的落盘目录（预检包暂存用）。
func (engine *nativeEngine) moduleCacheRoot() string {
	if engine.cacheDirectory != "" {
		return engine.cacheDirectory
	}
	return engine.directory
}

// nativeJSModuleInfos 列出已安装模块：读不到的模块带 Error（用户能看到坏在哪），
// 而不是静默跳过。
func (engine *nativeEngine) nativeJSModuleInfos() ([]nativeModuleInfo, error) {
	root := engine.moduleRoot()
	entries, err := os.ReadDir(root)
	if errors.Is(err, os.ErrNotExist) {
		return []nativeModuleInfo{}, nil
	}
	if err != nil {
		return nil, err
	}
	bundled, _ := readBundledJSModules()
	items := make([]nativeModuleInfo, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() || strings.HasPrefix(entry.Name(), ".") {
			continue
		}
		manifest, readErr := readJSModuleManifest(root, entry.Name())
		if readErr != nil {
			items = append(items, nativeModuleInfo{ID: entry.Name(), Name: entry.Name(), Error: readErr.Error()})
			continue
		}
		info := moduleInfoOf(manifest)
		info.Bundled = bundled[manifest.ID].raw != nil
		if _, found := provider.Get(manifest.ID); !found {
			info.Error = "模块未能加载，详见诊断日志"
		}
		items = append(items, info)
	}
	return items, nil
}

// nativeJSModulePrepare 预检一个模块包：下载/读取 → 解包 → 冲突检查 → 令牌暂存。
// file / address / indexed 三选一（本地路径、直链、索引里的 id）。
func (engine *nativeEngine) nativeJSModulePrepare(ctx context.Context, file, address, indexed string) (nativeModuleInfo, error) {
	var raw []byte
	var err error
	switch {
	case strings.TrimSpace(indexed) != "":
		raw, err = engine.indexedModulePackage(ctx, strings.TrimSpace(indexed))
	case strings.TrimSpace(address) != "":
		address = strings.TrimSpace(address)
		parsed, parseErr := parseModuleAddress(address)
		if parseErr != nil {
			return nativeModuleInfo{}, parseErr
		}
		raw, err = engine.downloadModulePackage(ctx, parsed)
	case strings.TrimSpace(file) != "":
		raw, err = readModulePackage(strings.TrimSpace(file))
	default:
		return nativeModuleInfo{}, errors.New("缺少模块来源")
	}
	if err != nil {
		return nativeModuleInfo{}, err
	}
	manifest, code, err := modulePackageFiles(raw)
	if err != nil {
		return nativeModuleInfo{}, err
	}
	module, err := parseJSModule(manifest, code)
	if err != nil {
		return nativeModuleInfo{}, err
	}
	if indexed != "" && module.ID != indexed {
		return nativeModuleInfo{}, fmt.Errorf("索引里的 %s 实际是模块 %s", indexed, module.ID)
	}
	if err := moduleConflict(engine.moduleRoot(), module); err != nil {
		return nativeModuleInfo{}, err
	}
	folder := filepath.Join(engine.moduleCacheRoot(), modulePackageFolder)
	if err := os.RemoveAll(folder); err != nil {
		return nativeModuleInfo{}, err
	}
	if err := os.MkdirAll(folder, 0o700); err != nil {
		return nativeModuleInfo{}, err
	}
	token := make([]byte, 16)
	if _, err := rand.Read(token); err != nil {
		return nativeModuleInfo{}, err
	}
	info := moduleInfoOf(module)
	info.Token = hex.EncodeToString(token)
	if err := os.WriteFile(filepath.Join(folder, info.Token+".zip"), raw, 0o600); err != nil {
		return nativeModuleInfo{}, err
	}
	if installed, readErr := readJSModuleManifest(engine.moduleRoot(), module.ID); readErr == nil {
		info.Installed = true
		info.Previous = installed.Version
	}
	return info, nil
}

// nativeJSModuleInstallToken 凭令牌安装预检过的模块包。
func (engine *nativeEngine) nativeJSModuleInstallToken(ctx context.Context, token string) (map[string]any, error) {
	token = strings.TrimSpace(token)
	if !modulePackageToken.MatchString(token) {
		return nil, errors.New("安装包已失效，请重新选择")
	}
	staged := filepath.Join(engine.moduleCacheRoot(), modulePackageFolder, token+".zip")
	raw, err := os.ReadFile(staged)
	if err != nil {
		return nil, errors.New("安装包已失效，请重新选择")
	}
	manifest, code, err := modulePackageFiles(raw)
	if err != nil {
		return nil, err
	}
	module, err := parseJSModule(manifest, code)
	if err != nil {
		return nil, err
	}
	root := engine.moduleRoot()
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	jsModuleRootPath = root
	if err := moduleConflict(root, module); err != nil {
		return nil, err
	}
	if err := writeJSModuleDir(root, module.ID, manifest, code); err != nil {
		return nil, err
	}
	// 安装即重新装回：清掉「已卸载」记忆。
	if err := markBundledJSModuleRemoved(root, module.ID, false); err != nil {
		return nil, err
	}
	if err := reloadJSModule(engine.downloader, root, module.ID); err != nil {
		return nil, err
	}
	_ = os.Remove(staged)
	return map[string]any{"id": module.ID, "installed": true}, nil
}

// moduleConflict 检查模块与已装模块的域名/别名冲突：冲突即拒绝安装，
// 而不是装完发现没生效。
func moduleConflict(root string, manifest JSModuleManifest) error {
	installed, err := ScanJSModules(root)
	if err != nil {
		return nil // 读不到已装列表时不拦（安装路径自己会校验）
	}
	for _, other := range installed {
		if other.ID == manifest.ID {
			continue
		}
		for _, host := range manifest.Hosts {
			if jsModuleHostClaimed(other, host) {
				return fmt.Errorf("域名 %s 已被模块 %s 占用", host, other.displayName())
			}
		}
		for _, suffix := range manifest.HostSuffixes {
			if jsModuleHostClaimed(other, suffix) {
				return fmt.Errorf("域名后缀 %s 已被模块 %s 占用", suffix, other.displayName())
			}
		}
		for _, alias := range manifest.Aliases {
			for _, otherAlias := range other.Aliases {
				if strings.EqualFold(alias, otherAlias) {
					return fmt.Errorf("别名 %s 已被模块 %s 占用", alias, other.displayName())
				}
			}
		}
	}
	return nil
}

// jsModuleHostClaimed 判断某域名/后缀是否属于该模块。
func jsModuleHostClaimed(manifest JSModuleManifest, host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	for _, owned := range manifest.Hosts {
		if strings.EqualFold(strings.TrimSpace(owned), host) {
			return true
		}
	}
	for _, suffix := range manifest.HostSuffixes {
		if strings.EqualFold(strings.TrimSpace(suffix), host) {
			return true
		}
	}
	return false
}

// parseModuleAddress 校验模块直链地址。
func parseModuleAddress(address string) (string, error) {
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return "", errors.New("模块地址无效")
	}
	return address, nil
}

// downloadModulePackage 限量下载模块安装包。
func (engine *nativeEngine) downloadModulePackage(ctx context.Context, address string) ([]byte, error) {
	return engine.fetchJSModuleResource(ctx, address, jsModulePackageBytes)
}

// readModulePackage 读取本地模块安装包。
func readModulePackage(file string) ([]byte, error) {
	info, err := os.Stat(file)
	if err != nil {
		return nil, err
	}
	if info.Size() > jsModulePackageBytes {
		return nil, fmt.Errorf("模块包超过 %d KB", jsModulePackageBytes>>10)
	}
	return os.ReadFile(file)
}

// modulePackageFiles 解开模块安装包，只取 manifest.json 与 main.js 两个条目
// （与上游一致：多余文件视为非法包）。
func modulePackageFiles(raw []byte) (manifest, code []byte, err error) {
	reader, err := zip.NewReader(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		return nil, nil, fmt.Errorf("模块包无法打开: %w", err)
	}
	found := map[string][]byte{}
	for _, file := range reader.File {
		name := path.Base(file.Name)
		if name != jsModuleManifestFile && name != jsModuleEntryFile {
			return nil, nil, fmt.Errorf("模块包含多余文件: %s", file.Name)
		}
		if _, exists := found[name]; exists {
			return nil, nil, fmt.Errorf("模块包含重复文件: %s", name)
		}
		data, readErr := readPackageFile(file)
		if readErr != nil {
			return nil, nil, readErr
		}
		found[name] = data
	}
	manifest, ok := found[jsModuleManifestFile]
	if !ok {
		return nil, nil, fmt.Errorf("模块缺少 %s", jsModuleManifestFile)
	}
	code, ok = found[jsModuleEntryFile]
	if !ok {
		return nil, nil, fmt.Errorf("模块缺少 %s", jsModuleEntryFile)
	}
	return manifest, code, nil
}

// readPackageFile 限量读取 zip 内的一个文件。
func readPackageFile(file *zip.File) ([]byte, error) {
	if file.UncompressedSize64 > jsModuleEntryBytes {
		return nil, fmt.Errorf("模块文件过大: %s", file.Name)
	}
	reader, err := file.Open()
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	data, err := io.ReadAll(io.LimitReader(reader, jsModuleEntryBytes))
	if err != nil {
		return nil, err
	}
	return data, nil
}

// parseJSModule 解析并校验清单，返回归一后的模块清单。
func parseJSModule(manifest, code []byte) (JSModuleManifest, error) {
	if len(manifest) > jsModuleManifestBytes {
		return JSModuleManifest{}, fmt.Errorf("%s 超过 %d KB", jsModuleManifestFile, jsModuleManifestBytes>>10)
	}
	var parsed JSModuleManifest
	if err := json.Unmarshal(manifest, &parsed); err != nil {
		return JSModuleManifest{}, fmt.Errorf("%s 无法解析：%w", jsModuleManifestFile, err)
	}
	parsed.normalize("")
	if err := parsed.validate(); err != nil {
		return JSModuleManifest{}, err
	}
	return parsed, nil
}
