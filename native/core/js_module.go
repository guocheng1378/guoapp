package core

// 站源 JS 模块运行时（最小闭环）。
//
// 目标：站源不再编译进本体，而是运行时从数据目录加载 JS 模块，改源只需换
// 模块文件、不必重新发版。模块格式与上游（Xanerix/guoapp 2.x）保持一致：
//
//	<moduleRoot>/<id>/module.json   { id, name, version, hosts, capabilities, adult, main }
//	<moduleRoot>/<id>/main.js       导出 categories/catalogPage/detail/search/resolveMedia
//
// host 原语沿用上游的调用形状（retries()/maxPages() 是函数、fetchText 收对象）。

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/dop251/goja"

	"duanjuapp/native/provider"
)

// jsModuleRuntime 是一个模块实例：goja 运行时 + 导出对象 + host 原语。
// goja 运行时不是并发安全的，call 用 callMu 串行化。
type jsModuleRuntime struct {
	vm         *goja.Runtime
	exports    *goja.Object
	manifest   JSModuleManifest
	downloader *Downloader

	// host 是本次调用的宿主（提供优选域名等运行时覆盖）。模块自己发请求时
	// 通过 host.baseUrl() 取当前生效的基址，与内置 provider 行为一致。
	host provider.Host
	// ctx 是本次调用的上下文：模块发请求时以它为父上下文，
	// 后台预取标记（冷却表隔离）才不会丢。
	ctx context.Context

	callMu      sync.Mutex
	exclusiveMu sync.Mutex
	cacheMu     sync.Mutex
	caches      map[string]jsModuleCacheEntry

	// reserveMu 保护预约票据表；reserveTicket 是单调递增的票据号。
	reserveMu     sync.Mutex
	reservations  map[string]jsModuleReservation
	reserveTicket uint64
}

// jsModuleReservation 记录某条车道（域名）的预约票据数。
type jsModuleReservation struct {
	count   int
	expires time.Time
}

// baseURL 返回当前生效的基址：宿主覆盖优先，清单兜底。
func (runtime *jsModuleRuntime) baseURL() string {
	if runtime.host != nil {
		if base := strings.TrimSpace(runtime.host.BaseURL(runtime.manifest.ID)); base != "" {
			return base
		}
	}
	return runtime.manifest.baseURL()
}

// parentContext 返回本次调用的父上下文（没有则用 Background）。
func (runtime *jsModuleRuntime) parentContext() context.Context {
	if runtime.ctx != nil {
		return runtime.ctx
	}
	return context.Background()
}

func newJSModuleRuntime(d *Downloader, manifest JSModuleManifest, script string) (*jsModuleRuntime, error) {
	runtime := &jsModuleRuntime{
		vm:           goja.New(),
		manifest:     manifest,
		downloader:   d,
		caches:       map[string]jsModuleCacheEntry{},
		reservations: map[string]jsModuleReservation{},
	}
	if err := runtime.vm.Set("host", runtime.hostObject()); err != nil {
		return nil, err
	}
	wrapped := "(function(){var module={exports:{}};(function(module,exports){\n" + script +
		"\n})(module,module.exports);return module.exports;})()"
	value, err := runtime.vm.RunString(wrapped)
	if err != nil {
		return nil, fmt.Errorf("模块 %s 加载失败: %w", manifest.ID, err)
	}
	runtime.exports = value.ToObject(runtime.vm)
	return runtime, nil
}

func jsBytes(vm *goja.Runtime, value goja.Value) []byte {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	switch exported := value.Export().(type) {
	case []byte:
		return exported
	case goja.ArrayBuffer:
		return exported.Bytes()
	case string:
		return []byte(exported)
	}
	object := value.ToObject(vm)
	length := int(object.Get("length").ToInteger())
	out := make([]byte, length)
	for index := 0; index < length; index++ {
		out[index] = byte(object.Get(strconv.Itoa(index)).ToInteger())
	}
	return out
}

