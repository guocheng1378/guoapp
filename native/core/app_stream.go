package core

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"sync"
	"time"
)

type nativeStreamAsset struct {
	address     string
	data        []byte
	contentType string
	total       int64
	etag        string
	modified    string
}

type nativeStreamSession struct {
	credentials *providerMediaCredentials
	mu          sync.Mutex
	assets      map[string]nativeStreamAsset
	referer     string
	key         []byte
	ctx         context.Context
	cancel      context.CancelFunc
	lastUsed    time.Time
	refresher   func(context.Context) (providerMedia, error)
	renewMu     sync.Mutex
	renewedAt   time.Time
	renewedByID map[string]time.Time
	renewing    map[string]chan nativeRenewResult
	// caches 是本集媒体各资产的本地预读缓存（直链媒体才有），见 app_stream_cache.go。
	caches map[string]*nativeStreamCache
}

// nativeRenewResult 是一次后台重签的结果。
type nativeRenewResult struct {
	address string
	ok      bool
}

type nativeStreamServer struct {
	mu         sync.Mutex
	downloader *Downloader
	address    string
	sessions   map[string]*nativeStreamSession
	server     *http.Server
}

func (stream *nativeStreamServer) nativeRequest(request *http.Request) (*http.Response, error) {
	client := *stream.downloader.client
	client.Timeout = 0
	return stream.downloader.doMediaRequestWithClient(request, &client)
}

var nativePlaylistURI = regexp.MustCompile(`URI="([^"]+)"`)

