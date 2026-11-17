package core

import (
	"bytes"
	"compress/gzip"
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
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
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	beaboxGatewayURL = "https://beabox.cc"
	beaboxAPIPrefix  = "/api"
	beaboxUserAgent  = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
	beaboxPageSize   = 20
	beaboxCacheTTL   = 30 * time.Minute
	// beaboxHostFile 持久化「上次可用线路」，重启后先试它，
	// 避免每次冷启动都从发布页重新发现域名。
	beaboxHostFile = "beabox_host.json"
)

// 笔盒接口响应为 AES-128-CBC 密文，key 由前端 bundle 硬编码。
var beaboxResponseKey = []byte{
	0xf6, 0x32, 0x2f, 0xa1, 0xc0, 0x64, 0x37, 0x0e,
	0xa4, 0x0c, 0x8c, 0xdc, 0x20, 0x64, 0x9f, 0x8e,
}

// 发布网关（会轮换），内嵌 __ENC_DOMAINS 给出当前 bh*.top 真实域。
var beaboxGatewayHosts = []string{"beabox.cc", "bihe198.com", "beabox.live"}

// 内置兜底真实域（从网关解出），网关解密失败时直接尝试。
var beaboxFallbackHosts = []string{
	"bh4066.top", "bh4254.top", "bh4287.top", "bh4362.top", "bh4549.top",
	"bh5530.top", "bh6246.top", "bh6291.top", "bh6429.top", "bh6831.top",
}

var (
	reBeaboxEncDomains = regexp.MustCompile(`(?s)__ENC_DOMAINS\s*=\s*["']([^"']+)["']`)
	reBeaboxKey        = regexp.MustCompile(`(?s)__KEY\s*=\s*["']([^"']+)["']`)
)

var beaboxDomainCache struct {
	mu        sync.Mutex
	base      string
	expires   time.Time
	failUntil time.Time
}

const (
	// beaboxProbeBudget 单次域名探测的总预算。10 个候选 + 3 个发现网关逐跳
	// 15s 时最坏会阻塞 195s，且全程占着 HTTP 限流槽，必须整体封顶。
	beaboxProbeBudget = 10 * time.Second
	// beaboxFailCooldown 探测失败后的冷却：期间直接报错，不再重探。
	beaboxFailCooldown = 60 * time.Second
)

func beaboxXorDecode(encoded, key string) ([]string, error) {
	raw, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		raw, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(encoded, "="))
		if err != nil {
			return nil, errors.New("笔盒域名网关解码失败")
		}
	}
	if len(key) == 0 {
		return nil, errors.New("笔盒域名网关缺少密钥")
	}
	out := make([]byte, len(raw))
	for i, b := range raw {
		out[i] = b ^ key[i%len(key)]
	}
	var domains []string
	if json.Unmarshal(out, &domains) != nil || len(domains) == 0 || len(domains) > 200 {
		return nil, errors.New("笔盒域名网关格式无效")
	}
	valid := make([]string, 0, len(domains))
	for _, domain := range domains {
		domain = strings.TrimSpace(strings.ToLower(domain))
		if domain == "" || len(domain) > 200 || strings.ContainsAny(domain, "/\\ \x00\r\n") {
			continue
		}
		valid = append(valid, domain)
	}
	if len(valid) == 0 {
		return nil, errors.New("笔盒域名网关无有效域名")
	}
	return valid, nil
}