func jsArgString(args []goja.Value, index int) string {
	if index >= len(args) || args[index] == nil || goja.IsUndefined(args[index]) || goja.IsNull(args[index]) {
		return ""
	}
	return args[index].String()
}

func jsArgInt(args []goja.Value, index int, fallback int64) int64 {
	if index >= len(args) || args[index] == nil || goja.IsUndefined(args[index]) {
		return fallback
	}
	return args[index].ToInteger()
}

// decodeModuleBase64 解码模块传入的 base64 字符串。
// Go 的 base64.StdEncoding.DecodeString 对无 padding 的输入不会报错，而是
// 解出被截断的字节（43 字符解出 63 字节）——黄果 AI 的 edge 握手把 65 字节
// P-256 公钥 base64url 无 padding 下发，模块 base64UrlDecode 先做了 -/ _→+/ /
// 替换但没补 padding，旧实现据此解出残缺公钥，ECDH 协商失败→握手失败→
// 「有目录、点播放没画面」。这里统一补齐 padding，并兼容 url-safe 字符，
// 对已有标准 base64（含 padding）调用无副作用。
func decodeModuleBase64(text string) ([]byte, error) {
	text = strings.TrimSpace(text)
	if text == "" {
		return []byte{}, nil
	}
	text = strings.ReplaceAll(text, "-", "+")
	text = strings.ReplaceAll(text, "_", "/")
	switch remainder := len(text) % 4; remainder {
	case 0:
	case 2:
		text += "=="
	case 3:
		text += "="
	default:
		return nil, errors.New("base64 长度无效")
	}
	return base64.StdEncoding.DecodeString(text)
}

