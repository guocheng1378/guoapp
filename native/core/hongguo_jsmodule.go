package core

// 直接运行上游（Xanerix/guoapp 2.0.1+113）内嵌的红果 JS 源模块。
//
// 上游从 1.0.12 起把站源移出本体、改为运行时 JS 模块；其官方 APK 把模块
// 以明文嵌在 libduanju_core.so 的 bundled/hongguo 里。与其手工把上万行 JS
// 翻译成 Go（接口/签名换代频繁，翻译必漂移），不如用 goja 原样执行上游模块，
// 由本文件提供它需要的 host 原语（fetch/md5/hex/base64/cache/...）。

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/md5"
	"crypto/rand"
	"crypto/sha256"
	_ "embed"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math/big"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/provider"
	"github.com/dop251/goja"
	"golang.org/x/net/html"
)

//go:embed jsmodule/hongguo.js
var hongguoJSModuleSource string

type hongguoJSModule struct {
	vm         *goja.Runtime
	exports    *goja.Object
	downloader *Downloader

	// exclusiveMu 保护 host.exclusive 串行化；cacheMu 单独保护缓存。
	// 二者必须分离：JS 会在 exclusive 回调内部调用 cacheGet/cacheSet，
	// 若共用一把不可重入的 sync.Mutex 会当场死锁（表现为播放一直转圈）。
	exclusiveMu sync.Mutex
	cacheMu     sync.Mutex
	caches      map[string]any

	// catalogBackground/catalogMore 供 JS catalogPage 的 host.catalogContext()
	// 读取，控制前台轻量分页(background=false)与是否从已存游标续页(more=true)。
	// 在每次调用 catalogPage 前设置；默认前台分页。
	catalogBackground bool
	catalogMore       bool

	fetchMu sync.Mutex
}

var hongguoMaxSafeInteger = new(big.Int).SetInt64(9007199254740991)

// hongguoPreserveIntegers 把 JSON 里超过 IEEE754 安全范围的整数 token 加引号，
// 避免 goja 的 Number(double) 静默改写红果 19 位 ID（series_id/vid 等）。
// 字符串内的数字、小数、指数保持原样；JS 侧 mapString 能把 string 转回 ID。
func hongguoPreserveIntegers(text string) string {
	var out strings.Builder
	out.Grow(len(text))
	inString, escaped := false, false
	for i := 0; i < len(text); {
		ch := text[i]
		if inString {
			out.WriteByte(ch)
			switch {
			case escaped:
				escaped = false
			case ch == '\\':
				escaped = true
			case ch == '"':
				inString = false
			}
			i++
			continue
		}
		if ch == '"' {
			inString = true
			out.WriteByte(ch)
			i++
			continue
		}
		if ch == '-' || (ch >= '0' && ch <= '9') {
			start := i
			if ch == '-' {
				i++
			}
			digitStart := i
			for i < len(text) && text[i] >= '0' && text[i] <= '9' {
				i++
			}
			if i > digitStart && i < len(text) && (text[i] == '.' || text[i] == 'e' || text[i] == 'E') {
				out.WriteString(text[start:i])
				continue
			}
			token := text[start:i]
			if number, ok := new(big.Int).SetString(token, 10); ok &&
				new(big.Int).Abs(number).Cmp(hongguoMaxSafeInteger) > 0 {
				out.WriteByte('"')
				out.WriteString(token)
				out.WriteByte('"')
				continue
			}
			out.WriteString(token)
			continue
		}
		out.WriteByte(ch)
		i++
	}
	return out.String()
}