// nativePruneAdSegments 剔除采集站注入媒体清单的广告分片段。
// 实测注入模式（开元棋牌等采集片源）：广告分片来自与正片不同的目录，
// 由 #EXT-X-DISCONTINUITY 包夹，短段插播在正片中。判定：解析分片绝对
// 地址后，目录与主目录（分片数最多的目录）不同的分片视为广告，连同其
// 前置标签行（EXTINF/KEY/BYTERANGE/包夹 DISCONTINUITY）一并移除。
// 主清单（多码率索引）、单目录清单与主目录不显著的清单原样返回。
//
// 剔除块边界补插两件事（中插广告才有前后正片）：
//   - 补一个 #EXT-X-DISCONTINUITY：广告与正片独立转码打轴，包夹标记
//     随段删除后正片时间轴出现无提示跳变，播放器音频同步拉扯出杂音。
//   - 广告段自带的 #EXT-X-KEY 随段删除（KEY 是持续作用标签，残留会把
//     广告密钥套到后续正片上，解密失败即爆音），并在块边界恢复正片
//     原本生效的 KEY。
func nativePruneAdSegments(lines []string, base string) []string {
	parsed, err := url.Parse(base)
	if err != nil {
		return lines
	}
	dirCount := map[string]int{}
	segDirs := make([]string, len(lines))
	segments := 0
	for i, line := range lines {
		text := strings.TrimSpace(line)
		if text == "" || strings.HasPrefix(text, "#") {
			continue
		}
		reference, err := url.Parse(text)
		if err != nil {
			continue
		}
		resolved := parsed.ResolveReference(reference)
		if resolved.Host == "" {
			continue
		}
		dir := resolved.Host + path.Dir(resolved.Path)
		segDirs[i] = dir
		dirCount[dir]++
		segments++
	}
	if segments == 0 {
		return lines
	}
	mainDir, mainCount, other := "", 0, 0
	for dir, count := range dirCount {
		if count > mainCount {
			mainDir, mainCount = dir, count
		}
	}
	for dir, count := range dirCount {
		if dir != mainDir {
			other += count
		}
	}
	if mainDir == "" || mainCount < 4 || mainCount <= other {
		// 主目录不显著（清单过短或目录对半分）时不动清单，避免误杀正片。
		return lines
	}
	remove := map[int]bool{}
	lastSegment := -1
	for i, line := range lines {
		dir := segDirs[i]
		if dir == "" || dir == mainDir {
			if strings.TrimSpace(line) != "" && !strings.HasPrefix(strings.TrimSpace(line), "#") {
				lastSegment = i
			}
			continue
		}
		// HLS 中分片行之间的 # 行都修饰其后的第一个分片行，因此从上一个
		// 正片分片到当前广告分片之间的标签行随广告段一并删除；
		// 清单级标签保留，但广告段自带的 EXT-X-KEY 例外（持续作用标签，
		// 残留会把广告密钥套到后续正片上，正片 KEY 在块边界恢复）。
		for j := lastSegment + 1; j <= i; j++ {
			text := strings.TrimSpace(lines[j])
			if text == "" {
				continue
			}
			if strings.HasPrefix(text, "#EXT-X-KEY") {
				remove[j] = true
				continue
			}
			if nativePlaylistGlobalTag(text) {
				continue
			}
			remove[j] = true
		}
	}
	if len(remove) == 0 {
		return lines
	}
	// 逐行记录剔除后的生效 KEY：只认保留的 KEY 行（广告自带的 KEY
	// 已标记删除，不得污染快照），正片分片前的 KEY 即正片密钥，
	// 广告块删除后据此在块边界恢复。
	currentKey, mainKey := "", ""
	for i, line := range lines {
		text := strings.TrimSpace(line)
		if strings.HasPrefix(text, "#EXT-X-KEY") && !remove[i] {
			currentKey = text
		}
		if segDirs[i] != "" && !remove[i] {
			mainKey = currentKey
		}
	}
	insertDIS := map[int]bool{}
	insertKey := map[int]string{}
	blockStart := -1
	for i := 0; i <= len(lines); i++ {
		if i < len(lines) && remove[i] {
			if blockStart < 0 {
				blockStart = i
			}
			continue
		}
		if blockStart < 0 {
			continue
		}
		// 剔除块 [blockStart, i) 结束：仅在中插（块前后都有正片）时补插。
		before := false
		for j := 0; j < blockStart; j++ {
			if segDirs[j] != "" && !remove[j] {
				before = true
				break
			}
		}
		nextSeg := -1
		for j := i; j < len(lines); j++ {
			if segDirs[j] != "" && !remove[j] {
				nextSeg = j
				break
			}
		}
		if before && nextSeg >= 0 {
			for j := blockStart; j < i; j++ {
				text := strings.TrimSpace(lines[j])
				if !strings.HasPrefix(text, "#EXT-X-KEY") {
					continue
				}
				// 广告段带独立 KEY 且正片有密钥、块后到正片分片前
				// 又没有重新声明时，恢复正片 KEY。
				if mainKey == "" {
					break
				}
				declared := false
				for k := i; k <= nextSeg; k++ {
					if strings.HasPrefix(strings.TrimSpace(lines[k]), "#EXT-X-KEY") {
						declared = true
						break
					}
				}
				if !declared {
					insertKey[i] = mainKey
				}
				break
			}
			insertDIS[i] = true
		}
		blockStart = -1
	}
	output := make([]string, 0, len(lines)+len(insertDIS)+len(insertKey))
	for i, line := range lines {
		if text, ok := insertKey[i]; ok {
			output = append(output, text)
		}
		if insertDIS[i] {
			output = append(output, "#EXT-X-DISCONTINUITY")
		}
		if remove[i] {
			continue
		}
		if strings.TrimSpace(line) == "#EXT-X-DISCONTINUITY" && len(output) > 0 && strings.TrimSpace(output[len(output)-1]) == "#EXT-X-DISCONTINUITY" {
			continue
		}
		output = append(output, line)
	}
	return output
}

