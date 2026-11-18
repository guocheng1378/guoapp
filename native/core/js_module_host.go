package core

// 站源 JS 模块的 host 原语（工具类部分）。
//
// 与上游（Xanerix/guoapp 2.x）的形状保持一致：模块脚本里通过全局 host 取用。
// 这里放的是"纯计算/纯本地"的能力：保真整数、HTML 解析、地址解析、加密、
// 缓存与预约。涉及网络的能力在 js_module.go 里（fetch / fetchText）。

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ecdh"
	"crypto/hkdf"
	"crypto/rand"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

const (
	// moduleCacheEntries 单模块共享缓存的最大条目数。
	moduleCacheEntries = 512
	// moduleCacheValueBytes 单条缓存的最大字节数。
	moduleCacheValueBytes = 1 << 20
	// moduleRandomBytes randomBytes 的上限。
	moduleRandomBytes = 1024
	// moduleDerivedBytes HKDF 派生字节数的上限。
	moduleDerivedBytes = 1024
	// moduleHTMLBytes parseHtml 的输入上限。
	moduleHTMLBytes = 8 << 20
	// moduleReserveTTL 预约票据的有效期：超时未消费即作废。
	moduleReserveTTL = 30 * time.Second
)

// jsModuleCacheEntry 是共享缓存的一条记录（带过期时间）。
type jsModuleCacheEntry struct {
	value   string
	expires time.Time
}

// preserveIntegers 把超过 2^53 的整数字面量改成字符串，避免 JS 侧精度丢失。
// 站点返回的剧集 ID、签名串常有 19 位数字，JSON.parse 后会被截断。
func preserveIntegers(text string) string {
	var out strings.Builder
	out.Grow(len(text) + 64)
	inString, escaped := false, false
	for index := 0; index < len(text); {
		char := text[index]
		switch {
		case inString:
			if escaped {
				escaped = false
			} else if char == '\\' {
				escaped = true
			} else if char == '"' {
				inString = false
			}
		case char == '"':
			inString = true
		case char == '-' || char >= '0' && char <= '9':
			end := index + 1
			for end < len(text) && strings.IndexByte("0123456789+-.eE", text[end]) >= 0 {
				end++
			}
			token := text[index:end]
			value, err := strconv.ParseInt(token, 10, 64)
			if !strings.ContainsAny(token, ".eE+") && (err != nil || value > 1<<53-1 || value < -(1<<53-1)) {
				out.WriteByte('"')
				out.WriteString(token)
				out.WriteByte('"')
			} else {
				out.WriteString(token)
			}
			index = end
			continue
		}
		out.WriteByte(char)
		index++
	}
	return out.String()
}

// moduleHTMLTree 把 html.Node 转成 JS 侧可遍历的树（键名与 JSON 形态一致）。
func moduleHTMLTree(node *html.Node) map[string]any {
	result := map[string]any{}
	switch node.Type {
	case html.TextNode:
		result["text"] = node.Data
		return result
	case html.ElementNode:
		result["tag"] = node.Data
		if len(node.Attr) > 0 {
			attrs := make(map[string]string, len(node.Attr))
			for _, attribute := range node.Attr {
				attrs[attribute.Key] = attribute.Val
			}
			result["attrs"] = attrs
		}
	}
	children := []any{}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		if child.Type == html.TextNode || child.Type == html.ElementNode {
			children = append(children, moduleHTMLTree(child))
		}
	}
	if len(children) > 0 {
		result["children"] = children
	}
	return result
}

// hostParseHtml 解析 HTML，返回节点树。
func (runtime *jsModuleRuntime) hostParseHtml(call goja.FunctionCall) goja.Value {
	text := jsArgString(call.Arguments, 0)
	if len(text) > moduleHTMLBytes {
		panic(runtime.vm.NewGoError(errors.New("网页内容过大")))
	}
	document, err := html.Parse(strings.NewReader(text))
	if err != nil {
		panic(runtime.vm.NewGoError(errors.New("网页无法解析")))
	}
	return runtime.vm.ToValue(moduleHTMLTree(document))
}

// hostResolveUrl 以 base 为基准解析相对地址。
func (runtime *jsModuleRuntime) hostResolveUrl(call goja.FunctionCall) goja.Value {
	baseURL, err := url.Parse(jsArgString(call.Arguments, 0))
	if err != nil {
		panic(runtime.vm.NewGoError(errors.New("地址无效")))
	}
	refURL, err := url.Parse(jsArgString(call.Arguments, 1))
	if err != nil {
		panic(runtime.vm.NewGoError(errors.New("地址无效")))
	}
	return runtime.vm.ToValue(baseURL.ResolveReference(refURL).String())
}