// hongguoHTMLNodeValue 把 *html.Node 转成 JS htmlTree() 可遍历的普通对象：
// 元素节点带 tag/attrs，文本节点带 text，children 保持文档序（不含 parent，
// 由 JS 回填）。榜单 DOM 兜底依赖这些字段。
func hongguoHTMLNodeValue(node *html.Node) map[string]any {
	value := map[string]any{}
	switch node.Type {
	case html.ElementNode:
		value["tag"] = node.Data
		attrs := map[string]string{}
		for _, attribute := range node.Attr {
			attrs[attribute.Key] = attribute.Val
		}
		value["attrs"] = attrs
	case html.TextNode:
		value["text"] = node.Data
	}
	children := []any{}
	for child := node.FirstChild; child != nil; child = child.NextSibling {
		children = append(children, hongguoHTMLNodeValue(child))
	}
	value["children"] = children
	return value
}

var (
	hongguoJSOnce   sync.Once
	hongguoJSShared *hongguoJSModule
	hongguoJSErr    error
)

// hongguoJS 返回进程内单例（goja 运行时不宜并发共享，调用方需按需加锁）。
func (d *Downloader) hongguoJS() (*hongguoJSModule, error) {
	hongguoJSOnce.Do(func() {
		hongguoJSShared, hongguoJSErr = newHongguoJSModule(d)
	})
	return hongguoJSShared, hongguoJSErr
}

func newHongguoJSModule(d *Downloader) (*hongguoJSModule, error) {
	module := &hongguoJSModule{vm: goja.New(), downloader: d, caches: map[string]any{}}
	if err := module.vm.Set("host", module.hostObject()); err != nil {
		return nil, err
	}
	wrapped := "(function(){var module={exports:{}};(function(module,exports){\n" +
		hongguoJSModuleSource +
		"\n})(module,module.exports);return module.exports;})()"
	value, err := module.vm.RunString(wrapped)
	if err != nil {
		return nil, fmt.Errorf("加载红果 JS 模块失败: %w", err)
	}
	module.exports = value.ToObject(module.vm)
	return module, nil
}

func jsToBytes(vm *goja.Runtime, value goja.Value) []byte {
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil
	}
	switch exported := value.Export().(type) {
	case []byte:
		return exported
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

func jsString(args []goja.Value, index int) string {
	if index >= len(args) || args[index] == nil || goja.IsUndefined(args[index]) || goja.IsNull(args[index]) {
		return ""
	}
	return args[index].String()
}

func jsInt(args []goja.Value, index int, fallback int64) int64 {
	if index >= len(args) || args[index] == nil || goja.IsUndefined(args[index]) {
		return fallback
	}
	return args[index].ToInteger()
}

func jsField(object *goja.Object, name string) goja.Value {
	if object == nil {
		return goja.Undefined()
	}
	return object.Get(name)
}

func jsFieldString(object *goja.Object, name string) string {
	value := jsField(object, name)
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return ""
	}
	return value.String()
}