func (runtime *jsModuleRuntime) hostObject() map[string]any {
	vm := runtime.vm
	values := func(data []byte) goja.Value { return vm.ToValue(data) }
	sourceID := runtime.manifest.ID
	return map[string]any{
		"source":   sourceID,
		"retries":  func() int { return 3 },
		"maxPages": func() int { return 50 },

		// baseUrl 返回当前生效的基址（宿主覆盖优先，清单兜底）。
		"baseUrl": func() string { return runtime.baseURL() },
		// manifest 暴露清单字段，模块族（一份实现多站点）靠它取站点参数。
		"manifest": func() goja.Value {
			payload := map[string]any{
				"id": runtime.manifest.ID, "name": runtime.manifest.displayName(),
				"version": runtime.manifest.Version, "base": runtime.manifest.baseURL(),
				"referer": runtime.manifest.Referer, "category": runtime.manifest.Category,
			}
			if runtime.manifest.Adult != nil {
				payload["adult"] = *runtime.manifest.Adult
			}
			if len(runtime.manifest.Config) > 0 {
				payload["config"] = runtime.manifest.Config
			}
			return vm.ToValue(payload)
		},

		"md5": func(call goja.FunctionCall) goja.Value {
			sum := md5.Sum(jsBytes(vm, call.Argument(0)))
			return values(sum[:])
		},
		"sha256": func(call goja.FunctionCall) goja.Value {
			sum := sha256.Sum256(jsBytes(vm, call.Argument(0)))
			return values(sum[:])
		},
		// hmacSha256(key, data) 输出 32 字节摘要。黄豆/真果·鉴等站点的请求签名
		// 依赖 HMAC-SHA256，host 直接提供，模块无需自己实现。
		"hmacSha256": func(call goja.FunctionCall) goja.Value {
			mac := hmac.New(sha256.New, jsBytes(vm, call.Argument(0)))
			_, _ = mac.Write(jsBytes(vm, call.Argument(1)))
			return values(mac.Sum(nil))
		},
		// gzipCompress / gzipDecompress 用标准 gzip。黄豆请求体压缩/响应解压依赖它。
		"gzipCompress": func(call goja.FunctionCall) goja.Value {
			compressed, err := jsGzipCompress(jsBytes(vm, call.Argument(0)))
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return values(compressed)
		},
		"gzipDecompress": func(call goja.FunctionCall) goja.Value {
			plain, err := jsGzipDecompress(jsBytes(vm, call.Argument(0)))
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return values(plain)
		},
		"hexEncode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(hex.EncodeToString(jsBytes(vm, call.Argument(0))))
		},
		"hexDecode": func(call goja.FunctionCall) goja.Value {
			decoded, _ := hex.DecodeString(strings.TrimSpace(jsArgString(call.Arguments, 0)))
			return values(decoded)
		},
		"base64Encode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(base64.StdEncoding.EncodeToString(jsBytes(vm, call.Argument(0))))
		},
		"base64Decode": func(call goja.FunctionCall) goja.Value {
			decoded, _ := decodeModuleBase64(jsArgString(call.Arguments, 0))
			return values(decoded)
		},
		"utf8Encode": func(call goja.FunctionCall) goja.Value {
			return values([]byte(jsArgString(call.Arguments, 0)))
		},
		"utf8Decode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(strings.ToValidUTF8(string(jsBytes(vm, call.Argument(0))), "�"))
		},
		"randomBytes": func(call goja.FunctionCall) goja.Value {
			size := int(jsArgInt(call.Arguments, 0, 16))
			if size < 0 || size > 1<<16 {
				size = 16
			}
			buf := make([]byte, size)
			_, _ = rand.Read(buf)
			return values(buf)
		},
		"aesCbcEncrypt": func(call goja.FunctionCall) goja.Value {
			return values(jsAESCBCEncrypt(jsBytes(vm, call.Argument(0)), jsBytes(vm, call.Argument(1)), jsBytes(vm, call.Argument(2))))
		},
		"aesCbcDecrypt": func(call goja.FunctionCall) goja.Value {
			return values(jsAESCBCDecrypt(jsBytes(vm, call.Argument(0)), jsBytes(vm, call.Argument(1)), jsBytes(vm, call.Argument(2))))
		},
		"isKnown": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(runtime.hostIsKnown(jsArgString(call.Arguments, 0)))
		},
		"preserveIntegers": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(preserveIntegers(jsArgString(call.Arguments, 0)))
		},
		"catalogContext": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(runtime.hostCatalogContext())
		},
		"reportProgress": func(call goja.FunctionCall) goja.Value {
			runtime.hostReportProgress(call.Argument(0))
			return goja.Undefined()
		},
		"reserve": func(call goja.FunctionCall) goja.Value {
			address := jsArgString(call.Arguments, 0)
			lane := ""
			if object := call.Argument(1); object != nil && !goja.IsUndefined(object) && !goja.IsNull(object) {
				lane = object.String()
			}
			return vm.ToValue(runtime.reserve(address, lane))
		},
		"finishMedia": func(call goja.FunctionCall) goja.Value { return call.Argument(0) },
		"parseHtml":   runtime.hostParseHtml,
		"resolveUrl":  runtime.hostResolveUrl,
		// 上游 guoapp-modules 官方模块用到的补充原语。
		"prepareWebMedia": runtime.hostPrepareWebMedia,
		"fetchPlaylist":   runtime.hostFetchPlaylist,
		"preferredSite":   runtime.hostPreferredSite,
		"log":             runtime.hostLog,
		"saveState": func(call goja.FunctionCall) goja.Value {
			if err := runtime.jsSaveState(jsArgString(call.Arguments, 0), jsArgString(call.Arguments, 1)); err != nil {
				panic(vm.NewGoError(err))
			}
			return goja.Undefined()
		},
		"loadState": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(runtime.jsLoadState(jsArgString(call.Arguments, 0)))
		},
		"aesGcmSeal":      runtime.hostAESGCMSeal,
		"aesGcmOpen":      runtime.hostAESGCMOpen,
		"ecdhP256KeyPair": runtime.hostECDHKeyPair,
		"ecdhP256":        runtime.hostECDH,
		"hkdfSha256":      runtime.hostHKDF,
		// chapterId 生成分集唯一标识，格式对齐 provider.ChapterID(source, sourceID, key)：
		// 模块 ID 作 source 前缀 + 传入的站点 ID + 分集 key，用 ":" 拼接。
		// 曾只取第一参数（站点 ID），导致同一剧所有分集 id 相同，被 uniqueChapters
		// 去重成 1 集（黄果 AI / 黄果视频 等在线模块「只有 1 集」根因）。
		// 第二参数传空串时保留尾冒号，供模块用 startsWith(prefix) 反查分集 key。
		"chapterId": func(call goja.FunctionCall) goja.Value {
			parts := make([]string, 0, len(call.Arguments)+1)
			parts = append(parts, sourceID)
			for _, argument := range call.Arguments {
				parts = append(parts, strings.TrimSpace(fmt.Sprintf("%v", argument.Export())))
			}
			return vm.ToValue(strings.Join(parts, ":"))
		},
		"dramaId": func(call goja.FunctionCall) goja.Value {
			id := strings.TrimSpace(jsArgString(call.Arguments, 0))
			if strings.Contains(id, ":") {
				return vm.ToValue(id)
			}
			return vm.ToValue(sourceID + ":" + id)
		},
		"parseUrl": func(call goja.FunctionCall) goja.Value {
			parsed, err := url.Parse(jsArgString(call.Arguments, 0))
			if err != nil {
				return vm.ToValue(map[string]any{})
			}
			return vm.ToValue(map[string]any{
				"scheme": parsed.Scheme, "host": parsed.Host, "hostname": parsed.Hostname(),
				"port": parsed.Port(), "path": parsed.Path, "query": parsed.RawQuery,
				"fragment": parsed.Fragment, "href": parsed.String(),
			})
		},
		"exclusive": func(call goja.FunctionCall) goja.Value {
			runtime.exclusiveMu.Lock()
			defer runtime.exclusiveMu.Unlock()
			fn, ok := goja.AssertFunction(call.Argument(0))
			if !ok {
				return goja.Undefined()
			}
			value, err := fn(goja.Undefined())
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return value
		},
		"cacheGet": func(call goja.FunctionCall) goja.Value {
			value, found := runtime.cacheGet(jsArgString(call.Arguments, 0))
			if !found {
				return goja.Null()
			}
			return vm.ToValue(value)
		},
		"cacheSet": func(call goja.FunctionCall) goja.Value {
			ttl := time.Duration(jsArgInt(call.Arguments, 2, 0)) * time.Millisecond
			value := ""
			if argument := call.Argument(1); argument != nil && !goja.IsUndefined(argument) && !goja.IsNull(argument) {
				value = argument.String()
			}
			if err := runtime.cacheSet(jsArgString(call.Arguments, 0), value, ttl); err != nil {
				panic(vm.NewGoError(err))
			}
			return goja.Undefined()
		},
		"sleep": func(call goja.FunctionCall) goja.Value {
			ms := jsArgInt(call.Arguments, 0, 0)
			if ms <= 0 {
				return goja.Undefined()
			}
			timer := time.NewTimer(time.Duration(ms) * time.Millisecond)
			defer timer.Stop()
			select {
			case <-timer.C:
			case <-runtime.parentContext().Done():
			}
			return goja.Undefined()
		},
		"fetch":     runtime.hostFetch,
		"fetchText": runtime.hostFetchText,
	}
}