func (d *Downloader) beaboxGetBytes(ctx context.Context, base, path string) ([]byte, error) {
	address := strings.TrimRight(base, "/") + path
	parsed, err := url.Parse(address)
	if err != nil || parsed.Scheme != "https" || parsed.User != nil || parsed.Host == "" {
		return nil, errors.New("笔盒接口地址无效")
	}
	timeout := 15 * time.Second
	if background, _ := ctx.Value(backgroundCatalogKey{}).(bool); background {
		timeout = 8 * time.Second
	}
	requestCtx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	request, err := http.NewRequestWithContext(requestCtx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("无法创建笔盒请求")
	}
	request.Header.Set("User-Agent", beaboxUserAgent)
	request.Header.Set("Accept", "application/json, text/plain, */*")
	request.Header.Set("Referer", strings.TrimRight(base, "/")+"/")
	if d.limiter != nil {
		release, err := d.limiter.acquire(requestCtx, request)
		if err != nil {
			return nil, err
		}
		defer release()
	}
	client := d.client
	if client == nil {
		client = http.DefaultClient
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("笔盒连接失败：%w", publicError(err))
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, 16<<20))
	if err != nil {
		return nil, errors.New("笔盒响应读取失败")
	}
	if len(data) >= 2 && data[0] == 0x1f && data[1] == 0x8b {
		reader, gzipErr := gzip.NewReader(bytes.NewReader(data))
		if gzipErr == nil {
			if inflated, readErr := io.ReadAll(io.LimitReader(reader, 16<<20)); readErr == nil {
				data = inflated
			}
			reader.Close()
		}
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, fmt.Errorf("笔盒接口返回状态 %d", response.StatusCode)
	}
	return data, nil
}

func beaboxDecrypt(hexPayload string) (any, error) {
	raw, err := hex.DecodeString(strings.TrimSpace(hexPayload))
	if err != nil || len(raw) < 32 || len(raw)%aes.BlockSize != 0 {
		return nil, errors.New("笔盒响应密文格式无效")
	}
	block, err := aes.NewCipher(beaboxResponseKey)
	if err != nil {
		return nil, errors.New("笔盒响应解密失败")
	}
	iv, ciphertext := raw[:aes.BlockSize], raw[aes.BlockSize:]
	out := make([]byte, len(ciphertext))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, ciphertext)
	if padding := int(out[len(out)-1]); padding > 0 && padding <= aes.BlockSize && len(out) >= padding {
		out = out[:len(out)-padding]
	}
	var decoded any
	decoder := json.NewDecoder(bytes.NewReader(out))
	decoder.UseNumber()
	if decoder.Decode(&decoded) != nil {
		return nil, errors.New("笔盒响应解析失败")
	}
	return decoded, nil
}

func (d *Downloader) beaboxAPIGet(ctx context.Context, base, path string) (any, error) {
	raw, err := d.beaboxGetBytes(ctx, base, beaboxAPIPrefix+path)
	if err != nil {
		return nil, err
	}
	var envelope struct {
		Code any    `json:"code"`
		Msg  string `json:"msg"`
		Data any    `json:"data"`
	}
	if json.Unmarshal(raw, &envelope) != nil {
		return nil, errors.New("笔盒接口返回格式无效")
	}
	payload, ok := envelope.Data.(string)
	if !ok || payload == "" {
		// 少数接口直接返回明文结构
		if envelope.Data != nil {
			return envelope.Data, nil
		}
		return nil, errors.New("笔盒接口返回空数据")
	}
	return beaboxDecrypt(payload)
}

func (d *Downloader) beaboxDiscoverDomains(ctx context.Context) []string {
	var hosts []string
	for _, host := range beaboxGatewayHosts {
		raw, err := d.beaboxGetBytes(ctx, "https://"+host, "/")
		if err != nil {
			continue
		}
		enc := reBeaboxEncDomains.FindSubmatch(raw)
		key := reBeaboxKey.FindSubmatch(raw)
		if len(enc) < 2 || len(key) < 2 {
			continue
		}
		domains, err := beaboxXorDecode(string(enc[1]), string(key[1]))
		if err != nil {
			continue
		}
		hosts = append(hosts, domains...)
	}
	return hosts
}

// beaboxStoredHost 读取上次探测成功的线路；文件缺失/内容无效时返回空串。
func (d *Downloader) beaboxStoredHost() string {
	if strings.TrimSpace(d.cfg.dataDir) == "" {
		return ""
	}
	raw, err := os.ReadFile(filepath.Join(d.cfg.dataDir, beaboxHostFile))
	if err != nil {
		return ""
	}
	var stored struct {
		Host string `json:"host"`
	}
	if json.Unmarshal(raw, &stored) != nil {
		return ""
	}
	parsed, err := url.Parse(strings.TrimSpace(stored.Host))
	if err != nil || parsed.Scheme != "https" || parsed.Host == "" {
		return ""
	}
	return strings.TrimRight(parsed.Scheme+"://"+parsed.Host, "/")
}