// moduleCBC 校验 AES-CBC 的密钥、向量与数据长度。
func moduleCBC(key, iv, data []byte) (cipher.Block, []byte, []byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, nil, errors.New("AES 密钥长度无效")
	}
	if len(iv) != aes.BlockSize || len(data)%aes.BlockSize != 0 {
		return nil, nil, nil, errors.New("AES 向量或数据长度无效")
	}
	return block, iv, data, nil
}

// moduleGCM 校验 AES-GCM 的密钥与随机数长度。
func moduleGCM(key, nonce []byte) (cipher.AEAD, []byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, nil, errors.New("AES 密钥长度无效")
	}
	aead, err := cipher.NewGCM(block)
	if err != nil {
		return nil, nil, err
	}
	if len(nonce) != aead.NonceSize() {
		return nil, nil, errors.New("AES-GCM 随机数长度无效")
	}
	return aead, nonce, nil
}

// hostAESGCMSeal 用 AES-GCM 加密（extra 作为附加认证数据）。
func (runtime *jsModuleRuntime) hostAESGCMSeal(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	aead, vector, err := moduleGCM(jsBytes(vm, call.Argument(0)), jsBytes(vm, call.Argument(1)))
	if err != nil {
		panic(vm.NewGoError(err))
	}
	sealed := aead.Seal(nil, vector, jsBytes(vm, call.Argument(2)), jsBytes(vm, call.Argument(3)))
	return vm.ToValue(sealed)
}

// hostAESGCMOpen 解开 AES-GCM 密文。
func (runtime *jsModuleRuntime) hostAESGCMOpen(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	aead, vector, err := moduleGCM(jsBytes(vm, call.Argument(0)), jsBytes(vm, call.Argument(1)))
	if err != nil {
		panic(vm.NewGoError(err))
	}
	plain, err := aead.Open(nil, vector, jsBytes(vm, call.Argument(2)), jsBytes(vm, call.Argument(3)))
	if err != nil {
		panic(vm.NewGoError(errors.New("AES-GCM 校验失败")))
	}
	return vm.ToValue(plain)
}

// hostECDHKeyPair 生成一对 ECDH P-256 密钥。
func (runtime *jsModuleRuntime) hostECDHKeyPair(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	private, err := ecdh.P256().GenerateKey(rand.Reader)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	pair := vm.NewObject()
	_ = pair.Set("privateKey", vm.ToValue(private.Bytes()))
	_ = pair.Set("publicKey", vm.ToValue(private.PublicKey().Bytes()))
	return pair
}

// hostECDH 用私钥与对端公钥协商共享密钥。
func (runtime *jsModuleRuntime) hostECDH(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	private, err := ecdh.P256().NewPrivateKey(jsBytes(vm, call.Argument(0)))
	if err != nil {
		panic(vm.NewGoError(errors.New("ECDH 私钥无效")))
	}
	public, err := ecdh.P256().NewPublicKey(jsBytes(vm, call.Argument(1)))
	if err != nil {
		panic(vm.NewGoError(errors.New("ECDH 公钥无效")))
	}
	secret, err := private.ECDH(public)
	if err != nil {
		panic(vm.NewGoError(errors.New("ECDH 协商失败")))
	}
	return vm.ToValue(secret)
}

// hostHKDF 用 HKDF-SHA256 派生密钥。
func (runtime *jsModuleRuntime) hostHKDF(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	length := int(jsArgInt(call.Arguments, 3, 0))
	if length < 1 || length > moduleDerivedBytes {
		panic(vm.NewGoError(errors.New("HKDF 长度无效")))
	}
	key, err := hkdf.Key(sha256.New, jsBytes(vm, call.Argument(0)), jsBytes(vm, call.Argument(1)), string(jsBytes(vm, call.Argument(2))), length)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	return vm.ToValue(key)
}

// cacheGet 取共享缓存；过期即视为未命中。
func (runtime *jsModuleRuntime) cacheGet(key string) (string, bool) {
	runtime.cacheMu.Lock()
	defer runtime.cacheMu.Unlock()
	entry, found := runtime.caches[key]
	if !found {
		return "", false
	}
	if !entry.expires.IsZero() && !time.Now().Before(entry.expires) {
		delete(runtime.caches, key)
		return "", false
	}
	return entry.value, true
}

