package core

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strconv"
	"strings"
	"sync"
	"time"
)

// 本机流代理的「直链媒体本地预读缓存」。
//
// 真网实测（2026-10-20，红果公开直链 /video/public/{vid}/360p.mp4）：
//   - 单集只有 10.7MB，响应体一旦开始就以 30MB/s 冲完（0.4 秒）；
//   - 慢的全是「响应头到达」这一步，实测随机排队 0.5~27 秒；
//   - 源站对同一直链的首次请求还会随机 404/502（CDN 未就绪）。
// mpv 对 mp4 是按 Range 分块读的，每一块都要重新付一次排队等待，整集播放
// 就表现为「一顿一顿」；切集时第一块尤其慢，直接变成十几秒的黑屏。
//
// 做法：每个直链资产只开一条上游连接，把整集顺序拉到本机临时文件；播放器
// 的 Range 请求改为读本地文件，源站排队被挡在代理之外。切集时如果下一集
// 早已在后台下完，切换就是零等待的。

const (
	// nativeCacheMaxBytes 单集预读上限：短剧 360p 一集约 10MB，
	// 64MB 足够铺满一集；超大文件只预读前段，避免占满磁盘。
	nativeCacheMaxBytes = 64 << 20
	// nativeCacheMinBytes 预读门槛：只有回源确认是「大文件」才预读。
	// 分片、密钥、探测请求都是几十 KB 级，用体积门槛就能只对整集直链预读。
	nativeCacheMinBytes = 1 << 20
	// nativeCacheSlotLimit 同时预读的资产数：源站按连接排队，
	// 同时预拉多集会互相拖慢。
	nativeCacheSlotLimit = 2
	// nativePrefetchAttempts 预读的尝试次数：源站随机 404/502 时
	// 退避重试，等 CDN 就绪即可继续。
	nativePrefetchAttempts = 5
	// nativeCacheHeaderWait 等预读拿到上游响应头（拿到总长度）的上限。
	// 这一步就是源站的排队时间，实测最长 27 秒，所以要给足；但不能超过
	// 播放器侧的卡顿看门狗（45 秒）太多，否则会被误判成卡死。
	nativeCacheHeaderWait = 35 * time.Second
	// nativeCacheStallWait 预读多久没有推进就放弃等待。
	nativeCacheStallWait = 30 * time.Second
	// nativeRenewWait 转发失败后等待后台重签就绪的上限：重签要走整条
	// 解析链（红果实测 8 秒以上），这里只给一个短窗口，超时就把失败
	// 交回播放器——播放器重试时地址已被热替换，会直接命中新地址。
	nativeRenewWait = 1500 * time.Millisecond
)

var nativeCacheSlots = make(chan struct{}, nativeCacheSlotLimit)

// nativeStreamCache 是一个直链媒体的本地预读缓存。
type nativeStreamCache struct {
	mu       sync.Mutex
	file     *os.File
	path     string
	size     int64 // 已落盘字节数，对应文件偏移 [0,size)
	total    int64 // 上游总长度，0 表示未知
	complete bool  // 整个文件已落盘
	failed   bool  // 预读失败
	closed   bool
	err      error
	done     chan struct{}
	once     sync.Once
}

func newNativeStreamCache() (*nativeStreamCache, error) {
	file, err := os.CreateTemp("", "duanju-stream-*.part")
	if err != nil {
		return nil, err
	}
	return &nativeStreamCache{file: file, path: file.Name(), done: make(chan struct{})}, nil
}

func (cache *nativeStreamCache) setTotal(total int64) {
	cache.mu.Lock()
	if total > 0 && cache.total <= 0 {
		cache.total = total
	}
	cache.mu.Unlock()
}

func (cache *nativeStreamCache) advance(written int64) {
	cache.mu.Lock()
	cache.size += written
	cache.mu.Unlock()
}

func (cache *nativeStreamCache) snapshot() (size, total int64, complete, failed, closed bool) {
	cache.mu.Lock()
	defer cache.mu.Unlock()
	return cache.size, cache.total, cache.complete, cache.failed, cache.closed
}

