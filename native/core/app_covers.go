package core

import (
	"bytes"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
	"time"
)

const nativeCoverMaxBytes = 20 << 20
const nativeCoverCacheBytes = 256 << 20
const nativeCoverCacheEntries = 2000
const nativeCoverTTL = 30 * 24 * time.Hour

// nativeCoverFetchTimeout 单张封面的下载超时。
//
// 正常封面（几十~几百 KB）实测 60~300ms，25 秒的超时只会让网络病态的图片
// 长时间占住并发槽：12 个槽被占满后，后面所有新封面都停在占位态，用户眼里
// 就是「新卡片一直不出图」。10 秒足够跨弱网重试，失败也能让槽位尽快回收。
const nativeCoverFetchTimeout = 10 * time.Second

// nativeCoverFailureTTL 封面下载失败后的冷却期。
//
// 失败不写缓存，同一 URL 每次渲染都会重新完整下载——列表反复重建时形成重试
// 风暴，把并发槽与流量全耗在注定失败的图上。冷却期内直接回报失败，用户点
// 「重试海报」（force=true）可立即绕过。
const nativeCoverFailureTTL = 60 * time.Second

type nativeCoverEntry struct {
	size      int64
	updatedAt time.Time
	usedAt    time.Time
}

type nativeCoverCall struct {
	done chan struct{}
	path string
	err  error
}

type nativeCoverCache struct {
	directory   string
	downloader  *Downloader
	mu          sync.Mutex
	entries     map[string]nativeCoverEntry
	pending     map[string]*nativeCoverCall
	slots       chan struct{}
	repairSlots chan struct{}
	repairs     map[string]*nativeCoverRepair
	// failures 失败冷却表（key → 失败时刻）：冷却期内同 URL 直接回报失败，
	// 避免「注定失败的图」反复占槽把正常封面的队列拖死。
	failures map[string]time.Time
	size     int64
	limit    int64
}

func newNativeCoverCache(directory string, downloader *Downloader) *nativeCoverCache {
	cache := &nativeCoverCache{
		directory: filepath.Join(directory, "covers-v1"), downloader: downloader,
		entries: map[string]nativeCoverEntry{}, pending: map[string]*nativeCoverCall{},
		// 封面是小图、IO 密集：原 4 槽在列表首屏十几张未缓存海报 +
		// 详情预取并发抢占 6 个全局 worker 时，会让海报长时间排队停在占位态。
		// 提到 12 让首屏批量封面几乎同时下载，几秒内陆续出图。
		slots: make(chan struct{}, 12), limit: nativeCoverCacheBytes,
		repairSlots: make(chan struct{}, 1), repairs: map[string]*nativeCoverRepair{},
		failures: map[string]time.Time{},
	}
	files, _ := os.ReadDir(cache.directory)
	for _, file := range files {
		if strings.HasPrefix(file.Name(), ".decode-") && !file.IsDir() {
			if info, err := file.Info(); err == nil && time.Since(info.ModTime()) > time.Hour {
				_ = os.Remove(filepath.Join(cache.directory, file.Name()))
			}
		}
		key, valid := strings.CutSuffix(file.Name(), ".img")
		if !valid || len(key) != 64 || file.IsDir() {
			continue
		}
		if _, err := hex.DecodeString(key); err != nil {
			continue
		}
		info, err := file.Info()
		if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 || info.Size() > nativeCoverMaxBytes {
			continue
		}
		cache.entries[key] = nativeCoverEntry{size: info.Size(), updatedAt: info.ModTime(), usedAt: info.ModTime()}
		cache.size += info.Size()
	}
	cache.prune("")
	return cache
}