// nativePlaylistGlobalTag 判断是否清单级标签（不属于任何单个分片，剔除
// 广告段时必须保留）。
func nativePlaylistGlobalTag(text string) bool {
	if colon := strings.IndexByte(text, ':'); colon >= 0 {
		text = text[:colon]
	}
	switch text {
	case "#EXTM3U", "#EXT-X-VERSION", "#EXT-X-TARGETDURATION", "#EXT-X-MEDIA-SEQUENCE",
		"#EXT-X-DISCONTINUITY-SEQUENCE", "#EXT-X-PLAYLIST-TYPE", "#EXT-X-ALLOW-CACHE",
		"#EXT-X-INDEPENDENT-SEGMENTS", "#EXT-X-START", "#EXT-X-MAP", "#EXT-X-KEY",
		"#EXT-X-SESSION-KEY", "#EXT-X-ENDLIST":
		return true
	}
	return false
}

func newNativeStreamServer(d *Downloader) (*nativeStreamServer, error) {
	listener, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		return nil, errors.New("无法初始化本机播放器")
	}
	stream := &nativeStreamServer{downloader: d, address: "http://" + listener.Addr().String(), sessions: map[string]*nativeStreamSession{}}
	server := &http.Server{Handler: http.HandlerFunc(stream.nativeServe), ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 30 * time.Second, MaxHeaderBytes: 16384}
	stream.server = server
	go func() { _ = server.Serve(listener) }()
	return stream, nil
}

func (stream *nativeStreamServer) nativeOpen(media providerMedia, refresher ...func(context.Context) (providerMedia, error)) (string, string, error) {
	tokenBytes := make([]byte, 24)
	if _, err := rand.Read(tokenBytes); err != nil {
		return "", "", errors.New("无法生成本机播放会话")
	}
	token := hex.EncodeToString(tokenBytes)
	ctx, cancel := context.WithCancel(providerMediaContext(context.Background(), media.credentials))
	session := &nativeStreamSession{assets: map[string]nativeStreamAsset{}, referer: media.Referer, key: media.HLSKey, ctx: ctx, cancel: cancel, lastUsed: time.Now(), credentials: media.credentials, caches: map[string]*nativeStreamCache{}}
	if len(refresher) > 0 {
		session.refresher = refresher[0]
	}
	stream.mu.Lock()
	for id, old := range stream.sessions {
		if time.Since(old.lastUsed) > 10*time.Minute {
			old.cancel()
			nativeCloseStreamCache(old)
			delete(stream.sessions, id)
		}
	}
	if len(stream.sessions) >= 8 {
		oldest := ""
		for id, old := range stream.sessions {
			if oldest == "" || old.lastUsed.Before(stream.sessions[oldest].lastUsed) {
				oldest = id
			}
		}
		stream.sessions[oldest].cancel()
		nativeCloseStreamCache(stream.sessions[oldest])
		delete(stream.sessions, oldest)
	}
	stream.sessions[token] = session
	stream.mu.Unlock()
	entry := nativeStreamAsset{address: media.URL, contentType: "video/mp4"}
	if parsed, err := url.Parse(media.URL); err == nil && strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	if media.Playlist != "" {
		entry.data = []byte(media.Playlist)
		entry.contentType = "application/vnd.apple.mpegurl"
	}
	// 直链媒体的本地预读在播放器真正请求该资产时再启动（见 nativeServe），
	// 避免对「预加载但还没播」的下一集也占源站带宽。
	return stream.nativeAsset(token, session, entry), token, nil
}

// nativeCloseStreamCache 释放会话的本地预读缓存（关文件并删临时文件）。
func nativeCloseStreamCache(session *nativeStreamSession) {
	session.mu.Lock()
	caches := session.caches
	session.caches = nil
	session.mu.Unlock()
	for _, cache := range caches {
		cache.close()
	}
}

func (stream *nativeStreamServer) nativeRelease(token string) {
	stream.mu.Lock()
	if session := stream.sessions[token]; session != nil {
		session.cancel()
		nativeCloseStreamCache(session)
		delete(stream.sessions, token)
	}
	stream.mu.Unlock()
}

