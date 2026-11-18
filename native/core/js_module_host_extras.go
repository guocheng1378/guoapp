package core

// 上游模块（guoapp-modules）用到的 host 原语补充实现。
// 这些原语在早期红果单模块里未出现，14 个官方模块全量接入时需要：
//   - preserveIntegers：JSON 解析前保护 >2^53 的整数（goja 数字精度）。
//   - prepareWebMedia：网页型取流地址 → 核心 providerMedia（含 m3u8 抓取）。
//   - fetchPlaylist：抓 m3u8 返回 {playlist,url}。
//   - saveState/loadState：模块级持久化（token/站点池）落盘。
//   - preferredSite：宿主优选域名覆盖。
//   - log：调试日志（no-op 保留接口）。

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/dop251/goja"
)

// jsStatePath 返回模块状态文件绝对路径。状态按模块 id + key 隔离，
// 落在模块目录的 state 子目录（随模块数据一起备份/清理）。
func (runtime *jsModuleRuntime) jsStatePath(key string) (string, error) {
	key = strings.TrimSpace(key)
	if key == "" || strings.ContainsAny(key, `/\\..\x00`) {
		return "", errors.New("状态键无效")
	}
	root := jsModuleRootPath
	if root == "" {
		return "", errors.New("模块目录未初始化")
	}
	dir := filepath.Join(root, runtime.manifest.ID, "state")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return "", err
	}
	return filepath.Join(dir, key+".json"), nil
}

// jsSaveState 持久化模块状态字符串（空值即删除）。
func (runtime *jsModuleRuntime) jsSaveState(key, value string) error {
	path, err := runtime.jsStatePath(key)
	if err != nil {
		return err
	}
	if value == "" {
		if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
			return err
		}
		return nil
	}
	return os.WriteFile(path, []byte(value), 0o600)
}

// jsLoadState 读取模块状态字符串，缺失返回空串。
func (runtime *jsModuleRuntime) jsLoadState(key string) string {
	path, err := runtime.jsStatePath(key)
	if err != nil {
		return ""
	}
	raw, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	if len(raw) > 256<<10 {
		return ""
	}
	return string(raw)
}

// jsProviderMediaFromValue 把 JS 传来的 media 对象转成核心 providerMedia。
func jsProviderMediaFromValue(vm *goja.Runtime, value goja.Value, seen int) providerMedia {
	var out providerMedia
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) || seen > 8 {
		return out
	}
	obj := value.ToObject(vm)
	get := func(key string) string {
		v := obj.Get(key)
		if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
			return ""
		}
		return v.String()
	}
	out.URL = get("url")
	out.Referer = get("referer")
	out.Label = get("label")
	if duration := get("durationMs"); duration != "" {
		if ms, err := strconv.ParseInt(duration, 10, 64); err == nil {
			out.Duration = time.Duration(ms) * time.Millisecond
		}
	}
	if quality := get("quality"); quality != "" {
		if q, err := strconv.Atoi(quality); err == nil {
			out.Quality = q
		}
	}
	if creds := obj.Get("credentials"); creds != nil && !goja.IsUndefined(creds) && !goja.IsNull(creds) {
		cobj := creds.ToObject(vm)
		cget := func(key string) string {
			v := cobj.Get(key)
			if v == nil || goja.IsUndefined(v) || goja.IsNull(v) {
				return ""
			}
			return v.String()
		}
		out.credentials = &providerMediaCredentials{
			cookie:    cget("cookie"),
			origin:    cget("origin"),
			referer:   cget("referer"),
			userAgent: cget("userAgent"),
		}
	}
	if variants := obj.Get("variants"); variants != nil && !goja.IsUndefined(variants) && !goja.IsNull(variants) {
		if arr, ok := variants.Export().([]any); ok {
			for _, item := range arr {
				out.Variants = append(out.Variants, jsProviderMediaFromValue(vm, vm.ToValue(item), seen+1))
			}
		}
	}
	return out
}

// jsMediaMap 把核心 providerMedia 转成 JS 对象 map（与 resolveMedia 同构）。
func jsMediaMap(media providerMedia) map[string]any {
	obj := map[string]any{
		"url":        media.URL,
		"referer":    media.Referer,
		"playlist":   media.Playlist,
		"quality":    media.Quality,
		"durationMs": media.Duration.Milliseconds(),
	}
	if len(media.HLSKey) > 0 {
		obj["hlsKey"] = media.HLSKey
	}
	if len(media.CENCKey) > 0 {
		obj["cencKey"] = media.CENCKey
	}
	if len(media.Variants) > 0 {
		variants := make([]any, 0, len(media.Variants))
		for _, variant := range media.Variants {
			variants = append(variants, jsMediaMap(variant))
		}
		obj["variants"] = variants
	}
	return obj
}

// jsMediaValue 把核心 providerMedia 转成 JS 模块可消费的对象。
func jsMediaValue(vm *goja.Runtime, media providerMedia) goja.Value {
	return vm.ToValue(jsMediaMap(media))
}

// hostPrepareWebMedia：网页型模块取流统一出口。
func (runtime *jsModuleRuntime) hostPrepareWebMedia(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	media := jsProviderMediaFromValue(vm, call.Argument(0), 0)
	name := call.Argument(1).String()
	if name == "" {
		name = runtime.manifest.displayName()
	}
	prepared, err := runtime.downloader.prepareWebProviderMedia(runtime.parentContext(), media, name)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	return jsMediaValue(vm, prepared)
}

// hostFetchPlaylist：抓 m3u8，返回 {playlist,url}（url 为跟随重定向后的最终地址）。
func (runtime *jsModuleRuntime) hostFetchPlaylist(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	argument := call.Argument(0)
	address, referer := "", ""
	if obj, ok := argument.Export().(map[string]any); ok {
		address, _ = obj["url"].(string)
		referer, _ = obj["referer"].(string)
	} else {
		address = argument.String()
	}
	if address == "" {
		panic(vm.NewGoError(errors.New("fetchPlaylist 缺少 url")))
	}
	ctx := runtime.parentContext()
	if credsObj := argument.ToObject(vm).Get("credentials"); credsObj != nil && !goja.IsUndefined(credsObj) && !goja.IsNull(credsObj) {
		creds := jsProviderMediaFromValue(vm, vm.ToValue(map[string]any{"credentials": credsObj.Export()}), 0).credentials
		if creds != nil {
			ctx = providerMediaContext(ctx, creds)
		}
	}
	playlist, finalURL, err := runtime.downloader.fetchMediaPlaylist(ctx, address, referer)
	if err != nil {
		panic(vm.NewGoError(fmt.Errorf("获取播放列表失败: %w", err)))
	}
	return vm.ToValue(map[string]any{"playlist": playlist, "url": finalURL})
}

// hostPreferredSite：宿主优选域名（运营热更覆盖），未配置返回空串让模块用内置基址。
func (runtime *jsModuleRuntime) hostPreferredSite() string {
	if runtime.host == nil {
		return ""
	}
	return strings.TrimSpace(runtime.host.BaseURL(runtime.manifest.ID))
}

// hostLog：模块调试日志。生产静默，保留接口避免模块抛 "not a function"。
func (runtime *jsModuleRuntime) hostLog(call goja.FunctionCall) goja.Value {
	_ = call.Argument(0).String()
	return goja.Undefined()
}