func nativeCoverReferer(downloader *Downloader, source, address string) string {
	// 豆瓣图片 CDN 校验 Referer 域：非 douban 域 Referer 一律 403（无
	// Referer 反而放行）。榜单条目封面必须带豆瓣站内 Referer 才能下载。
	if source == sourceDouban {
		return doubanReferer
	}
	if parsed, err := url.Parse(address); err == nil &&
		strings.HasSuffix(strings.ToLower(parsed.Hostname()), "doubanio.com") {
		return doubanReferer
	}
	// 百度图片中转（真果·鉴 poster_url 走 gimg*.baidu.com?src=源站地址）
	// 把携带 Referer 的请求判为盗链直接 400，无 Referer 反而放行——
	// 这类中转域名一律不发 Referer。
	if parsed, err := url.Parse(address); err == nil &&
		strings.HasSuffix(strings.ToLower(parsed.Hostname()), ".baidu.com") {
		return ""
	}
	if source == sourceCloudFront {
		if parsed, err := url.Parse(address); err == nil && (strings.HasSuffix(strings.ToLower(parsed.Hostname()), ".zdmhyg.cn") || strings.EqualFold(parsed.Hostname(), "pic.tuafjz.cn")) {
			return downloader.providerBaseURL(sourceHuangguoAI) + "/"
		}
	}
	if source == sourceHuangdou {
		if parsed, err := url.Parse(address); err == nil && (strings.EqualFold(parsed.Hostname(), "tideember.cc") || strings.EqualFold(parsed.Hostname(), "xqjurgek.top")) {
			return parsed.Scheme + "://" + parsed.Host + "/home"
		}
		downloader.providerMu.Lock()
		host := downloader.providerHosts[source]
		downloader.providerMu.Unlock()
		if host == "" {
			host = downloader.providerBaseURL(source)
		}
		return host + "/home"
	}
	return downloader.providerBaseURL(source) + "/"
}

func validNativeCoverURL(address *url.URL) bool {
	return address != nil && (address.Scheme == "https" || address.Scheme == "http") && address.Hostname() != "" && address.User == nil
}

func (cache *nativeCoverCache) loadAddress(ctx context.Context, drama nativeDrama, force bool) (string, error) {
	drama.Cover = repairLegacyCoverURL(drama)
	address, err := url.Parse(drama.Cover)
	if err != nil || !validNativeCoverURL(address) {
		return "", errors.New("海报地址无效")
	}
	source := canonicalProviderSource(drama.Source)
	if source == "" {
		source = sourceFromDramaID(drama.ID)
	}
	referer := nativeCoverReferer(cache.downloader, source, drama.Cover)
	// 缓存键只认「来源 + 图片地址」：Referer 是请求头，不是资源身份。
	// 之前把 referer 也算进键里，站源优选域名一变（学到的镜像换了），
	// 同一张图就算成新资源——已缓存的封面全部失效，过期兜底也跟着失效。
	digest := sha256.Sum256([]byte(source + "\x00" + drama.Cover))
	key := hex.EncodeToString(digest[:])
	path := filepath.Join(cache.directory, key+".img")
	cache.mu.Lock()
	fallback := ""
	// 失败冷却：磁盘上没有这份图、上次下载又刚失败过，直接回报失败。
	// 否则列表每次重建都会重跑一遍注定失败的下载（重试风暴），把
	// 12 个并发槽全占住、正常封面排到队尾永远出不来。
	if !force {
		if failedAt, failed := cache.failures[key]; failed {
			if time.Since(failedAt) < nativeCoverFailureTTL {
				cache.mu.Unlock()
				return "", errors.New("海报暂不可用，请稍后重试")
			}
			delete(cache.failures, key)
		}
	}
	if entry, found := cache.entries[key]; found {
		if info, err := os.Stat(path); err == nil && info.Mode().IsRegular() && info.Size() == entry.size {
			entry.usedAt = time.Now()
			cache.entries[key] = entry
			age := time.Since(entry.updatedAt)
			if !force && age >= 0 && age < nativeCoverTTL {
				cache.mu.Unlock()
				return path, nil
			}
			if !force {
				fallback = path
			}
		} else {
			delete(cache.entries, key)
			cache.size -= entry.size
		}
	}
	call := cache.pending[key]
	if call == nil {
		if len(cache.pending) >= 256 {
			cache.mu.Unlock()
			return "", errors.New("海报正在加载，请稍后重试")
		}
		call = &nativeCoverCall{done: make(chan struct{})}
		cache.pending[key] = call
		go cache.fetch(key, drama, referer, fallback, call)
	}
	cache.mu.Unlock()
	select {
	case <-ctx.Done():
		return "", ctx.Err()
	case <-call.done:
		return call.path, call.err
	}
}