func jsAESCBCEncrypt(key, iv, data []byte) []byte {
	block, err := aes.NewCipher(key)
	if err != nil || len(iv) != block.BlockSize() {
		return nil
	}
	padded := append([]byte{}, data...)
	if pad := block.BlockSize() - len(padded)%block.BlockSize(); pad > 0 {
		padded = append(padded, []byte(strings.Repeat(string(rune(pad)), pad))...)
	}
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(padded, padded)
	return padded
}

func jsAESCBCDecrypt(key, iv, data []byte) []byte {
	block, err := aes.NewCipher(key)
	if err != nil || len(iv) != block.BlockSize() || len(data)%block.BlockSize() != 0 || len(data) == 0 {
		return nil
	}
	out := append([]byte{}, data...)
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, out)
	if pad := int(out[len(out)-1]); pad > 0 && pad <= block.BlockSize() && pad <= len(out) {
		out = out[:len(out)-pad]
	}
	return out
}

// jsGzipCompress / jsGzipDecompress 为 JS 模块提供标准 gzip 能力，
// 供需要压缩请求体或解压响应的站点（如黄豆）使用。
func jsGzipCompress(data []byte) ([]byte, error) {
	var out bytes.Buffer
	writer := gzip.NewWriter(&out)
	if _, err := writer.Write(data); err != nil {
		_ = writer.Close()
		return nil, err
	}
	if err := writer.Close(); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func jsGzipDecompress(data []byte) ([]byte, error) {
	reader, err := gzip.NewReader(bytes.NewReader(data))
	if err != nil {
		return nil, err
	}
	defer reader.Close()
	return io.ReadAll(io.LimitReader(reader, 8<<20))
}

func (runtime *jsModuleRuntime) hostFetch(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	options := call.Argument(0).ToObject(vm)
	method := strings.ToUpper(strings.TrimSpace(jsModuleFieldText(options, "method")))
	if method == "" {
		method = http.MethodGet
	}
	address := jsModuleFieldText(options, "url")
	// body 用 jsBytes 抽取：Uint8Array/ArrayBuffer 走 goja 快路径零拷贝取原始
	// 字节，纯字符串按 UTF-8 转字节（与旧版 []byte(body) 逐字节一致）。
	body := jsBytes(vm, jsField(options, "body"))
	timeout := jsArgInt([]goja.Value{jsField(options, "timeoutMs")}, 0, 20000)
	if timeout <= 0 || timeout > 60000 {
		timeout = 20000
	}
	parent := runtime.ctx
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, time.Duration(timeout)*time.Millisecond)
	defer cancel()
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, address, reader)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	if headers := jsField(options, "headers"); headers != nil && !goja.IsUndefined(headers) && !goja.IsNull(headers) {
		headerObject := headers.ToObject(vm)
		for _, key := range headerObject.Keys() {
			request.Header.Set(key, headerObject.Get(key).String())
		}
	}
	if request.Header.Get("User-Agent") == "" {
		request.Header.Set("User-Agent", hongguoWebUserAgent)
	}
	// 走核心的目录请求管线：限流、429/403 冷却表与后台隔离与内置源一致。
	runtime.consumeReservation(address)
	response, err := runtime.downloader.doPreparedCatalogRequest(request, 0, nil)
	if err != nil {
		panic(vm.NewGoError(err))
	}
	defer response.Body.Close()
	content, _ := io.ReadAll(io.LimitReader(response.Body, 24<<20))
	headerMap := map[string]any{}
	for key, list := range response.Header {
		if len(list) > 0 {
			headerMap[key] = list[0]
		}
	}
	return vm.ToValue(map[string]any{"status": response.StatusCode, "body": string(content),
		"bodyBase64": base64.StdEncoding.EncodeToString(content), "headers": headerMap})
}