func (module *hongguoJSModule) hostObject() map[string]any {
	vm := module.vm
	bytesValue := func(data []byte) goja.Value { return vm.ToValue(data) }
	return map[string]any{
		"source": "hongguo",
		// JS 侧是 host.retries() / host.maxPages()，必须是函数而不是数字。
		"retries":  func() int { return 3 },
		"maxPages": func() int { return 50 },

		"md5": func(call goja.FunctionCall) goja.Value {
			sum := md5.Sum(jsToBytes(vm, call.Argument(0)))
			return bytesValue(sum[:])
		},
		"sha256": func(call goja.FunctionCall) goja.Value {
			sum := sha256.Sum256(jsToBytes(vm, call.Argument(0)))
			return bytesValue(sum[:])
		},
		"hexEncode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(hex.EncodeToString(jsToBytes(vm, call.Argument(0))))
		},
		"hexDecode": func(call goja.FunctionCall) goja.Value {
			decoded, _ := hex.DecodeString(strings.TrimSpace(jsString(call.Arguments, 0)))
			return bytesValue(decoded)
		},
		"base64Encode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(base64.StdEncoding.EncodeToString(jsToBytes(vm, call.Argument(0))))
		},
		"base64Decode": func(call goja.FunctionCall) goja.Value {
			decoded, _ := base64.StdEncoding.DecodeString(strings.TrimSpace(jsString(call.Arguments, 0)))
			return bytesValue(decoded)
		},
		"utf8Encode": func(call goja.FunctionCall) goja.Value {
			return bytesValue([]byte(jsString(call.Arguments, 0)))
		},
		"utf8Decode": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(string(jsToBytes(vm, call.Argument(0))))
		},
		"randomBytes": func(call goja.FunctionCall) goja.Value {
			size := int(jsInt(call.Arguments, 0, 16))
			if size < 0 || size > 1<<16 {
				size = 16
			}
			buf := make([]byte, size)
			_, _ = rand.Read(buf)
			return bytesValue(buf)
		},
		"aesCbcEncrypt": func(call goja.FunctionCall) goja.Value {
			key := jsToBytes(vm, call.Argument(0))
			iv := jsToBytes(vm, call.Argument(1))
			data := jsToBytes(vm, call.Argument(2))
			block, err := aes.NewCipher(key)
			if err != nil || len(iv) != block.BlockSize() {
				return bytesValue(nil)
			}
			padded := append([]byte{}, data...)
			if pad := block.BlockSize() - len(padded)%block.BlockSize(); pad > 0 {
				padded = append(padded, bytes.Repeat([]byte{byte(pad)}, pad)...)
			}
			cipher.NewCBCEncrypter(block, iv).CryptBlocks(padded, padded)
			return bytesValue(padded)
		},
		"isKnown": func(call goja.FunctionCall) goja.Value { return vm.ToValue(false) },
		"preserveIntegers": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(hongguoPreserveIntegers(jsString(call.Arguments, 0)))
		},
		"parseUrl": func(call goja.FunctionCall) goja.Value {
			parsed, err := url.Parse(jsString(call.Arguments, 0))
			if err != nil {
				return vm.ToValue(map[string]any{})
			}
			return vm.ToValue(map[string]any{
				"scheme": parsed.Scheme, "host": parsed.Host, "hostname": parsed.Hostname(),
				"port": parsed.Port(), "path": parsed.Path, "query": parsed.RawQuery, "hash": parsed.Fragment,
			})
		},
		"parseHtml": func(call goja.FunctionCall) goja.Value {
			document, err := html.Parse(strings.NewReader(jsString(call.Arguments, 0)))
			if err != nil {
				panic(vm.NewGoError(err))
			}
			return vm.ToValue(hongguoHTMLNodeValue(document))
		},
		"catalogContext": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(map[string]any{
				"background": module.catalogBackground,
				"more":       module.catalogMore,
			})
		},
		"reportProgress": func(call goja.FunctionCall) goja.Value { return goja.Undefined() },
		"chapterId": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(fmt.Sprintf("%v", call.Argument(0)))
		},
		"dramaId": func(call goja.FunctionCall) goja.Value {
			id := strings.TrimSpace(jsString(call.Arguments, 0))
			if strings.HasPrefix(id, "hongguo:") {
				return vm.ToValue(id)
			}
			return vm.ToValue("hongguo:" + id)
		},
		"finishMedia": func(call goja.FunctionCall) goja.Value { return call.Argument(0) },
		"exclusive": func(call goja.FunctionCall) goja.Value {
			module.exclusiveMu.Lock()
			defer module.exclusiveMu.Unlock()
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
			module.cacheMu.Lock()
			defer module.cacheMu.Unlock()
			value, found := module.caches[jsString(call.Arguments, 0)]
			if !found {
				return goja.Null()
			}
			return vm.ToValue(value)
		},
		"cacheSet": func(call goja.FunctionCall) goja.Value {
			module.cacheMu.Lock()
			defer module.cacheMu.Unlock()
			module.caches[jsString(call.Arguments, 0)] = call.Argument(1).Export()
			return goja.Undefined()
		},
		"sleep": func(call goja.FunctionCall) goja.Value {
			ms := jsInt(call.Arguments, 0, 0)
			if ms > 0 && ms < 5000 {
				time.Sleep(time.Duration(ms) * time.Millisecond)
			}
			return goja.Undefined()
		},
		"reserve": func(call goja.FunctionCall) goja.Value {
			return vm.ToValue(1)
		},
		"fetch":     module.hostFetch,
		"fetchText": module.hostFetchText,
	}
}