func (cache *nativeCoverCache) fetch(key string, drama nativeDrama, referer, fallback string, call *nativeCoverCall) {
	ctx, cancel := context.WithTimeout(context.Background(), nativeCoverFetchTimeout)
	defer cancel()
	var data []byte
	var err error
	// 排队等并发槽超时 ≠ 图片下载失败：弱网首屏批量取图时，队尾图片可能
	// 一次都没请求过就被判死并冷却 60 秒。这类错误单独标记，不写失败表。
	queueTimeout := false
	select {
	case cache.slots <- struct{}{}:
		data, err = cache.download(ctx, drama.Cover, referer)
		<-cache.slots
	case <-ctx.Done():
		err = ctx.Err()
		queueTimeout = true
	}
	path := filepath.Join(cache.directory, key+".img")
	cache.mu.Lock()
	defer cache.mu.Unlock()
	if err == nil {
		err = writeNativeCacheFile(path, data)
		if err == nil {
			cache.size -= cache.entries[key].size
			now := time.Now()
			cache.entries[key] = nativeCoverEntry{size: int64(len(data)), updatedAt: now, usedAt: now}
			cache.size += int64(len(data))
			cache.prune(key)
			call.path = path
		}
	}
	if err != nil && fallback != "" {
		if _, statErr := os.Stat(fallback); statErr == nil {
			call.path, err = fallback, nil
		}
	}
	call.err = err
	delete(cache.pending, key)
	close(call.done)
	if err != nil {
		// 记一次失败冷却（调用方持有 cache.mu）：冷却期内同 URL 不再发起下载。
		// 排队超时不记：那不是这张图的问题，记了会让正常封面 60 秒内报错。
		if !queueTimeout {
			if len(cache.failures) >= 1024 {
				cache.failures = map[string]time.Time{}
			}
			cache.failures[key] = time.Now()
		}
		cache.downloader.recordDiagnostic(diagnosticEvent{Event: "cover_failed", Source: drama.Source, DramaID: drama.ID, Message: err.Error()})
	} else {
		delete(cache.failures, key)
	}
}

func (cache *nativeCoverCache) download(ctx context.Context, address, referer string) ([]byte, error) {
	request, err := http.NewRequestWithContext(context.WithValue(ctx, nativeCoverNetworkKey{}, true), http.MethodGet, address, nil)
	if err != nil {
		return nil, err
	}
	request.Header.Set("User-Agent", userAgent)
	if referer != "" {
		request.Header.Set("Referer", referer)
	}
	request.Header.Set("Accept", "image/webp,image/jpeg,image/png,image/gif,*/*;q=0.5")
	request.Header.Set("Sec-Fetch-Mode", "no-cors")
	request.Header.Set("Sec-Fetch-Dest", "image")
	client := *cache.downloader.client
	client.CheckRedirect = func(request *http.Request, via []*http.Request) error {
		if len(via) >= 5 || !validNativeCoverURL(request.URL) {
			return errors.New("海报重定向地址无效")
		}
		if referer != "" {
			request.Header.Set("Referer", referer)
		}
		return nil
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("海报请求失败：HTTP %d", response.StatusCode)
	}
	if response.ContentLength > nativeCoverMaxBytes {
		return nil, errors.New("海报文件过大")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, nativeCoverMaxBytes+1))
	if err != nil {
		return nil, err
	}
	if len(data) > nativeCoverMaxBytes {
		return nil, errors.New("海报文件过大")
	}
	data = nativeDecodeCover(data)
	if !nativeIsCoverImage(data) {
		return nil, errors.New("站源未返回有效海报")
	}
	return data, nil
}