// hostFetchText 对应 JS 的 host.fetchText(options)。
//
// 基础形态（历史兼容）：{url, referer} → 固定 GET，返回 {body,url,status,headers}。
// 增强形态（在线模块全能力所需）：
//   - method/body： POST 信封（如黄果 AI 的 /api/edge/request），body 非空默认 POST。
//   - headers/userAgent/cookie/noCache：补齐其它模块一直在传、此前却被忽略的字段。
//   - mirrors：候选域名数组，按 path+query 换 host 逐个尝试，首个 2xx 即返回；
//     网络错误/5xx/404 换下一个（对齐 fetchProviderRequest 的镜像轮转语义）。
//
// 只传 url/referer 时行为与旧版完全一致（单请求 GET），老模块不受影响。
func (runtime *jsModuleRuntime) hostFetchText(call goja.FunctionCall) goja.Value {
	vm := runtime.vm
	argument := call.Argument(0)
	address, referer := "", ""
	method := ""
	var body []byte
	var userAgent, cookie string
	var noCache bool
	var mirrors []string
	var headers map[string]string
	if object, ok := argument.Export().(map[string]any); ok {
		address, _ = object["url"].(string)
		referer, _ = object["referer"].(string)
		method, _ = object["method"].(string)
		if raw, ok := object["body"]; ok && raw != nil {
			body = jsBytes(vm, vm.ToValue(raw))
		}
		userAgent, _ = object["userAgent"].(string)
		cookie, _ = object["cookie"].(string)
		noCache, _ = object["noCache"].(bool)
		if raw, ok := object["headers"].(map[string]any); ok {
			headers = make(map[string]string, len(raw))
			for key, value := range raw {
				if text, ok := value.(string); ok {
					headers[key] = text
				}
			}
		}
		if raw, ok := object["mirrors"].([]any); ok {
			for _, item := range raw {
				if text, ok := item.(string); ok && text != "" {
					mirrors = append(mirrors, text)
				}
			}
		}
	} else {
		address = jsArgString(call.Arguments, 0)
	}
	if address == "" {
		panic(vm.NewGoError(errors.New("fetchText 缺少 url")))
	}
	if method == "" {
		if len(body) > 0 {
			method = http.MethodPost
		} else {
			method = http.MethodGet
		}
	} else {
		method = strings.ToUpper(strings.TrimSpace(method))
	}
	if userAgent == "" {
		userAgent = hongguoWebUserAgent
	}

	// mirrors 按“换 host 不换 path/query”展开候选；无 mirrors 时用原 url 单发。
	candidates := []string{address}
	if len(mirrors) > 0 {
		candidates = make([]string, 0, len(mirrors))
		for _, mirror := range mirrors {
			if rewritten, ok := rewriteFetchTextURL(address, mirror); ok {
				candidates = append(candidates, rewritten)
			}
		}
		if len(candidates) == 0 {
			candidates = []string{address}
		}
	}

	var lastErr error
	for _, candidate := range candidates {
		var reader io.Reader
		if len(body) > 0 {
			reader = bytes.NewReader(body)
		}
		request, err := http.NewRequestWithContext(runtime.parentContext(), method, candidate, reader)
		if err != nil {
			lastErr = err
			continue
		}
		request.Header.Set("User-Agent", userAgent)
		// POST 信封（如黄果 AI 的 JSON envelope）默认按 application/json 发送；
		// 模块可用 headers.content-type 显式覆盖。不设会被服务端以 415 拒绝。
		if len(body) > 0 {
			request.Header.Set("Content-Type", "application/json")
		}
		if referer != "" {
			request.Header.Set("Referer", referer)
		}
		if cookie != "" {
			request.Header.Set("Cookie", cookie)
		}
		if noCache {
			request.Header.Set("Cache-Control", "no-cache")
		}
		for key, value := range headers {
			request.Header.Set(key, value)
		}
		// 多镜像轮转时给每个候选独立短超时，避免某个域 hang 住耗光整次调用；
		// 单请求维持原行为（timeout=0，交给 client 的全局超时）。
		perAttempt := time.Duration(0)
		if len(candidates) > 1 {
			perAttempt = 8 * time.Second
		}
		response, err := runtime.downloader.doPreparedCatalogRequest(request, perAttempt, nil)
		if err != nil {
			lastErr = err
			continue
		}
		content, _ := io.ReadAll(io.LimitReader(response.Body, 8<<20))
		status := response.StatusCode
		headerMap := map[string]any{}
		for key, list := range response.Header {
			if len(list) > 0 {
				headerMap[key] = list[0]
			}
		}
		response.Body.Close()
		result := vm.ToValue(map[string]any{"body": string(content), "bodyBase64": base64.StdEncoding.EncodeToString(content),
			"url": candidate, "status": status, "headers": headerMap})
		// 无 mirrors（单候选）时保持旧行为：任何状态码都返回 body，让模块自己按 body 判读。
		// 仅多镜像轮转时跳过非 2xx，换下一候选。
		if len(candidates) == 1 || (status >= 200 && status < 300) {
			return result
		}
		lastErr = fmt.Errorf("fetchText %s 返回 HTTP %d", candidate, status)
	}
	panic(vm.NewGoError(firstNonEmptyErr(lastErr, errors.New("fetchText 请求失败"))))
}