func (stream *nativeStreamServer) nativeAsset(token string, session *nativeStreamSession, asset nativeStreamAsset) string {
	digest := sha256.Sum256([]byte(asset.address + "\x00" + asset.contentType))
	extension := ".ts"
	if parsed, err := url.Parse(asset.address); err == nil {
		switch candidate := strings.ToLower(path.Ext(parsed.Path)); candidate {
		case ".m3u8", ".ts", ".m4s", ".mp4", ".aac", ".m4a", ".mp3", ".vtt", ".webvtt", ".key":
			extension = candidate
		}
	}
	switch asset.contentType {
	case "application/vnd.apple.mpegurl":
		extension = ".m3u8"
	case "application/octet-stream":
		extension = ".key"
	case "video/mp4":
		extension = ".mp4"
	}
	id := hex.EncodeToString(digest[:12]) + extension
	session.mu.Lock()
	if previous, found := session.assets[id]; !found || len(previous.data) == 0 || len(asset.data) > 0 {
		session.assets[id] = asset
	}
	session.mu.Unlock()
	return stream.address + "/" + token + "/" + id
}

func (stream *nativeStreamServer) nativeRewrite(token string, session *nativeStreamSession, body, base string) (string, error) {
	lines := strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n")
	body = strings.Join(nativePruneAdSegments(lines, base), "\n")
	var output []string
	nextPlaylist := false
	for _, line := range strings.Split(strings.ReplaceAll(body, "\r\n", "\n"), "\n") {
		text := strings.TrimSpace(line)
		rewrite := func(reference string, key bool, contentType string) string {
			if strings.HasPrefix(reference, "data:") {
				return reference
			}
			parsed, err := url.Parse(base)
			if err != nil {
				return ""
			}
			relative, err := url.Parse(reference)
			if err != nil {
				return ""
			}
			address := parsed.ResolveReference(relative).String()
			if !isProviderHTTPMediaURL(address) {
				return ""
			}
			asset := nativeStreamAsset{address: address, contentType: contentType}
			if key && len(session.key) == 16 {
				asset.data = append([]byte{}, session.key...)
				asset.contentType = "application/octet-stream"
			}
			return stream.nativeAsset(token, session, asset)
		}
		if text != "" && !strings.HasPrefix(text, "#") {
			contentType := ""
			if nextPlaylist {
				contentType = "application/vnd.apple.mpegurl"
			}
			line = rewrite(text, false, contentType)
			nextPlaylist = false
			if line == "" {
				return "", errors.New("播放列表中的媒体地址无效")
			}
		} else if strings.Contains(text, "URI=") {
			invalid := false
			line = nativePlaylistURI.ReplaceAllStringFunc(line, func(match string) string {
				reference := nativePlaylistURI.FindStringSubmatch(match)[1]
				key := strings.HasPrefix(text, "#EXT-X-KEY:") || strings.HasPrefix(text, "#EXT-X-SESSION-KEY:")
				contentType := ""
				switch {
				case key:
					contentType = "application/octet-stream"
				case strings.HasPrefix(text, "#EXT-X-MAP:"):
					contentType = "video/mp4"
				case strings.HasPrefix(text, "#EXT-X-MEDIA:"), strings.HasPrefix(text, "#EXT-X-I-FRAME-STREAM-INF:"), strings.HasPrefix(text, "#EXT-X-RENDITION-REPORT:"):
					contentType = "application/vnd.apple.mpegurl"
				}
				updated := rewrite(reference, key, contentType)
				if updated == "" {
					invalid = true
				}
				return "URI=\"" + updated + "\""
			})
			if invalid {
				return "", errors.New("播放列表中的附属地址无效")
			}
		}
		if strings.HasPrefix(text, "#EXT-X-STREAM-INF:") {
			nextPlaylist = true
		}
		output = append(output, line)
	}
	return strings.Join(output, "\n"), nil
}