// finish 标记预读结束：complete=true 表示整集已落盘，err 非空表示失败。
func (cache *nativeStreamCache) finish(complete bool, err error) {
	cache.mu.Lock()
	if complete {
		cache.complete = true
		if cache.total <= 0 {
			cache.total = cache.size
		}
	} else {
		cache.failed = true
		cache.err = err
	}
	cache.mu.Unlock()
	cache.once.Do(func() { close(cache.done) })
}

// discard 放弃这份缓存（失败时调用）：关文件、删临时文件、唤醒等待者。
func (cache *nativeStreamCache) discard() {
	cache.mu.Lock()
	if cache.closed {
		cache.mu.Unlock()
		return
	}
	cache.closed = true
	cache.failed = true
	file := cache.file
	cache.mu.Unlock()
	cache.once.Do(func() { close(cache.done) })
	if file != nil {
		_ = file.Close()
	}
	_ = os.Remove(cache.path)
}

// close 关闭并删除临时文件（会话结束时调用）。
func (cache *nativeStreamCache) close() {
	cache.discard()
}

// waitTotal 等预读拿到上游总长度。拿到之前无法给出 Content-Length 与
// Content-Range，播放器只能干等，所以这一步就是源站的排队时间。
func (cache *nativeStreamCache) waitTotal(ctx context.Context, timeout time.Duration) (int64, bool) {
	deadline := time.Now().Add(timeout)
	for {
		cache.mu.Lock()
		total, complete, failed, closed := cache.total, cache.complete, cache.failed, cache.closed
		cache.mu.Unlock()
		if closed || failed {
			return 0, false
		}
		if total > 0 {
			return total, true
		}
		if complete {
			return 0, false
		}
		if time.Now().After(deadline) {
			return 0, false
		}
		select {
		case <-ctx.Done():
			return 0, false
		case <-cache.done:
			cache.mu.Lock()
			total, complete, failed, closed = cache.total, cache.complete, cache.failed, cache.closed
			cache.mu.Unlock()
			if closed || failed || complete && total <= 0 {
				return 0, false
			}
			return total, total > 0
		case <-time.After(100 * time.Millisecond):
		}
	}
}

// copyGrowing 把本地缓存里 [start, start+length) 的内容写给播放器。
// 预读还没下完时也能边下边发：已落盘的部分立刻写出，剩下的等预读推进。
func (cache *nativeStreamCache) copyGrowing(ctx context.Context, writer io.Writer, start, length int64) error {
	position, remaining := start, length
	buffer := make([]byte, 256*1024)
	lastProgress := time.Now()
	for remaining > 0 {
		size, _, complete, failed, closed := cache.snapshot()
		if closed || failed {
			return errors.New("本地预读已中断")
		}
		if position < size {
			chunk := int64(len(buffer))
			if chunk > size-position {
				chunk = size - position
			}
			if chunk > remaining {
				chunk = remaining
			}
			read, err := cache.file.ReadAt(buffer[:chunk], position)
			if read > 0 {
				if _, writeErr := writer.Write(buffer[:read]); writeErr != nil {
					return writeErr
				}
				position += int64(read)
				remaining -= int64(read)
				lastProgress = time.Now()
			}
			if err != nil && !errors.Is(err, io.EOF) {
				return err
			}
			continue
		}
		if complete {
			// 文件比承诺的短：只能到此为止。
			return nil
		}
		if time.Since(lastProgress) > nativeCacheStallWait {
			return errors.New("本地预读长时间没有推进")
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-time.After(50 * time.Millisecond):
		}
	}
	return nil
}

// nativeCacheableAsset 判断资产是否适合做整集预读：只有直链 mp4 才行，
// HLS 清单、分片、密钥都太小，预读没有意义。
func nativeCacheableAsset(asset nativeStreamAsset) bool {
	if len(asset.data) > 0 || strings.Contains(asset.contentType, "mpegurl") {
		return false
	}
	parsed, err := url.Parse(asset.address)
	if err != nil {
		return false
	}
	return strings.EqualFold(path.Ext(parsed.Path), ".mp4")
}