// rewriteFetchTextURL 把 address 的 host 换成 mirror（保留 path/query/fragment）。
// mirror 可以是根地址（https://host）或完整 URL；只取它的 scheme+host。
func rewriteFetchTextURL(address, mirror string) (string, bool) {
	target, err := url.Parse(address)
	if err != nil || target.Scheme == "" || target.Host == "" {
		return "", false
	}
	root, err := url.Parse(mirror)
	if err != nil || root.Host == "" {
		return "", false
	}
	scheme := root.Scheme
	if scheme == "" {
		scheme = target.Scheme
	}
	target.Scheme = scheme
	target.Host = root.Host
	return target.String(), true
}

func firstNonEmptyErr(err error, fallback error) error {
	if err != nil {
		return err
	}
	return fallback
}

func jsModuleFieldText(object *goja.Object, name string) string {
	if object == nil {
		return ""
	}
	return jsFieldString(object, name)
}

// call 按 JSON 传参调用模块导出的函数，并把返回值解码进 result。
// ctx 与 host 是本次调用的上下文与宿主：模块发请求时沿用它们，
// 后台预取标记（冷却表隔离）与优选域名才不会丢。
func (runtime *jsModuleRuntime) call(ctx context.Context, host provider.Host, function string, result any, args ...any) (err error) {
	runtime.callMu.Lock()
	defer runtime.callMu.Unlock()
	runtime.host = host
	runtime.ctx = ctx
	// 模块脚本里的 host 原语 panic 不应掀翻整个 App：转成普通错误。
	defer func() {
		if recovered := recover(); recovered != nil {
			err = fmt.Errorf("模块 %s 执行 %s 失败：%v", runtime.manifest.displayName(), function, recovered)
		}
	}()
	fn, ok := goja.AssertFunction(runtime.exports.Get(function))
	if !ok {
		return fmt.Errorf("模块 %s 未实现 %s", runtime.manifest.displayName(), function)
	}
	encoded, err := json.Marshal(args)
	if err != nil {
		return err
	}
	var decoded []any
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		return err
	}
	values := make([]goja.Value, len(decoded))
	for index, item := range decoded {
		values[index] = runtime.vm.ToValue(item)
	}
	value, err := fn(goja.Undefined(), values...)
	if err != nil {
		return err
	}
	if result == nil || value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	raw, err := json.Marshal(value.Export())
	if err != nil {
		return err
	}
	return json.Unmarshal(raw, result)
}

// hasExport 报告模块是否导出了某个函数。Provider 的可选接口（取流、分页搜索、
// 服务端排序）按导出情况装配：模块没导出 resolveMedia 时走核心通用的
// 「章节播放页解析」链路，而不是直接失败。
func (runtime *jsModuleRuntime) hasExport(name string) bool {
	runtime.callMu.Lock()
	defer runtime.callMu.Unlock()
	if runtime.exports == nil {
		return false
	}
	value := runtime.exports.Get(name)
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return false
	}
	_, ok := goja.AssertFunction(value)
	return ok
}