// nativeRenewedURL 从重新解析出的媒体里挑选与旧地址形态匹配的替换地址：
// 优先主地址，形态不符时在变体里找同扩展名的第一个，避免拿清单替换直链。
func nativeRenewedURL(media providerMedia, oldAddress string) string {
	suffix := ""
	if parsed, err := url.Parse(oldAddress); err == nil {
		suffix = strings.ToLower(path.Ext(parsed.Path))
	}
	consider := func(candidate providerMedia) string {
		if !isProviderHTTPMediaURL(candidate.URL) {
			return ""
		}
		if suffix == "" {
			return candidate.URL
		}
		if parsed, err := url.Parse(candidate.URL); err == nil && strings.ToLower(path.Ext(parsed.Path)) == suffix {
			return candidate.URL
		}
		return ""
	}
	if address := consider(media); address != "" {
		return address
	}
	for _, variant := range media.Variants {
		if address := consider(variant); address != "" {
			return address
		}
	}
	return ""
}

// nativeRenewAsset 在媒体地址失效（403/404/410）时重新解析并热替换会话内
// 该资产的地址。本机代理地址（assetId）保持不变，播放器无感知地续传；
// 冷却期按资产分别记录，已在队列中等待的请求醒来后直接复用首个请求刷新
// 出的新地址。
func (session *nativeStreamSession) nativeRenewAsset(ctx context.Context, id, oldAddress string) (string, bool) {
	session.mu.Lock()
	asset, found := session.assets[id]
	since := time.Since(session.renewedByID[id])
	session.mu.Unlock()
	if found && asset.address != oldAddress {
		return asset.address, true
	}
	if session.refresher == nil {
		return "", false
	}
	if !session.renewedByID[id].IsZero() && since < 5*time.Second {
		return "", false
	}
	media, err := session.refresher(ctx)
	session.mu.Lock()
	if session.renewedByID == nil {
		session.renewedByID = map[string]time.Time{}
	}
	session.renewedByID[id] = time.Now()
	session.renewedAt = time.Now()
	session.mu.Unlock()
	if err != nil {
		return "", false
	}
	address := nativeRenewedURL(media, oldAddress)
	if address == "" {
		return "", false
	}
	session.mu.Lock()
	if asset, found := session.assets[id]; found && asset.address == oldAddress {
		asset.address = address
		session.assets[id] = asset
	}
	session.mu.Unlock()
	return address, true
}

// nativeRenewAssetAsync 在后台发起重签并返回结果通道。
//
// 重签要走整条解析链：红果的 App 取流接口已失效时要退回网页兜底，
// 一次解析实测要 8 秒以上，堵在播放器的请求线程里等于直接卡死画面。
// 改为后台重签 + 短暂等待窗口：命中新地址就用它重试，否则把失败交回
// 播放器；播放器重试同一请求时资产地址已被热替换，直接命中新地址。
func (session *nativeStreamSession) nativeRenewAssetAsync(ctx context.Context, id, oldAddress string) <-chan nativeRenewResult {
	session.renewMu.Lock()
	if session.renewing == nil {
		session.renewing = map[string]chan nativeRenewResult{}
	}
	if existing, found := session.renewing[id]; found {
		session.renewMu.Unlock()
		return existing
	}
	results := make(chan nativeRenewResult, 1)
	session.renewing[id] = results
	session.renewMu.Unlock()
	go func() {
		// 重签必须换一条真实地址：带上强制标记，绕开源侧的「零网络直链
		// 快速通道」，否则会在同一个失效地址上空转。
		renewCtx := context.WithValue(ctx, hongguoFullResolveKey{}, true)
		address, ok := session.nativeRenewAsset(renewCtx, id, oldAddress)
		results <- nativeRenewResult{address: address, ok: ok}
		close(results)
		session.renewMu.Lock()
		delete(session.renewing, id)
		session.renewMu.Unlock()
	}()
	return results
}

// nativeLastUsed 返回流会话最近一次被播放器读取的时间；会话已不存在时
// 返回零值（视为完全空闲），供播放会话逐出时优先清理。
func (stream *nativeStreamServer) nativeLastUsed(token string) time.Time {
	stream.mu.Lock()
	defer stream.mu.Unlock()
	if session := stream.sessions[token]; session != nil {
		return session.lastUsed
	}
	return time.Time{}
}