// nativeStartPrefetch 为直链资产启动后台预读（每个资产只开一条上游连接）。
//
// 预读是切集速度的关键：源站响应头的排队实测最长 27 秒，如果等到切集才
// 去请求，这 27 秒就整段落在用户的等待里；在上一集还在播的时候就把下一集
// 下完，切集时读本地文件即可零等待。
func (stream *nativeStreamServer) nativeStartPrefetch(session *nativeStreamSession, id string, asset nativeStreamAsset, contentLength int64) {
	if contentLength > 0 && contentLength < nativeCacheMinBytes {
		return
	}
	if contentLength == 0 && !nativeCacheableAsset(asset) {
		return
	}
	if !strings.HasPrefix(asset.address, "http://") && !strings.HasPrefix(asset.address, "https://") {
		return
	}
	session.mu.Lock()
	if session.caches == nil {
		session.caches = map[string]*nativeStreamCache{}
	}
	if existing, found := session.caches[id]; found {
		_, _, _, failed, closed := existing.snapshot()
		if !failed && !closed {
			// 已经在预读（或已下完）：不重复开连接。
			session.mu.Unlock()
			return
		}
		// 上一份缓存已失败：丢掉重来一次。
		delete(session.caches, id)
	}
	cache, err := newNativeStreamCache()
	if err != nil {
		session.mu.Unlock()
		return
	}
	session.caches[id] = cache
	session.mu.Unlock()

	select {
	case nativeCacheSlots <- struct{}{}:
	default:
		// 预读名额已满：放弃预读，播放照常回源（不额外占连接）。
		cache.discard()
		session.mu.Lock()
		delete(session.caches, id)
		session.mu.Unlock()
		return
	}
	go func() {
		defer func() { <-nativeCacheSlots }()
		stream.nativePrefetchLoop(session, id, cache, asset)
	}()
}

// nativePrefetchLoop 顺序把整集拉进本地文件。
// 成功后保留文件（供播放器的 Range 请求命中），失败才关闭并清理。
func (stream *nativeStreamServer) nativePrefetchLoop(session *nativeStreamSession, id string, cache *nativeStreamCache, asset nativeStreamAsset) {
	// 源站对同一直链会随机 404/502（CDN 缓存未就绪，通常几百毫秒后就绪）。
	// 预读只试一次会让整集缓存直接作废，播放时只能回源再等一轮——这里
	// 自己带退避重试，把「等就绪」压在预读阶段，播放时基本都能直接命中。
	// 403/410 是签名过期或资源失效，重试没有意义，直接放弃，交给转发
	// 路径的重签（重新解析换一条真实地址）处理。
	var response *http.Response
	permanent := false
	for attempt := 1; attempt <= nativePrefetchAttempts; attempt++ {
		if attempt > 1 {
			select {
			case <-session.ctx.Done():
				cache.discard()
				stream.dropCache(session, id, cache)
				return
			case <-time.After(time.Duration(attempt) * 300 * time.Millisecond):
			}
		}
		request, err := http.NewRequestWithContext(session.ctx, http.MethodGet, asset.address, nil)
		if err != nil {
			cache.discard()
			stream.dropCache(session, id, cache)
			return
		}
		request.Header.Set("User-Agent", hongguoWebMediaUserAgent(asset.address))
		request.Header.Set("Referer", session.referer)
		// 用 bytes=0- 拿整集：即使上游用分块传输，也能从 Content-Range
		// 里拿到总长度（播放器需要它来算 Content-Length）。
		request.Header.Set("Range", "bytes=0-")
		response, err = stream.nativeRequest(request)
		if err != nil {
			continue
		}
		if response.StatusCode == http.StatusOK || response.StatusCode == http.StatusPartialContent {
			break
		}
		permanent = response.StatusCode == http.StatusForbidden || response.StatusCode == http.StatusGone
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 8<<10))
		response.Body.Close()
		response = nil
		if permanent {
			break
		}
	}
	if response == nil {
		cache.discard()
		stream.dropCache(session, id, cache)
		return
	}
	defer response.Body.Close()
	total := nativeCacheTotal(response)
	if total > 0 && total < nativeCacheMinBytes {
		// 体积过小（例如错误页）：不值得预读，交给回源路径。
		cache.discard()
		stream.dropCache(session, id, cache)
		return
	}
	cache.setTotal(total)
	buffer := make([]byte, 256*1024)
	for {
		read, readErr := response.Body.Read(buffer)
		if read > 0 {
			if _, writeErr := cache.file.Write(buffer[:read]); writeErr != nil {
				cache.discard()
				stream.dropCache(session, id, cache)
				return
			}
			cache.advance(int64(read))
			size, _, _, _, _ := cache.snapshot()
			if size > nativeCacheMaxBytes {
				// 超出预读上限：放弃缓存，播放回源直连继续。
				cache.discard()
				stream.dropCache(session, id, cache)
				return
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				cache.finish(true, nil)
				return
			}
			cache.discard()
			stream.dropCache(session, id, cache)
			return
		}
	}
}

