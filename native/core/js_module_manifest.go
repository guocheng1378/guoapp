package core

// 站源模块清单（manifest）——与上游（Xanerix/guoapp 2.x）模块包格式对齐。
//
// 模块包结构：
//
//	<id>/manifest.json   清单：id/name/version/api/runtime/hosts/...
//	<id>/main.js        入口脚本，导出 categories/catalogPage/detail/search/resolveMedia
//
// 早期本项目用过 module.json，这里两种文件名都认，方便存量 zip 包继续安装。

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

const (
	// jsModuleAPIVersion 是本运行时支持的模块接口版本，与上游一致。
	jsModuleAPIVersion = 1
	// jsModuleRuntimeJS 是当前唯一支持的模块运行时。
	jsModuleRuntimeJS = "js"
	// jsModuleManifestFile 是上游模块包的清单文件名。
	jsModuleManifestFile = "manifest.json"
	// jsModuleLegacyManifestFile 是本项目早期模块包的清单文件名（兼容读取）。
	jsModuleLegacyManifestFile = "module.json"
	// jsModuleEntryFile 是模块入口脚本文件名。
	jsModuleEntryFile = "main.js"
	// jsModuleManifestBytes / jsModuleEntryBytes 是清单与脚本的体积上限。
	jsModuleManifestBytes = 64 << 10
	jsModuleEntryBytes    = 4 << 20
	// jsModulePackageBytes 是模块 zip 包的体积上限（与 Dart 侧安装校验同口径）。
	jsModulePackageBytes = 8 << 20
)

// jsModuleIDPattern 约束模块标识：只允许小写字母、数字、下划线与连字符，最长 32 位。
var jsModuleIDPattern = regexp.MustCompile(`^[a-z0-9][a-z0-9_-]{0,31}$`)

// JSModuleRanking 是模块声明的榜单（上游 ModuleRanking）。
type JSModuleRanking struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Description string `json:"description"`
}

// JSModuleManifest 是一个模块包的清单。
type JSModuleManifest struct {
	ID          string `json:"id"`
	Name        string `json:"name"`
	Version     string `json:"version"`
	Description string `json:"description"`

	// API 是模块接口版本，必须等于 jsModuleAPIVersion。
	API int `json:"api"`
	// Runtime 是模块运行时，当前只支持 "js"。
	Runtime string `json:"runtime"`

	Hosts        []string `json:"hosts"`
	HostSuffixes []string `json:"hostSuffixes"`
	Capabilities []string `json:"capabilities"`
	// Adult 声明模块是否属于限制级站源。
	Adult *bool `json:"adult"`

	Main     string `json:"main"`
	Category string `json:"category"`
	Base     string `json:"base"`
	// BaseURL 是上游字段名（baseUrl），与 Base 等价，二者取其一。
	BaseURL string `json:"baseUrl"`
	Referer string `json:"referer"`

	Aliases   []string `json:"aliases"`
	Group     string   `json:"group"`
	GroupName string   `json:"groupName"`
	EntryName string   `json:"entryName"`
	// SkipVIPPrompt 跳过播放前的 VIP 确认弹窗（上游同名字段）。
	SkipVIPPrompt bool `json:"skipVipPrompt"`
	// Rankings 让模块自己声明榜单（上游 ModuleRanking）：商店与榜单页据此展示。
	Rankings []JSModuleRanking `json:"rankings,omitempty"`
	// MediaAuthPaths 是模块要签发的媒体路径前缀（mediaAuth 能力）：媒体请求的
	// 路径命中任一前缀时由模块给出额外请求头；须与 capabilities 的 mediaAuth 同时声明。
	MediaAuthPaths []string `json:"mediaAuthPaths,omitempty"`

	// RequiresAllSources 声明该源只在全源变体（真果鉴）里出现。
	RequiresAllSources bool `json:"requiresAllSources"`
	// DisableSearch / DisablePaging 关闭模块的搜索与分页能力（默认开启）。
	DisableSearch bool `json:"disableSearch"`
	DisablePaging bool `json:"disablePaging"`
	// AllowEmptyCatalog 允许目录为空（上游同名字段）。
	AllowEmptyCatalog bool `json:"allowEmptyCatalog"`
	// Implementation 指向内置共享实现（bundled/impl/<name>.js），
	// 用于「一份实现 + 多站点清单」的模块族。
	Implementation string `json:"implementation"`
	// Config 是模块自定义参数（模块族用它承载站点差异：基址、type_id 等）。
	Config map[string]any `json:"config,omitempty"`
}

