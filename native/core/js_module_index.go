package core

// 在线模块仓库（对齐上游 module_index.go）：
//
// 拉取顺序：自建源 → jsDelivr → raw.githubusercontent（任一源失败自动落下一源）。
// 索引里的 repo 字段只用于 GitHub 兜底链路；自建源按 {base}/{tag}/{文件名} 直取，
// 没有 gh/repo@tag 结构。sourceConfig.moduleIndexUrl 可把自建源置顶换域，
// 模块文件基址一并跟随（换源不发版）。
//
//	https://guoapp.dpdns.org/modules/index.json
//	https://cdn.jsdelivr.net/gh/guocheng1378/guoapp-modules@main/index.json
//	https://raw.githubusercontent.com/guocheng1378/guoapp-modules/main/index.json
//
// 索引条目声明每个模块的仓库与 tag，并给出 manifest.json/main.js 的 SHA256；
// 下载后逐文件校验，不符即拒绝安装。内置模块不在此列出（随安装包内置、
// 版本更高自动升级），商店里的内置条目由本地 bundled 清单合并而来。

import (
	"archive/zip"
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

const (
	jsModuleIndexFormat  = 1
	jsModuleIndexBytes   = 1 << 20
	jsModuleFetchTimeout = 20 * time.Second

	// 自建分发源：索引固定 index.json，模块文件按 {base}/{tag}/{文件名} 直取。
	jsModuleSelfHostedIndexURL = "https://guoapp.dpdns.org/modules/index.json"
	// %[2]s = tag、%[3]s = 文件名（第 1 个参数是 repo，自建链路忽略）。
	jsModuleSelfHostedFilePattern = "https://guoapp.dpdns.org/modules/%[2]s/%[3]s"
)

var (
	// 内置地址链：自建源优先，jsDelivr 与 raw 兜底。测试可直接替换这两个切片；
	// 生产链路由 effective* 函数叠加热更覆盖后返回（覆盖为空时原样返回）。
	jsModuleIndexAddresses = []string{
		jsModuleSelfHostedIndexURL,
		"https://cdn.jsdelivr.net/gh/guocheng1378/guoapp-modules@main/index.json",
		"https://raw.githubusercontent.com/guocheng1378/guoapp-modules/main/index.json",
	}
	jsModuleFileAddresses = []string{
		jsModuleSelfHostedFilePattern,
		"https://cdn.jsdelivr.net/gh/%s@%s/%s",
		"https://raw.githubusercontent.com/%s/%s/%s",
	}
	jsModuleIndexRepo = regexp.MustCompile(`^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$`)
	jsModuleIndexTag  = regexp.MustCompile(`^v\d+\.\d+\.\d+$`)
	jsModuleIndexHash = regexp.MustCompile(`^[0-9a-f]{64}$`)

	// sourceConfig.moduleIndexUrl 热更覆盖：索引地址与模块文件基址同域。
	// 互斥保护，避免 config.source 与 store/install 并发读写切片引用。
	jsModuleSourceMu      sync.RWMutex
	jsModuleIndexOverride string
	jsModuleFileOverride  string
)

// effectiveJSModuleIndexAddresses 返回生效的索引地址链：热更覆盖置顶（若有），
// 其后内置自建源 → jsDelivr → raw；重复地址去掉，避免同域连拉两次。
func effectiveJSModuleIndexAddresses() []string {
	jsModuleSourceMu.RLock()
	override := jsModuleIndexOverride
	jsModuleSourceMu.RUnlock()
	return jsModulePrepend(jsModuleIndexAddresses, override)
}

// effectiveJSModuleFileAddresses 返回生效的模块文件模板链，顺序与索引链一致
// （索引命中第 N 源后优先用第 N 源取文件，其余顺序兜底）。
func effectiveJSModuleFileAddresses() []string {
	jsModuleSourceMu.RLock()
	override := jsModuleFileOverride
	jsModuleSourceMu.RUnlock()
	return jsModulePrepend(jsModuleFileAddresses, override)
}

func jsModulePrepend(base []string, override string) []string {
	if override == "" {
		return base
	}
	out := make([]string, 0, len(base)+1)
	out = append(out, override)
	for _, addr := range base {
		if addr != override {
			out = append(out, addr)
		}
	}
	return out
}

// setJSModuleSourceURL 应用 sourceConfig.moduleIndexUrl（config.source 转发）。
// 空串 = 清空覆盖回落内置链（仅供测试复位，applySourceConfig 会先做 URL 校验）。
// 文件模板从索引 URL 的目录推导：https://x/p/index.json → https://x/p/%[2]s/%[3]s，
// 保证换域后索引与模块文件同源；repo 仅留给 GitHub 兜底。
func setJSModuleSourceURL(raw string) {
	text := strings.TrimSpace(raw)
	indexOverride, fileOverride := "", ""
	if text != "" {
		if parsed, err := url.Parse(text); err == nil &&
			(parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" {
			dir := strings.TrimSuffix(parsed.EscapedPath(), "/")
			if slash := strings.LastIndex(dir, "/"); slash >= 0 {
				dir = dir[:slash]
			}
			indexOverride = text
			fileOverride = parsed.Scheme + "://" + parsed.Host + dir + "/%[2]s/%[3]s"
		}
	}
	jsModuleSourceMu.Lock()
	jsModuleIndexOverride = indexOverride
	jsModuleFileOverride = fileOverride
	jsModuleSourceMu.Unlock()
}

// jsModuleSourceOverrides 返回当前热更覆盖值（诊断/测试用）。
func jsModuleSourceOverrides() (string, string) {
	jsModuleSourceMu.RLock()
	defer jsModuleSourceMu.RUnlock()
	return jsModuleIndexOverride, jsModuleFileOverride
}

// moduleIndexEntry 是在线商店里的一个模块条目。
type moduleIndexEntry struct {
	ID          string            `json:"id"`
	Name        string            `json:"name"`
	Version     string            `json:"version"`
	Description string            `json:"description"`
	API         int               `json:"api"`
	Adult       bool              `json:"adult"`
	// Category 与 manifest 同名字段：商店条目也要带分类，Dart 侧分组才有依据。
	Category    string            `json:"category,omitempty"`
	Repo        string            `json:"repo"`
	Tag         string            `json:"tag"`
	SHA256      map[string]string `json:"sha256"`
	Bundled     bool              `json:"bundled,omitempty"`
}

// usable 校验条目是否可用：接口版本匹配、标识合法、仓库与 tag 合法、校验和齐全。
func (entry moduleIndexEntry) usable() bool {
	return entry.API == jsModuleAPIVersion && jsModuleIDPattern.MatchString(entry.ID) &&
		strings.TrimSpace(entry.Name) != "" &&
		jsModuleIndexRepo.MatchString(entry.Repo) && jsModuleIndexTag.MatchString(entry.Tag) &&
		jsModuleIndexHash.MatchString(entry.SHA256[jsModuleManifestFile]) &&
		jsModuleIndexHash.MatchString(entry.SHA256[jsModuleEntryFile])
}

// parseModuleIndex 解析索引文件并过滤掉不可用条目。
func parseModuleIndex(raw []byte) ([]moduleIndexEntry, error) {
	var index struct {
		Format  int                `json:"format"`
		Modules []moduleIndexEntry `json:"modules"`
	}
	if err := json.Unmarshal(raw, &index); err != nil {
		return nil, errors.New("索引格式无效")
	}
	if index.Format != jsModuleIndexFormat {
		return nil, fmt.Errorf("索引格式为第 %d 版，请更新应用", index.Format)
	}
	entries := []moduleIndexEntry{}
	for _, entry := range index.Modules {
		if entry.usable() {
			entries = append(entries, entry)
		}
	}
	return entries, nil
}

// jsModuleIndex 拉取在线索引，返回条目与命中的地址序号。
func (engine *nativeEngine) jsModuleIndex(ctx context.Context) ([]moduleIndexEntry, int, error) {
	var failures []string
	for mirror, address := range effectiveJSModuleIndexAddresses() {
		raw, err := engine.fetchJSModuleResource(ctx, address, jsModuleIndexBytes)
		if err == nil {
			var entries []moduleIndexEntry
			if entries, err = parseModuleIndex(raw); err == nil {
				return entries, mirror, nil
			}
		}
		failures = append(failures, err.Error())
	}
	return nil, 0, fmt.Errorf("读取模块索引失败：%s", strings.Join(failures, "；"))
}

// jsModuleStore 返回在线商店条目：内置模块在前，联网条目在后；联网失败时仍返回内置项。
func (engine *nativeEngine) jsModuleStore(ctx context.Context) (map[string]any, error) {
	entries, _, err := engine.jsModuleIndex(ctx)
	bundled := bundledJSIndexEntries()
	if err != nil && len(bundled) == 0 {
		return nil, err
	}
	items := bundled
	for _, entry := range entries {
		if !isBundledJSModule(entry.ID) {
			items = append(items, entry)
		}
	}
	result := map[string]any{"items": items}
	if err != nil {
		result["warning"] = err.Error()
	}
	return result, nil
}

// isBundledJSModule 判断某 id 是否是内置模块。
func isBundledJSModule(id string) bool {
	modules, _ := readBundledJSModules()
	_, found := modules[id]
	return found
}

// indexedModulePackage 取某个在线模块的安装包字节（内置模块直接本地组包）。
func (engine *nativeEngine) indexedModulePackage(ctx context.Context, id string) ([]byte, error) {
	if modules, _ := readBundledJSModules(); modules[id].raw != nil {
		return zipJSModuleFiles(modules[id].raw, modules[id].code)
	}
	entries, mirror, err := engine.jsModuleIndex(ctx)
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.ID != id {
			continue
		}
		manifest, err := engine.fetchIndexedJSFile(ctx, entry, mirror, jsModuleManifestFile, jsModuleManifestBytes)
		if err != nil {
			return nil, err
		}
		code, err := engine.fetchIndexedJSFile(ctx, entry, mirror, jsModuleEntryFile, jsModuleEntryBytes)
		if err != nil {
			return nil, err
		}
		return zipJSModuleFiles(manifest, code)
	}
	return nil, fmt.Errorf("模块索引里没有 %s", id)
}