// beaboxStoreHost 记住本次探测成功的线路；写盘失败不影响本次使用。
func (d *Downloader) beaboxStoreHost(base string) {
	if strings.TrimSpace(d.cfg.dataDir) == "" || base == "" {
		return
	}
	data, err := json.Marshal(map[string]string{"host": base})
	if err != nil {
		return
	}
	_ = os.MkdirAll(d.cfg.dataDir, 0700)
	_ = nativeDownloadWrite(filepath.Join(d.cfg.dataDir, beaboxHostFile), data)
}

func (d *Downloader) beaboxResolveBase(ctx context.Context) (string, error) {
	if pinned := strings.TrimSpace(d.cfg.BeaboxURL); pinned != "" {
		if parsed, err := url.Parse(pinned); err == nil && parsed.Scheme == "https" && parsed.Host != "" {
			return strings.TrimRight(parsed.Scheme+"://"+parsed.Host, "/"), nil
		}
	}
	beaboxDomainCache.mu.Lock()
	if beaboxDomainCache.base != "" && time.Now().Before(beaboxDomainCache.expires) {
		base := beaboxDomainCache.base
		beaboxDomainCache.mu.Unlock()
		return base, nil
	}
	// 冷却期内直接报错：以前 failUntil 只写不读，探测失败后每个请求都会把
	// 10 个内置候选 + 3 个发现网关重跑一遍，最长占住限流槽几分钟。
	if time.Now().Before(beaboxDomainCache.failUntil) {
		beaboxDomainCache.mu.Unlock()
		return "", errors.New("笔盒线路暂不可用，请稍后重试")
	}
	beaboxDomainCache.mu.Unlock()

	// 单次探测总预算：逐跳 15s × 13 个候选最坏能阻塞 195s，必须整体封顶。
	ctx, cancel := context.WithTimeout(ctx, beaboxProbeBudget)
	defer cancel()

	// 上次可用线路（落盘）：命中即用，避免每次冷启动都走发布页发现域名。
	if stored := d.beaboxStoredHost(); stored != "" {
		if _, err := d.beaboxAPIGet(ctx, stored, "/vod/latest?page=1&limit=1"); err == nil {
			beaboxDomainCache.mu.Lock()
			beaboxDomainCache.base = stored
			beaboxDomainCache.expires = time.Now().Add(beaboxCacheTTL)
			beaboxDomainCache.mu.Unlock()
			return stored, nil
		}
	}

	candidates := append([]string(nil), beaboxFallbackHosts...)
	candidates = append(candidates, d.beaboxDiscoverDomains(ctx)...)
	seen := map[string]bool{}
	for _, host := range candidates {
		if seen[host] {
			continue
		}
		seen[host] = true
		base := "https://" + host
		if _, err := d.beaboxAPIGet(ctx, base, "/vod/latest?page=1&limit=1"); err == nil {
			beaboxDomainCache.mu.Lock()
			beaboxDomainCache.base = base
			beaboxDomainCache.expires = time.Now().Add(beaboxCacheTTL)
			beaboxDomainCache.mu.Unlock()
			d.beaboxStoreHost(base)
			return base, nil
		}
		if ctx.Err() != nil {
			break
		}
	}
	beaboxDomainCache.mu.Lock()
	beaboxDomainCache.failUntil = time.Now().Add(beaboxFailCooldown)
	beaboxDomainCache.mu.Unlock()
	return "", errors.New("笔盒线路暂不可用，请稍后重试")
}