// nativeForward 将播放器对资产代理地址的请求转发到真实媒体地址。红果等
// 站源的 CDN 直链自带短时效签名，且首次请求可能随机 404，因此转发失败
// 时先对原地址重试一次，仍失败（403/404/410）再经会话 refresher 重新解
// 析并热替换资产地址后重试，把地址过期对播放器的影响收敛在本机代理内。
func (stream *nativeStreamServer) nativeForward(ctx context.Context, request *http.Request, session *nativeStreamSession, id string, asset nativeStreamAsset) (*http.Response, *http.Request) {
	attempt := func(address string) (*http.Response, *http.Request) {
		upstream, err := http.NewRequestWithContext(ctx, request.Method, address, nil)
		if err != nil {
			return nil, nil
		}
		upstream.Header.Set("User-Agent", hongguoWebMediaUserAgent(address))
		upstream.Header.Set("Referer", session.referer)
		for _, name := range []string{"Range", "If-Range"} {
			if value := request.Header.Get(name); value != "" {
				upstream.Header.Set(name, value)
			}
		}
		response, err := stream.nativeRequest(upstream)
		if err != nil {
			return nil, upstream
		}
		return response, upstream
	}
	retryable := func(response *http.Response) bool {
		switch response.StatusCode {
		case http.StatusForbidden, http.StatusNotFound, http.StatusRequestTimeout,
			http.StatusGone, http.StatusTooManyRequests,
			http.StatusInternalServerError, http.StatusBadGateway,
			http.StatusServiceUnavailable, http.StatusGatewayTimeout:
			return true
		}
		return false
	}
	renewable := func(response *http.Response) bool {
		switch response.StatusCode {
		case http.StatusForbidden, http.StatusNotFound, http.StatusGone:
			return true
		}
		return false
	}
	discard := func(response *http.Response) {
		if response == nil {
			return
		}
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		response.Body.Close()
	}
	response, upstream := attempt(asset.address)
	// 源站对同一直链会随机返回 404/502（CDN 未就绪，几百毫秒后就绪）。
	// 同址带退避重试比换地址快得多：换地址要重走整条解析链（数秒）。
	for retry := 0; retry < 3 && (response == nil || retryable(response)); retry++ {
		discard(response)
		select {
		case <-ctx.Done():
			return nil, upstream
		case <-time.After(time.Duration(150*(retry+1)) * time.Millisecond):
		}
		response, upstream = attempt(asset.address)
	}
	if response != nil && renewable(response) {
		// 后台重签 + 短暂等待：整条解析链可能要数秒，不能堵在播放器的
		// 请求线程里。等待窗口内拿到新地址就重试，否则交回播放器——它
		// 重试同一请求时资产地址已被热替换，会直接命中新地址。
		results := session.nativeRenewAssetAsync(ctx, id, asset.address)
		select {
		case renewed := <-results:
			if renewed.ok {
				discard(response)
				response, upstream = attempt(renewed.address)
			}
		case <-time.After(nativeRenewWait):
		}
	}
	return response, upstream
}