// hostFetch 同步执行一次 HTTP 请求（JS 侧是同步调用，不能返回 Promise）。
func (module *hongguoJSModule) hostFetch(call goja.FunctionCall) goja.Value {
	options := call.Argument(0).ToObject(module.vm)
	method := strings.ToUpper(strings.TrimSpace(jsFieldString(options, "method")))
	if method == "" {
		method = http.MethodGet
	}
	address := jsFieldString(options, "url")
	body := jsFieldString(options, "body")
	timeoutMs := jsInt([]goja.Value{jsField(options, "timeoutMs")}, 0, 20000)
	ctx, cancel := context.WithTimeout(context.Background(), time.Duration(timeoutMs)*time.Millisecond)
	defer cancel()
	var reader io.Reader
	if body != "" {
		reader = strings.NewReader(body)
	}
	request, err := http.NewRequestWithContext(ctx, method, address, reader)
	if err != nil {
		panic(module.vm.NewGoError(err))
	}
	if headers := jsField(options, "headers"); headers != nil && !goja.IsUndefined(headers) && !goja.IsNull(headers) {
		headerObject := headers.ToObject(module.vm)
		for _, key := range headerObject.Keys() {
			request.Header.Set(key, headerObject.Get(key).String())
		}
	}
	response, err := module.downloader.client.Do(request)
	if err != nil {
		panic(module.vm.NewGoError(err))
	}
	defer response.Body.Close()
	content, readErr := io.ReadAll(io.LimitReader(response.Body, 32<<20))
	if readErr != nil {
		panic(module.vm.NewGoError(readErr))
	}
	headerMap := map[string]any{}
	for key, list := range response.Header {
		if len(list) > 0 {
			headerMap[key] = list[0]
		}
	}
	return module.vm.ToValue(map[string]any{
		"status":  response.StatusCode,
		"body":    string(content),
		"headers": headerMap,
	})
}

// hostFetchText 对应 JS 的 host.fetchText({url, referer, noCache})，返回
// {body, status, headers}（JS 取 .body）。
func (module *hongguoJSModule) hostFetchText(call goja.FunctionCall) goja.Value {
	argument := call.Argument(0)
	address := ""
	referer := ""
	if object, ok := argument.Export().(map[string]any); ok {
		address, _ = object["url"].(string)
		referer, _ = object["referer"].(string)
	} else {
		address = jsString(call.Arguments, 0)
	}
	if address == "" {
		panic(module.vm.NewGoError(errors.New("fetchText 缺少 url")))
	}
	request, err := http.NewRequest(http.MethodGet, address, nil)
	if err != nil {
		panic(module.vm.NewGoError(err))
	}
	request.Header.Set("User-Agent", hongguoWebUserAgent)
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	response, err := module.downloader.client.Do(request)
	if err != nil {
		panic(module.vm.NewGoError(err))
	}
	defer response.Body.Close()
	content, _ := io.ReadAll(io.LimitReader(response.Body, 8<<20))
	headerMap := map[string]any{}
	for key, list := range response.Header {
		if len(list) > 0 {
			headerMap[key] = list[0]
		}
	}
	return module.vm.ToValue(map[string]any{
		"body":    string(content),
		"status":  response.StatusCode,
		"headers": headerMap,
	})
}