func beaboxDramaFromRow(row map[string]any, site string) (Drama, error) {
	id := strings.TrimSpace(mapString(row, "vodId"))
	title := strings.TrimSpace(mapString(row, "vodName"))
	if id == "" || len(id) > 40 || title == "" {
		return Drama{}, errors.New("笔盒条目资料不完整")
	}
	cover := providerCoverAddress(firstPresent(row, "vodPic", "vodThumb", "vodPreview"), site+"/")
	var tags []string
	seen := map[string]bool{}
	if classes, ok := row["vodClass"].([]any); ok {
		for _, value := range classes {
			tag := strings.TrimSpace(nativeText(value))
			if tag == "" || len([]rune(tag)) > 24 || seen[tag] || len(tags) >= 16 {
				continue
			}
			seen[tag] = true
			tags = append(tags, tag)
		}
	}
	drama := Drama{
		ID: providerDramaID(sourceBeabox, id), Source: sourceBeabox, SourceID: id,
		Title: truncate(title, 512), Name: truncate(title, 512),
		Desc: truncate(mapString(row, "vodContent", "vodBlurb"), 12000), Intro: truncate(mapString(row, "vodContent", "vodBlurb"), 12000),
		Cover: cover, CoverURL: cover, ChannelName: "笔盒", Tags: tags,
	}
	if len(tags) > 0 {
		drama.CategoryName = tags[0]
	} else {
		drama.CategoryName = "成人"
	}
	if seconds, ok := webProviderInteger(row["vodDuration"], 8640000); ok && seconds > 0 {
		drama.Remark = fmt.Sprintf("%d 分钟", seconds/60)
	}
	// 上限取 2e9：Android armv7/x86 的 int 是 32 位，4e9 会编译期溢出。
	if unix, ok := webProviderInteger(row["vodTime"], 2000000000); ok && unix > 0 {
		drama.OnlineDate = time.Unix(int64(unix), 0).Format("2006-01-02")
	}
	if heat, ok := webProviderInteger(firstPresent(row, "heatValue", "vodUp"), 1000000000); ok && heat > 0 {
		drama.Heat = strconv.Itoa(heat)
	}
	return drama, nil
}

func beaboxRows(decoded any) ([]any, int, bool) {
	if object, ok := decoded.(map[string]any); ok {
		for _, key := range []string{"data", "list", "items", "records"} {
			if rows, ok := object[key].([]any); ok {
				total, _ := webProviderInteger(object["total"], 1000000000)
				return rows, total, true
			}
		}
	}
	if rows, ok := decoded.([]any); ok {
		return rows, len(rows), true
	}
	return nil, 0, false
}

func (d *Downloader) fetchBeaboxCatalogPage(ctx context.Context, page int, category, query string) ([]Drama, bool, error) {
	if page < 1 || page > 1000000 {
		return nil, false, errors.New("笔盒目录页码无效")
	}
	query = strings.TrimSpace(query)
	if len(query) > 256 {
		return nil, false, errors.New("笔盒搜索关键词无效")
	}
	base, err := d.beaboxResolveBase(ctx)
	if err != nil {
		return nil, false, err
	}
	path := fmt.Sprintf("/vod/latest?page=%d&limit=%d", page, beaboxPageSize)
	if query != "" {
		path = fmt.Sprintf("/vod/search?keyword=%s&page=%d&limit=%d", url.QueryEscape(query), page, beaboxPageSize)
	}
	decoded, err := d.beaboxAPIGet(ctx, base, path)
	if err != nil {
		return nil, false, err
	}
	rows, total, ok := beaboxRows(decoded)
	if !ok {
		return nil, false, errors.New("笔盒目录格式无效")
	}
	items := make([]Drama, 0, len(rows))
	seen := map[string]bool{}
	for _, value := range rows {
		row, _ := value.(map[string]any)
		drama, err := beaboxDramaFromRow(row, base)
		if err != nil || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		items = append(items, drama)
	}
	more := len(items) >= beaboxPageSize && (total == 0 || page*beaboxPageSize < total)
	return items, more, nil
}