// cacheSet 写共享缓存；ttl 为毫秒，0 表示不过期。超出上限时报错。
func (runtime *jsModuleRuntime) cacheSet(key, value string, ttl time.Duration) error {
	runtime.cacheMu.Lock()
	defer runtime.cacheMu.Unlock()
	if value == "" {
		delete(runtime.caches, key)
		return nil
	}
	if len(value) > moduleCacheValueBytes {
		return errors.New("缓存内容过大")
	}
	if _, found := runtime.caches[key]; !found && len(runtime.caches) >= moduleCacheEntries {
		now := time.Now()
		for name, entry := range runtime.caches {
			if !entry.expires.IsZero() && !now.Before(entry.expires) {
				delete(runtime.caches, name)
			}
		}
		for name, entry := range runtime.caches {
			if len(runtime.caches) < moduleCacheEntries {
				break
			}
			if !entry.expires.IsZero() {
				delete(runtime.caches, name)
			}
		}
		if len(runtime.caches) >= moduleCacheEntries {
			return errors.New("不过期的缓存项过多")
		}
	}
	entry := jsModuleCacheEntry{value: value}
	if ttl > 0 {
		entry.expires = time.Now().Add(ttl)
	}
	runtime.caches[key] = entry
	return nil
}

// reserve 预约一次请求：按 lane（缺省用域名）记账并返回票据号。
//
// 与上游的差别：上游把预约名额交给宿主统一限流；这里的请求本身已经过核心
// 限流器（fetch 走 doPreparedCatalogRequest），预约只用于让模块能声明
// "这一批请求属于同一条车道"，并在实际发请求时消费掉票据，避免同车道并发。
func (runtime *jsModuleRuntime) reserve(address, lane string) uint64 {
	if strings.TrimSpace(lane) == "" {
		lane = jsModuleLaneOf(address)
	}
	runtime.reserveMu.Lock()
	defer runtime.reserveMu.Unlock()
	now := time.Now()
	for name, entry := range runtime.reservations {
		if now.After(entry.expires) {
			delete(runtime.reservations, name)
		}
	}
	entry := runtime.reservations[lane]
	if entry.count == 0 {
		entry.expires = now.Add(moduleReserveTTL)
	}
	entry.count++
	runtime.reservations[lane] = entry
	runtime.reserveTicket++
	return runtime.reserveTicket
}

// consumeReservation 消费一张预约票据：请求的域名属于被预约的车道时记一次。
func (runtime *jsModuleRuntime) consumeReservation(address string) {
	lane := jsModuleLaneOf(address)
	runtime.reserveMu.Lock()
	defer runtime.reserveMu.Unlock()
	entry, found := runtime.reservations[lane]
	if !found || entry.count <= 0 {
		return
	}
	entry.count--
	if entry.count <= 0 {
		delete(runtime.reservations, lane)
		return
	}
	runtime.reservations[lane] = entry
}

// jsModuleLaneOf 取请求的车道名：域名。
func jsModuleLaneOf(address string) string {
	parsed, err := url.Parse(strings.TrimSpace(address))
	if err != nil || parsed.Host == "" {
		return strings.TrimSpace(address)
	}
	return parsed.Host
}

// hostCatalogContext 告诉模块本次调用处于什么上下文：是否分页续取、是否后台。
func (runtime *jsModuleRuntime) hostCatalogContext() map[string]any {
	more, _ := runtime.ctx.Value(libraryMoreKey{}).(bool)
	background, _ := runtime.ctx.Value(backgroundCatalogKey{}).(bool)
	return map[string]any{"more": more, "background": background}
}

// hostIsKnown 报告剧集是否已在库（模块据此跳过已入库的条目）。
func (runtime *jsModuleRuntime) hostIsKnown(id string) bool {
	known, _ := runtime.ctx.Value(libraryKnownKey{}).(map[string]bool)
	return known[id]
}

// hostReportProgress 让模块上报抓取进度（写进剧库进度）。
func (runtime *jsModuleRuntime) hostReportProgress(items goja.Value) {
	var dramas []Drama
	raw, err := json.Marshal(items.Export())
	if err != nil {
		return
	}
	if json.Unmarshal(raw, &dramas) != nil {
		return
	}
	reportLibraryProgress(runtime.ctx, runtime.manifest.ID, dramas, nil, false)
}