// mainFile 返回模块入口脚本文件名。
func (manifest JSModuleManifest) mainFile() string {
	if strings.TrimSpace(manifest.Main) != "" {
		return strings.TrimSpace(manifest.Main)
	}
	return jsModuleEntryFile
}

// displayName 返回模块展示名。
func (manifest JSModuleManifest) displayName() string {
	if strings.TrimSpace(manifest.Name) != "" {
		return manifest.Name
	}
	return manifest.ID
}

// baseURL 返回模块请求基址。
func (manifest JSModuleManifest) baseURL() string {
	if base := strings.TrimSpace(manifest.Base); base != "" {
		return base
	}
	return strings.TrimSpace(manifest.BaseURL)
}

// adult 返回模块是否限制级。
func (manifest JSModuleManifest) adult() bool {
	return manifest.Adult != nil && *manifest.Adult
}

// capability 报告模块是否声明了某项能力。
func (manifest JSModuleManifest) capability(name string) bool {
	for _, item := range manifest.Capabilities {
		if strings.EqualFold(strings.TrimSpace(item), name) {
			return true
		}
	}
	return false
}

// validate 校验清单。规则对齐上游：标识受限、接口版本必须匹配、运行时只支持 js。
func (manifest JSModuleManifest) validate() error {
	if !jsModuleIDPattern.MatchString(manifest.ID) {
		return errors.New("模块标识只能用小写字母、数字、下划线和连字符，最长 32 个字符")
	}
	if strings.TrimSpace(manifest.Name) == "" {
		return errors.New("模块缺少名称")
	}
	if manifest.API != 0 && manifest.API != jsModuleAPIVersion {
		return fmt.Errorf("模块接口版本为 %d，当前应用支持 %d", manifest.API, jsModuleAPIVersion)
	}
	if runtime := strings.TrimSpace(manifest.Runtime); runtime != "" && runtime != jsModuleRuntimeJS {
		return fmt.Errorf("不支持的模块运行时 %q", runtime)
	}
	return nil
}

// normalize 补齐清单的派生字段（标识为空时以目录名兜底）。
func (manifest *JSModuleManifest) normalize(id string) {
	manifest.ID = strings.TrimSpace(manifest.ID)
	if manifest.ID == "" {
		manifest.ID = strings.TrimSpace(id)
	}
	if manifest.API == 0 {
		manifest.API = jsModuleAPIVersion
	}
	if strings.TrimSpace(manifest.Runtime) == "" {
		manifest.Runtime = jsModuleRuntimeJS
	}
	if manifest.Adult == nil {
		adult := false
		manifest.Adult = &adult
	}
}

// readJSModuleManifestFile 读取一个模块目录里的清单，返回清单与原始字节。
// 优先 manifest.json（上游格式），回退 module.json（本项目早期格式）。
func readJSModuleManifestFile(dir string) (JSModuleManifest, []byte, error) {
	var manifest JSModuleManifest
	candidates := []string{jsModuleManifestFile, jsModuleLegacyManifestFile}
	var lastErr error
	for _, name := range candidates {
		path := filepath.Join(dir, name)
		data, err := os.ReadFile(path)
		if err != nil {
			lastErr = err
			continue
		}
		if len(data) > jsModuleManifestBytes {
			return manifest, nil, fmt.Errorf("%s 超过 %d KB", name, jsModuleManifestBytes>>10)
		}
		if err := json.Unmarshal(data, &manifest); err != nil {
			return manifest, nil, fmt.Errorf("%s 无法解析：%w", name, err)
		}
		return manifest, data, nil
	}
	if lastErr == nil {
		lastErr = errors.New("模块包缺少清单")
	}
	return manifest, nil, lastErr
}