func nativeDecodeCover(data []byte) []byte {
	if nativeIsCoverImage(data) {
		return data
	}
	// 笔盒（beabox）封面是「data:image/...;base64,...」纯文本，前 4096 字节
	// 逐字节 XOR 0x12（站点前端 ab() 的默认 key=18/decryptSize=4096），因此
	// 下载回来的开头是 "vsfs({" 之类的乱码，既不是图片也不是 base64。
	// 先按这个规则还原，再走后面的通用解密链。
	if decoded := decodeBeaboxDataURLCover(data); decoded != nil && nativeIsCoverImage(decoded) {
		return decoded
	}
	encrypted := data
	if bytes.HasPrefix(encrypted, []byte("Salted__")) && len(encrypted) > 16 {
		encrypted = encrypted[16:]
	}
	if len(encrypted) > 0 {
		block, err := aes.NewCipher([]byte("f5d965df75336270"))
		if err == nil {
			plain := make([]byte, (len(encrypted)+aes.BlockSize-1)/aes.BlockSize*aes.BlockSize)
			copy(plain, encrypted)
			cipher.NewCBCDecrypter(block, []byte("97b60394abc2fbe1")).CryptBlocks(plain, plain)
			plain = plain[:len(encrypted)]
			if unpadded, err := pkcs7Unpad(plain, aes.BlockSize); err == nil {
				plain = unpadded
			}
			if nativeIsCoverImage(plain) {
				return plain
			}
		}
	}
	plain := append([]byte(nil), data...)
	key := []byte("2019ysapp7527")
	for index := 0; index < min(100, len(plain)); index++ {
		plain[index] ^= key[index%len(key)]
	}
	if nativeIsCoverImage(plain) {
		return plain
	}
	return data
}

// decodeBeaboxDataURLCover 还原笔盒封面：整份文件其实是
// 「data:image/<type>;base64,<payload>」文本，只有前 beaboxCoverXorBytes
// 个字节被逐字节 XOR beaboxCoverXorKey（站点前端 ab() 的默认参数）。
// 还原后按 data URL 解析出图片字节；不是这种格式时返回 nil。
func decodeBeaboxDataURLCover(data []byte) []byte {
	const (
		beaboxCoverXorKey   = byte(18)
		beaboxCoverXorBytes = 4096
	)
	if len(data) < 16 {
		return nil
	}
	plain := append([]byte(nil), data...)
	for index := 0; index < min(beaboxCoverXorBytes, len(plain)); index++ {
		plain[index] ^= beaboxCoverXorKey
	}
	if !bytes.HasPrefix(plain, []byte("data:")) {
		return nil
	}
	comma := bytes.IndexByte(plain, ',')
	if comma < 0 || comma > 256 || !bytes.Contains(plain[:comma], []byte("base64")) {
		return nil
	}
	payload := bytes.TrimSpace(plain[comma+1:])
	if len(payload) == 0 {
		return nil
	}
	decoded := make([]byte, base64.StdEncoding.DecodedLen(len(payload)))
	count, err := base64.StdEncoding.Decode(decoded, payload)
	if err != nil {
		decoded = make([]byte, base64.RawStdEncoding.DecodedLen(len(payload)))
		count, err = base64.RawStdEncoding.Decode(decoded, payload)
		if err != nil {
			return nil
		}
	}
	return decoded[:count]
}

func nativeIsCoverImage(data []byte) bool {
	if isHEICImage(data) {
		return true
	}
	if bytes.HasPrefix(data, []byte{0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n'}) ||
		bytes.HasPrefix(data, []byte{0xff, 0xd8, 0xff}) || bytes.HasPrefix(data, []byte("GIF87a")) || bytes.HasPrefix(data, []byte("GIF89a")) {
		return true
	}
	if len(data) >= 12 && string(data[:4]) == "RIFF" && string(data[8:12]) == "WEBP" {
		return true
	}
	if len(data) >= 16 && string(data[4:8]) == "ftyp" {
		switch string(data[8:12]) {
		case "avif", "avis", "heic", "heix", "hevc", "hevx", "mif1":
			return true
		}
	}
	return false
}

func (cache *nativeCoverCache) prune(keep string) {
	if cache.size <= cache.limit && len(cache.entries) <= nativeCoverCacheEntries {
		return
	}
	keys := make([]string, 0, len(cache.entries))
	for key := range cache.entries {
		if key != keep {
			keys = append(keys, key)
		}
	}
	sort.Slice(keys, func(i, j int) bool { return cache.entries[keys[i]].usedAt.Before(cache.entries[keys[j]].usedAt) })
	for _, key := range keys {
		if cache.size <= cache.limit && len(cache.entries) <= nativeCoverCacheEntries {
			break
		}
		if err := os.Remove(filepath.Join(cache.directory, key+".img")); err == nil || errors.Is(err, os.ErrNotExist) {
			cache.size -= cache.entries[key].size
			delete(cache.entries, key)
		}
	}
}