// hongguoJSResolveMedia 用上游 JS 模块解析一集的媒体地址。
func (module *hongguoJSModule) resolveMedia(ctx context.Context, dramaID, videoID string) (providerMedia, error) {
	module.fetchMu.Lock()
	defer module.fetchMu.Unlock()
	fn, ok := goja.AssertFunction(module.exports.Get("resolveMedia"))
	if !ok {
		return providerMedia{}, errors.New("红果 JS 模块缺少 resolveMedia")
	}
	task := map[string]any{
		"dramaId": dramaID,
		"chapter": map[string]any{"videoUrl": "hongguo-cenc://" + videoID},
	}
	value, err := fn(goja.Undefined(), module.vm.ToValue(task))
	if err != nil {
		return providerMedia{}, fmt.Errorf("红果 JS 取流失败: %w", err)
	}
	object := value.ToObject(module.vm)
	media := providerMedia{
		URL:     jsFieldString(object, "url"),
		Referer: jsFieldString(object, "referer"),
	}
	if media.URL == "" {
		return providerMedia{}, errors.New("红果 JS 未返回播放地址")
	}
	if key := jsFieldString(object, "cencKey"); key != "" {
		if decoded, decodeErr := base64.StdEncoding.DecodeString(key); decodeErr == nil {
			media.CENCKey = decoded
		}
	}
	if quality := jsField(object, "quality"); quality != nil && !goja.IsUndefined(quality) {
		media.Quality = int(quality.ToInteger())
	}
	if durationMs := jsField(object, "durationMs"); durationMs != nil && !goja.IsUndefined(durationMs) {
		media.Duration = time.Duration(durationMs.ToInteger()) * time.Millisecond
	}
	return media, nil
}

// hongguoJSCall 在 fetchMu 保护下调用一个 JS 导出并把返回值 Export 成 Go 值。
// goja.Runtime 非并发安全，所有导出调用必须共用这把锁（与 resolveMedia 同锁）。
// 返回 goja.Undefined()/null 时归一为 nil。
func (module *hongguoJSModule) hongguoJSCall(name string, args ...any) (any, error) {
	module.fetchMu.Lock()
	defer module.fetchMu.Unlock()
	fn, ok := goja.AssertFunction(module.exports.Get(name))
	if !ok {
		return nil, fmt.Errorf("红果 JS 模块缺少 %s", name)
	}
	values := make([]goja.Value, len(args))
	for index, arg := range args {
		values[index] = module.vm.ToValue(arg)
	}
	value, err := fn(goja.Undefined(), values...)
	if err != nil {
		return nil, fmt.Errorf("红果 JS %s 失败: %w", name, err)
	}
	if value == nil || goja.IsUndefined(value) || goja.IsNull(value) {
		return nil, nil
	}
	return value.Export(), nil
}

// isAllDigits 判断字符串是否全为数字（JS danmaku 要求纯数字 ID）。
func isAllDigits(value string) bool {
	if value == "" {
		return false
	}
	for i := 0; i < len(value); i++ {
		if value[i] < '0' || value[i] > '9' {
			return false
		}
	}
	return true
}

// jsStringSlice 把 Export 后的 []any 归一为 []string（过滤空白）。
func jsStringSlice(value any) []string {
	items, ok := value.([]any)
	if !ok {
		return nil
	}
	out := make([]string, 0, len(items))
	for _, item := range items {
		if text, ok := item.(string); ok && strings.TrimSpace(text) != "" {
			out = append(out, text)
		}
	}
	return out
}

// jsIntField 从 Export 后的 map 取整数字段（JS number 导出为 float64）。
func jsIntField(object map[string]any, key string) int {
	switch value := object[key].(type) {
	case float64:
		return int(value)
	case int64:
		return int(value)
	case int:
		return value
	case json.Number:
		n, _ := value.Int64()
		return int(n)
	}
	return 0
}

// jsBoolField 从 Export 后的 map 取布尔字段。
func jsBoolField(object map[string]any, key string) bool {
	value, _ := object[key].(bool)
	return value
}