func (stream *nativeStreamServer) nativeServe(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodGet && request.Method != http.MethodHead {
		writer.WriteHeader(http.StatusMethodNotAllowed)
		return
	}
	parts := strings.Split(strings.Trim(request.URL.Path, "/"), "/")
	if len(parts) != 2 {
		http.NotFound(writer, request)
		return
	}
	stream.mu.Lock()
	session := stream.sessions[parts[0]]
	if session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if session == nil {
		http.Error(writer, "播放已结束", http.StatusGone)
		return
	}
	session.mu.Lock()
	asset, found := session.assets[parts[1]]
	session.mu.Unlock()
	if !found {
		http.NotFound(writer, request)
		return
	}
	ctx, cancel := context.WithCancel(providerMediaContext(request.Context(), session.credentials))
	defer cancel()
	stop := context.AfterFunc(session.ctx, cancel)
	defer stop()
	writer.Header().Set("Cache-Control", "no-store")
	if len(asset.data) > 0 && asset.total > int64(len(asset.data)) {
		if stream.nativeServePrefix(ctx, writer, request, session, asset) {
			return
		}
		asset.data = nil
	}
	if len(asset.data) > 0 {
		if strings.Contains(asset.contentType, "mpegurl") {
			body, err := stream.nativeRewrite(parts[0], session, string(asset.data), asset.address)
			if err != nil {
				http.Error(writer, err.Error(), http.StatusBadGateway)
				return
			}
			writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			if request.Method == http.MethodGet {
				_, _ = io.WriteString(writer, body)
			}
		} else {
			writer.Header().Set("Content-Type", asset.contentType)
			if asset.etag != "" {
				writer.Header().Set("ETag", asset.etag)
			}
			http.ServeContent(writer, request, parts[1], time.Time{}, bytes.NewReader(asset.data))
		}
		return
	}
	if len(asset.data) == 0 && !strings.Contains(asset.contentType, "mpegurl") {
		// 直链媒体：后台单连接把整集拉进本地缓存，播放器的请求改读本地文件。
		// 源站响应头排队实测最长 27 秒，这一刻提前付掉，切集才是零等待；
		// 缓存没就绪时再走回源路径（见 nativeForward）。
		stream.nativeStartPrefetch(session, parts[1], asset, 0)
		if stream.nativeServeCached(ctx, writer, request, session, parts[1], asset) {
			return
		}
	}
	response, upstream := stream.nativeForward(ctx, request, session, parts[1], asset)
	if response == nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusPartialContent {
		body, _ := io.ReadAll(io.LimitReader(response.Body, 64<<10))
		err := stream.downloader.catalogResponseError(upstream, response, body)
		http.Error(writer, err.Error(), response.StatusCode)
		return
	}
	// 回源确认是整集大文件后，在后台预读一份到本机：播放器的后续 Range
	// 请求即可零等待命中本地，把源站的首字节抖动挡在代理之外。
	stream.nativeStartPrefetch(session, parts[1], asset, response.ContentLength)
	contentType := strings.ToLower(response.Header.Get("Content-Type"))
	finalURL := upstream.URL
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL
	}
	playlist := strings.Contains(asset.contentType, "mpegurl") || strings.Contains(contentType, "mpegurl") || strings.HasSuffix(strings.ToLower(finalURL.Path), ".m3u8")
	if request.Method == http.MethodGet && !playlist {
		prefix := make([]byte, 512)
		read, _ := io.ReadFull(response.Body, prefix)
		head := strings.TrimSpace(strings.TrimPrefix(string(prefix[:read]), "\ufeff"))
		if strings.HasPrefix(head, "#EXTM3U") {
			playlist = true
		}
		response.Body = io.NopCloser(io.MultiReader(bytes.NewReader(prefix[:read]), response.Body))
	}
	if playlist && request.Method == http.MethodHead {
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		writer.WriteHeader(http.StatusOK)
		return
	}
	if playlist && request.Method == http.MethodGet {
		body, err := io.ReadAll(io.LimitReader(response.Body, 4<<20+1))
		if err != nil || len(body) > 4<<20 {
			http.Error(writer, "播放列表过大或读取失败", http.StatusBadGateway)
			return
		}
		text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
		if !strings.HasPrefix(text, "#EXTM3U") {
			http.Error(writer, "播放列表无效", http.StatusBadGateway)
			return
		}
		rewritten, err := stream.nativeRewrite(parts[0], session, text, finalURL.String())
		if err != nil {
			http.Error(writer, err.Error(), http.StatusBadGateway)
			return
		}
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(writer, rewritten)
		return
	}
	for _, name := range []string{"Content-Type", "Content-Length", "Content-Range", "Accept-Ranges", "ETag", "Last-Modified"} {
		if value := response.Header.Get(name); value != "" {
			writer.Header().Set(name, value)
		}
	}
	writer.WriteHeader(response.StatusCode)
	if request.Method == http.MethodGet {
		_, _ = io.Copy(writer, response.Body)
	}
}