// fetchIndexedJSFile 下载并校验索引里的单个文件；sha256 校验逻辑不变，
// 任一源失败（含校验不符）自动落到下一源。
func (engine *nativeEngine) fetchIndexedJSFile(ctx context.Context, entry moduleIndexEntry, mirror int, name string, limit int) ([]byte, error) {
	var failures []string
	addresses := effectiveJSModuleFileAddresses()
	if len(addresses) == 0 {
		return nil, errors.New("没有可用的模块文件源")
	}
	for offset := range addresses {
		pattern := addresses[(mirror+offset)%len(addresses)]
		data, err := engine.fetchJSModuleResource(ctx, fmt.Sprintf(pattern, entry.Repo, entry.Tag, name), limit)
		if err == nil {
			sum := sha256.Sum256(data)
			if hex.EncodeToString(sum[:]) == entry.SHA256[name] {
				return data, nil
			}
			err = errors.New("文件校验不符")
		}
		failures = append(failures, err.Error())
	}
	return nil, fmt.Errorf("下载 %s 的 %s 失败：%s", entry.Name, name, strings.Join(failures, "；"))
}

// nativeJSModuleInstallAddress 从地址安装模块 zip（第三方模块分发直链，
// 不必上架索引）。与上游 2.0 的「从 zip 文件或地址安装」对齐。
func (engine *nativeEngine) nativeJSModuleInstallAddress(ctx context.Context, address string) (any, error) {
	address = strings.TrimSpace(address)
	if address == "" {
		return nil, errors.New("缺少模块地址")
	}
	parsed, err := url.Parse(address)
	if err != nil || parsed.Host == "" || (parsed.Scheme != "http" && parsed.Scheme != "https") {
		return nil, errors.New("模块地址无效")
	}
	root := filepath.Join(engine.directory, "modules")
	if err := os.MkdirAll(root, 0o700); err != nil {
		return nil, err
	}
	jsModuleRootPath = root
	raw, err := engine.fetchJSModuleResource(ctx, address, jsModulePackageBytes)
	if err != nil {
		return nil, err
	}
	installed, err := installJSModulePackage(raw)
	if err != nil {
		return nil, err
	}
	// 从地址安装等于重新装回：清掉「已卸载」记忆。
	if err := markBundledJSModuleRemoved(root, installed, false); err != nil {
		return nil, err
	}
	if err := reloadJSModule(engine.downloader, root, installed); err != nil {
		return nil, err
	}
	return map[string]any{"id": installed, "installed": true}, nil
}

// fetchJSModuleResource 限量下载一个资源。
func (engine *nativeEngine) fetchJSModuleResource(ctx context.Context, address string, limit int) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, jsModuleFetchTimeout)
	defer cancel()
	return engine.fetchLimited(ctx, address, limit)
}

// fetchLimited 限量下载一个地址的内容。
func (engine *nativeEngine) fetchLimited(ctx context.Context, address string, limit int) ([]byte, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	response, err := engine.downloader.client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", response.StatusCode)
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, int64(limit)+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > limit {
		return nil, fmt.Errorf("文件超过 %d KB", limit>>10)
	}
	return raw, nil
}

// zipJSModuleFiles 把清单与脚本打成模块安装包。
func zipJSModuleFiles(manifest, code []byte) ([]byte, error) {
	var buffer bytes.Buffer
	archive := zip.NewWriter(&buffer)
	for _, file := range []struct {
		name string
		data []byte
	}{{jsModuleManifestFile, manifest}, {jsModuleEntryFile, code}} {
		writer, err := archive.Create(file.name)
		if err != nil {
			return nil, err
		}
		if _, err := writer.Write(file.data); err != nil {
			return nil, err
		}
	}
	if err := archive.Close(); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}