// suggestions 走 JS：返回联想词数组。
func (module *hongguoJSModule) suggestions(query string) ([]string, error) {
	value, err := module.hongguoJSCall("suggestions", query)
	if err != nil {
		return nil, err
	}
	words := jsStringSlice(value)
	if len(words) == 0 {
		return nil, errors.New("红果 JS 联想为空")
	}
	return words, nil
}

// jsRoundTrip 把 goja.Export 出来的 Go 值经 JSON 重新解码到目标结构。
// JS Drama 的字段名与 provider.Drama 的 json tag 一致，靠 tag 自动对齐，
// 避免逐字段手工映射漏字段。
func jsRoundTrip(value any, target any) error {
	encoded, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return json.Unmarshal(encoded, target)
}

// jsDramaPage 承载 JS catalogPage/search 的返回。
type jsDramaPage struct {
	Items   []provider.Drama
	HasMore bool
	Warning string
}

// parseJSDramaPage 把 JS {items,hasMore,warning} 转成 Go 结构。
func parseJSDramaPage(value any) (jsDramaPage, error) {
	object, ok := value.(map[string]any)
	if !ok {
		return jsDramaPage{}, errors.New("红果 JS 返回结构异常")
	}
	var page jsDramaPage
	page.HasMore = jsBoolField(object, "hasMore")
	page.Warning, _ = object["warning"].(string)
	rawItems, ok := object["items"].([]any)
	if !ok || len(rawItems) == 0 {
		return page, nil
	}
	page.Items = make([]provider.Drama, 0, len(rawItems))
	for _, raw := range rawItems {
		var drama provider.Drama
		if err := jsRoundTrip(raw, &drama); err != nil {
			continue
		}
		if drama.ID == "" {
			continue
		}
		// JS 的 sourceId 可能已是纯 ID；统一补 hongguo: 前缀供 nativeNormalize 反解。
		if !strings.HasPrefix(drama.ID, "hongguo:") && drama.Source == "hongguo" {
			drama.ID = "hongguo:" + drama.ID
		}
		page.Items = append(page.Items, drama)
	}
	return page, nil
}

// catalogPage 走 JS：分类目录。前台轻量分页用 background=false/more=true。
func (module *hongguoJSModule) catalogPage(category string, page int) (jsDramaPage, error) {
	module.fetchMu.Lock()
	module.catalogBackground = false
	module.catalogMore = true
	module.fetchMu.Unlock()
	value, err := module.hongguoJSCall("catalogPage", page, category)
	if err != nil {
		return jsDramaPage{}, err
	}
	return parseJSDramaPage(value)
}

// search 走 JS：合并短剧+听书搜索。
func (module *hongguoJSModule) search(query string, page int) (jsDramaPage, error) {
	value, err := module.hongguoJSCall("search", query, page)
	if err != nil {
		return jsDramaPage{}, err
	}
	return parseJSDramaPage(value)
}

// categories 走 JS：分类列表（{id,name}）。
func (module *hongguoJSModule) categories() ([]provider.CatalogCategory, error) {
	value, err := module.hongguoJSCall("categories", false)
	if err != nil {
		return nil, err
	}
	// JS 成功时返回数组，失败/不完整时返回 {items, incomplete} 对象。
	items, _ := value.([]any)
	if object, ok := value.(map[string]any); ok {
		items, _ = object["items"].([]any)
	}
	if len(items) == 0 {
		return nil, errors.New("红果 JS 分类为空")
	}
	categories := make([]provider.CatalogCategory, 0, len(items))
	for _, raw := range items {
		object, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		id, _ := object["id"].(string)
		name, _ := object["name"].(string)
		if id == "" || name == "" {
			continue
		}
		categories = append(categories, provider.CatalogCategory{ID: id, Name: name})
	}
	if len(categories) == 0 {
		return nil, errors.New("红果 JS 分类无有效项")
	}
	return categories, nil
}