func beaboxPlayURL(row map[string]any) string {
	sources, ok := row["vodPlaySource"].(map[string]any)
	if !ok {
		return ""
	}
	extract := func(listValue any) string {
		list, ok := listValue.([]any)
		if !ok {
			return ""
		}
		for _, value := range list {
			entry, _ := value.(map[string]any)
			address := normalizeProviderMediaURL(beaboxGatewayURL+"/", firstNonEmpty(mapString(entry, "playUrl"), mapString(entry, "url")))
			if isProviderHTTPMediaURL(address) {
				return address
			}
		}
		return ""
	}
	// 先试常见键拿确定性结果，再兜底遍历其余键（站点会按来源使用 beabox-app 等键名）。
	for _, key := range []string{"dplayer", "default", "hls", "m3u8", "beabox-app"} {
		if address := extract(sources[key]); address != "" {
			return address
		}
	}
	for key, listValue := range sources {
		if key == "dplayer" || key == "default" || key == "hls" || key == "m3u8" || key == "beabox-app" {
			continue
		}
		if address := extract(listValue); address != "" {
			return address
		}
	}
	return ""
}

func (d *Downloader) fetchBeaboxDetail(ctx context.Context, sourceID string) (Drama, []Chapter, error) {
	sourceID = strings.TrimSpace(sourceID)
	if sourceID == "" || len(sourceID) > 40 || strings.ContainsAny(sourceID, "/\\ \x00\r\n?&") {
		return Drama{}, nil, errors.New("笔盒视频 ID 无效")
	}
	base, err := d.beaboxResolveBase(ctx)
	if err != nil {
		return Drama{}, nil, err
	}
	decoded, err := d.beaboxAPIGet(ctx, base, "/vod/detail/"+url.PathEscape(sourceID))
	if err != nil {
		return Drama{}, nil, err
	}
	row, _ := decoded.(map[string]any)
	if row == nil {
		return Drama{}, nil, errors.New("笔盒详情格式无效")
	}
	drama, err := beaboxDramaFromRow(row, base)
	if err != nil {
		return Drama{}, nil, err
	}
	playURL := beaboxPlayURL(row)
	chapters := []Chapter{{
		ID:             providerChapterID(sourceBeabox, sourceID, "1"),
		Source:         sourceBeabox,
		Title:          "正片",
		CurrentEpisode: rawEpisode(1),
		VideoURL:       playURL,
		Referer:        base + "/",
	}}
	drama.EpisodeCount, drama.TotalEpisode = 1, 1
	return drama, chapters, nil
}

func (d *Downloader) resolveBeaboxMedia(ctx context.Context, task Task) (providerMedia, error) {
	source, sourceID, valid := splitProviderDramaID(task.DramaID)
	if !valid || source != sourceBeabox || strings.TrimSpace(sourceID) == "" {
		return providerMedia{}, errors.New("笔盒播放信息无效，请刷新详情")
	}
	address := normalizeProviderMediaURL(beaboxGatewayURL+"/", strings.TrimSpace(task.Chapter.VideoURL))
	if !isProviderHTTPMediaURL(address) {
		drama, chapters, err := d.fetchBeaboxDetail(ctx, sourceID)
		if err != nil {
			return providerMedia{}, err
		}
		_ = drama
		for _, chapter := range chapters {
			candidate := normalizeProviderMediaURL(beaboxGatewayURL+"/", strings.TrimSpace(chapter.VideoURL))
			if isProviderHTTPMediaURL(candidate) {
				address = candidate
				break
			}
		}
	}
	if !isProviderHTTPMediaURL(address) {
		return providerMedia{}, errors.New("笔盒该视频暂无可用播放地址")
	}
	referer := beaboxGatewayURL + "/"
	if base, err := d.beaboxResolveBase(ctx); err == nil {
		referer = base + "/"
	}
	return d.prepareWebProviderMedia(ctx, providerMedia{URL: address, Referer: referer}, "笔盒")
}

func (d *Downloader) fetchBeaboxCategories() []nativeCategory {
	return []nativeCategory{{ID: "latest", Name: "最新"}}
}

func validBeaboxCategory(category string) bool {
	return category == "" || category == "latest" || category == "all"
}