// nativeCacheTotal 从上游响应里取整集总长度。
func nativeCacheTotal(response *http.Response) int64 {
	if start, end, total, ok := nativeContentRange(response.Header.Get("Content-Range")); ok && end >= start {
		return total
	}
	if response.ContentLength > 0 {
		return response.ContentLength
	}
	return 0
}

// dropCache 把失败的缓存从会话里摘掉，让下一次请求可以重新预读。
func (stream *nativeStreamServer) dropCache(session *nativeStreamSession, id string, cache *nativeStreamCache) {
	session.mu.Lock()
	if current, found := session.caches[id]; found && current == cache {
		delete(session.caches, id)
	}
	session.mu.Unlock()
}

// nativeServeCached 尝试用本地预读缓存响应请求。
// 返回 true 表示已响应（调用方不要再回源），false 表示缓存不可用需回源。
func (stream *nativeStreamServer) nativeServeCached(ctx context.Context, writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, id string, asset nativeStreamAsset) bool {
	session.mu.Lock()
	cache := session.caches[id]
	session.mu.Unlock()
	if cache == nil {
		return false
	}
	// 等预读拿到总长度：这一步就是源站的排队时间（最长实测 27 秒）。
	total, ok := cache.waitTotal(ctx, nativeCacheHeaderWait)
	if !ok {
		return false
	}
	start, end, hasRange, valid := parseNativeRange(request.Header.Get("Range"))
	if !valid {
		return false
	}
	if !hasRange {
		start, end = 0, total-1
	} else if end < 0 {
		end = total - 1
	}
	if start >= total {
		return false
	}
	if end >= total {
		end = total - 1
	}
	length := end - start + 1
	contentType := asset.contentType
	if contentType == "" {
		contentType = "video/mp4"
	}
	writer.Header().Set("Content-Type", contentType)
	writer.Header().Set("Accept-Ranges", "bytes")
	writer.Header().Set("Content-Length", strconv.FormatInt(length, 10))
	if hasRange {
		writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, total))
		writer.WriteHeader(http.StatusPartialContent)
	} else {
		writer.WriteHeader(http.StatusOK)
	}
	if request.Method != http.MethodGet {
		return true
	}
	// 预读还在继续时边下边发，播放器不必等整集下完。
	_ = cache.copyGrowing(ctx, writer, start, length)
	return true
}

// parseNativeRange 解析 Range 头。返回 start、end（-1 表示到末尾）、
// 是否带 Range、是否合法。
func parseNativeRange(header string) (int64, int64, bool, bool) {
	header = strings.TrimSpace(header)
	if header == "" {
		return 0, -1, false, true
	}
	if !strings.HasPrefix(header, "bytes=") {
		return 0, 0, false, false
	}
	spec := strings.TrimSpace(strings.TrimPrefix(header, "bytes="))
	if strings.IndexByte(spec, ',') >= 0 {
		// 多段 Range 本地缓存不处理，交给回源路径。
		return 0, 0, false, false
	}
	parts := strings.SplitN(spec, "-", 2)
	if len(parts) != 2 {
		return 0, 0, false, false
	}
	if strings.TrimSpace(parts[0]) == "" {
		// 后缀 Range（bytes=-N）：取文件末尾 N 字节，交给回源路径。
		return 0, 0, false, false
	}
	start, err := strconv.ParseInt(strings.TrimSpace(parts[0]), 10, 64)
	if err != nil || start < 0 {
		return 0, 0, false, false
	}
	end := int64(-1)
	if trimmed := strings.TrimSpace(parts[1]); trimmed != "" {
		parsed, err := strconv.ParseInt(trimmed, 10, 64)
		if err != nil || parsed < start {
			return 0, 0, false, false
		}
		end = parsed
	}
	return start, end, true, true
}