// rankingPage 走 JS：榜单（items 为 {rank,drama,metric}）。
type jsRankingPage struct {
	Items     []rankingItem
	HasMore   bool
	TotalPage int
}

func (module *hongguoJSModule) rankingPage(boardID string, page int) (jsRankingPage, error) {
	value, err := module.hongguoJSCall("rankingPage", boardID, page)
	if err != nil {
		return jsRankingPage{}, err
	}
	object, ok := value.(map[string]any)
	if !ok {
		return jsRankingPage{}, errors.New("红果 JS 榜单结构异常")
	}
	var result jsRankingPage
	result.HasMore = jsBoolField(object, "hasMore")
	result.TotalPage = jsIntField(object, "totalPages")
	rawItems, _ := object["items"].([]any)
	for _, raw := range rawItems {
		item, ok := raw.(map[string]any)
		if !ok {
			continue
		}
		var drama provider.Drama
		if err := jsRoundTrip(item["drama"], &drama); err != nil || drama.ID == "" {
			continue
		}
		if !strings.HasPrefix(drama.ID, "hongguo:") {
			drama.ID = "hongguo:" + drama.ID
		}
		rank := jsIntField(item, "rank")
		if rank <= 0 {
			rank = len(result.Items) + 1
		}
		metric, _ := item["metric"].(string)
		result.Items = append(result.Items, rankingItem{Rank: rank, Metric: metric, Drama: drama})
	}
	if len(result.Items) == 0 {
		return result, errors.New("红果 JS 榜单为空")
	}
	return result, nil
}

// jsDetailPage 承载 JS detail 的 {drama, chapters}。
type jsDetailPage struct {
	Drama    provider.Drama
	Chapters []provider.Chapter
}

// detail 走 JS：短剧/听书详情。drama 与 chapters 分别 JSON round-trip 映射。
func (module *hongguoJSModule) detail(sourceID string) (jsDetailPage, error) {
	value, err := module.hongguoJSCall("detail", sourceID)
	if err != nil {
		return jsDetailPage{}, err
	}
	object, ok := value.(map[string]any)
	if !ok {
		return jsDetailPage{}, errors.New("红果 JS 详情结构异常")
	}
	var result jsDetailPage
	if rawDrama := object["drama"]; rawDrama != nil {
		if err := jsRoundTrip(rawDrama, &result.Drama); err != nil || result.Drama.ID == "" {
			return jsDetailPage{}, errors.New("红果 JS 详情剧集无效")
		}
		if !strings.HasPrefix(result.Drama.ID, "hongguo:") {
			result.Drama.ID = "hongguo:" + result.Drama.ID
		}
	}
	rawChapters, _ := object["chapters"].([]any)
	for _, raw := range rawChapters {
		var chapter provider.Chapter
		if err := jsRoundTrip(raw, &chapter); err != nil || chapter.ID == "" {
			continue
		}
		result.Chapters = append(result.Chapters, chapter)
	}
	if len(result.Chapters) == 0 {
		return jsDetailPage{}, errors.New("红果 JS 详情无分集")
	}
	return result, nil
}

// danmaku 走 JS：返回页结构与 hongguoDanmakuPage 字段一致。
func (module *hongguoJSModule) danmaku(seriesID, videoID string, start, duration int64) (hongguoDanmakuPage, error) {
	value, err := module.hongguoJSCall("danmaku", seriesID, videoID, start, duration)
	if err != nil {
		return hongguoDanmakuPage{}, err
	}
	var page hongguoDanmakuPage
	if err := jsRoundTrip(value, &page); err != nil {
		return hongguoDanmakuPage{}, err
	}
	if len(page.Items) == 0 || page.NextMS <= start {
		return hongguoDanmakuPage{}, errors.New("红果 JS 弹幕为空或窗口无效")
	}
	return page, nil
}

var _ = json.Marshal
