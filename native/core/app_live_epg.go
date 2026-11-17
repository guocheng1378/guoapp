package core

// 电子节目单（EPG，2026-11-08）：只消费用户提供的 xmltv 地址（TVBox 的
// lives[].epg，或直播源页手填），不内置任何默认 EPG 源——没有配置就不产生
// 任何网络请求。
//
// 这里的核心约束是数据量：公共 xmltv 单体常见 10~60MB，整串读进内存再解析在
// 低端机上会直接 OOM；把整份节目表回传给 Dart 也会把桥接层撑爆。因此：
//   - 解析走 encoding/xml 的流式 Decoder，逐个 <channel>/<programme> 处理；
//   - 只保留「本次请求里出现过的频道」（tvg-id 精确或台名归一命中）的节目，
//     其余整段丢弃；
//   - 回传裁剪后的结果：每频道 now/next + 当日节目（上限 48 条）。
// 缓存按「源地址 + 请求频道集合」签名，TTL 10 分钟；失败另走 5 分钟负缓存，
// 避免 xmltv 源挂掉时每次进直播页都重拉一遍。

import (
	"bufio"
	"compress/gzip"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"sort"
	"strings"
	"time"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/transform"
)

const (
	liveEpgTTL         = 10 * time.Minute
	liveEpgFailTTL     = 5 * time.Minute
	liveEpgMaxBody     = 64 << 20  // 64MB：公共 xmltv 压缩包上限
	liveEpgMaxInflated = 128 << 20 // 128MB：解压后上限（防 gzip 炸弹逐 token 吃满内存）
	liveEpgMaxSources  = 4         // 单次请求最多源数
	liveEpgMaxRefs     = 200       // 单次请求最多频道数（当前分组的可见频道）
	liveEpgMaxPrograms = 48        // 单频道回传节目上限
	liveEpgRawLimit    = 400       // 解析期单频道缓存上限（防超长列表内存膨胀）
	liveEpgFetchWindow = 12 * time.Second
	liveEpgTotalBudget = 20 * time.Second
	liveEpgCacheSlots  = 16
)

// liveEpgRef 是 Dart 侧要节目单的频道（台名 + 可选 tvg-id）。
type liveEpgRef struct {
	Name  string `json:"name"`
	TVGID string `json:"tvgId"`
}

func (ref liveEpgRef) key() string {
	if id := strings.TrimSpace(ref.TVGID); id != "" {
		return "tvg:" + strings.ToLower(id)
	}
	return "name:" + liveChannelKey(ref.Name)
}

// liveEpgProgram 是回传给 Dart 的节目（时间为 RFC3339，带原始时区偏移）。
type liveEpgProgram struct {
	Title string `json:"title"`
	Desc  string `json:"desc,omitempty"`
	Start string `json:"start"`
	Stop  string `json:"stop,omitempty"`
}

// liveEpgChannelResult 与请求顺序一一对应；Matched=false 表示该源里没有这个频道。
type liveEpgChannelResult struct {
	Name     string           `json:"name"`
	TVGID    string           `json:"tvgId,omitempty"`
	Matched  bool             `json:"matched"`
	Match    string           `json:"match,omitempty"` // tvgId | name
	Now      *liveEpgProgram  `json:"now,omitempty"`
	Next     *liveEpgProgram  `json:"next,omitempty"`
	Programs []liveEpgProgram `json:"programs,omitempty"`
}

type liveEpgResult struct {
	Channels  []liveEpgChannelResult `json:"channels"`
	FetchedAt string                 `json:"fetchedAt,omitempty"`
	Warning   string                 `json:"warning,omitempty"`
	Cached    bool                   `json:"cached,omitempty"`
}

type liveEpgCacheEntry struct {
	result  liveEpgResult
	expires time.Time
}

func (d *Downloader) liveEpgLookup(key string) (liveEpgResult, bool) {
	d.liveEpgMu.Lock()
	defer d.liveEpgMu.Unlock()
	entry, ok := d.liveEpg[key]
	if !ok {
		return liveEpgResult{}, false
	}
	if time.Now().After(entry.expires) {
		delete(d.liveEpg, key)
		return liveEpgResult{}, false
	}
	result := entry.result
	result.Cached = true
	return result, true
}

func (d *Downloader) liveEpgStore(key string, result liveEpgResult, ttl time.Duration) {
	d.liveEpgMu.Lock()
	defer d.liveEpgMu.Unlock()
	if d.liveEpg == nil {
		d.liveEpg = map[string]liveEpgCacheEntry{}
	}
	now := time.Now()
	for existing, entry := range d.liveEpg {
		if now.After(entry.expires) {
			delete(d.liveEpg, existing)
		}
	}
	if len(d.liveEpg) >= liveEpgCacheSlots {
		var oldestKey string
		var oldest time.Time
		for existing, entry := range d.liveEpg {
			if oldestKey == "" || entry.expires.Before(oldest) {
				oldestKey, oldest = existing, entry.expires
			}
		}
		if oldestKey != "" {
			delete(d.liveEpg, oldestKey)
		}
	}
	result.Cached = false
	d.liveEpg[key] = liveEpgCacheEntry{result: result, expires: now.Add(ttl)}
}

// ---------- 台名归一与别名 ----------

// liveChannelSuffixes 台名后缀噪声：m3u 里同名频道常带「高清/1080P/HD」等标记，
// xmltv 的 display-name 通常不带，必须两侧同时剥掉才能对齐。
var liveChannelSuffixes = []string{
	"超高清", "高清", "标清", "蓝光", "蓝光原盘", "4k", "uhd", "fhd", "hd", "sd",
	"1080p", "720p", "576p", "备份", "备用", "测试",
}

// liveChannelAliases 是「归一后写法 → 规范键」的别名表：CCTV1 / CCTV-1 /
// 央视一套 在 xmltv 与 m3u 两侧写法差异极大，靠规则无法穷举，只覆盖高频台；
// 其余台仍走「归一后名称相等」的兜底。键必须是 liveChannelNormalize 的输出。
var liveChannelAliases = map[string]string{
	"cctv1": "cctv1", "cctv1综合": "cctv1", "cctv1综合频道": "cctv1", "央视一套": "cctv1", "中央电视台一套": "cctv1", "中央一台": "cctv1",
	"cctv2": "cctv2", "cctv2财经": "cctv2", "cctv2财经频道": "cctv2", "央视二套": "cctv2", "中央二台": "cctv2",
	"cctv3": "cctv3", "cctv3综艺": "cctv3", "cctv3综艺频道": "cctv3", "央视三套": "cctv3", "中央三台": "cctv3",
	"cctv4": "cctv4", "cctv4中文国际": "cctv4", "cctv4国际": "cctv4", "央视四套": "cctv4", "中央四台": "cctv4",
	"cctv5": "cctv5", "cctv5体育": "cctv5", "cctv5体育频道": "cctv5", "央视五套": "cctv5", "中央五台": "cctv5",
	"cctv5+": "cctv5plus", "cctv5plus": "cctv5plus", "cctv5赛事": "cctv5plus", "央视五套加": "cctv5plus", "cctv5体育赛事": "cctv5plus",
	"cctv6": "cctv6", "cctv6电影": "cctv6", "cctv6电影频道": "cctv6", "央视六套": "cctv6", "中央六台": "cctv6",
	"cctv7": "cctv7", "cctv7国防军事": "cctv7", "央视七套": "cctv7", "中央七台": "cctv7",
	"cctv8": "cctv8", "cctv8电视剧": "cctv8", "cctv8电视剧频道": "cctv8", "央视八套": "cctv8", "中央八台": "cctv8",
	"cctv9": "cctv9", "cctv9纪录": "cctv9", "cctv9记录": "cctv9", "央视九套": "cctv9", "中央九台": "cctv9",
	"cctv10": "cctv10", "cctv10科教": "cctv10", "央视十套": "cctv10", "中央十台": "cctv10",
	"cctv11": "cctv11", "cctv11戏曲": "cctv11", "央视十一套": "cctv11",
	"cctv12": "cctv12", "cctv12社会与法": "cctv12", "央视十二套": "cctv12",
	"cctv13": "cctv13", "cctv13新闻": "cctv13", "cctv新闻": "cctv13", "央视十三套": "cctv13", "新闻频道": "cctv13",
	"cctv14": "cctv14", "cctv14少儿": "cctv14", "央视十四套": "cctv14", "央视少儿": "cctv14",
	"cctv15": "cctv15", "cctv15音乐": "cctv15", "央视十五套": "cctv15",
	"cctv16": "cctv16", "cctv16奥林匹克": "cctv16", "cctv16风云": "cctv16",
	"cctv17": "cctv17", "cctv17农业农村": "cctv17",
	"cgtn": "cgtn", "中国国际电视台": "cgtn",
	"湖南卫视": "hunan", "湖南": "hunan",
	"浙江卫视": "zhejiang", "浙江": "zhejiang",
	"江苏卫视": "jiangsu", "江苏": "jiangsu",
	"东方卫视": "dragon", "上海东方卫视": "dragon", "上海卫视": "dragon",
	"北京卫视": "beijing", "北京": "beijing",
	"安徽卫视": "anhui", "山东卫视": "shandong", "广东卫视": "guangdong",
	"深圳卫视": "shenzhen", "湖北卫视": "hubei", "四川卫视": "sichuan",
	"天津卫视": "tianjin", "重庆卫视": "chongqing", "河南卫视": "henan",
	"黑龙江卫视": "heilongjiang", "吉林卫视": "jilin", "辽宁卫视": "liaoning",
	"江西卫视": "jiangxi", "广西卫视": "guangxi", "云南卫视": "yunnan",
	"贵州卫视": "guizhou", "山西卫视": "shanxi", "陕西卫视": "shaanxi",
	"甘肃卫视": "gansu", "宁夏卫视": "ningxia", "新疆卫视": "xinjiang",
	"西藏卫视": "xizang", "内蒙古卫视": "neimenggu", "河北卫视": "hebei",
	"福建东南卫视": "fujian", "东南卫视": "fujian", "厦门卫视": "xiamen",
	"海南卫视": "hainan", "青海卫视": "qinghai",
}

// liveEpgHalfToFull 把全角字符折成半角（台名里「ＣＣＴＶ－１」与「CCTV-1」等价）。
func liveEpgHalfWidth(text string) string {
	var builder strings.Builder
	builder.Grow(len(text))
	for _, r := range text {
		switch {
		case r == '\u3000':
			builder.WriteRune(' ')
		case r >= '\uFF01' && r <= '\uFF5E':
			builder.WriteRune(r - 0xFEE0)
		default:
			builder.WriteRune(r)
		}
	}
	return builder.String()
}

// liveChannelNormalize 去掉空白、标点与后缀噪声，只留可用于比较的主体。
func liveChannelNormalize(name string) string {
	text := strings.ToLower(liveEpgHalfWidth(name))
	var builder strings.Builder
	builder.Grow(len(text))
	for _, r := range text {
		switch {
		case r == ' ' || r == '\t' || r == '\n' || r == '\r':
			continue
		// 注意保留 '+'：CCTV5 与 CCTV5+ 是两个频道，折掉 '+' 会把它们并成一个。
		case strings.ContainsRune("-—_·.,、:：;；'\"()（）[]【】<>《》&/\\|", r):
			continue
		}
		builder.WriteRune(r)
	}
	key := builder.String()
	// 后缀可能叠加（「湖南卫视高清」→「湖南卫视」；「CCTV1HD」→「cctv1」）。
	for changed := true; changed; {
		changed = false
		for _, suffix := range liveChannelSuffixes {
			if len(key) > len(suffix) && strings.HasSuffix(key, suffix) {
				key = strings.TrimSuffix(key, suffix)
				changed = true
			}
		}
	}
	return key
}

// liveChannelKey 在归一基础上套别名表，得到最终匹配键。
func liveChannelKey(name string) string {
	key := liveChannelNormalize(name)
	if key == "" {
		return ""
	}
	if canonical, ok := liveChannelAliases[key]; ok {
		return canonical
	}
	// 「湖南卫视高清」归一后是 hunanweishi，与别名键「湖南卫视」不同：
	// 再查一次去掉「卫视/频道/台」尾缀的形态。
	trimmed := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(key, "卫视"), "频道"), "台")
	if trimmed != key {
		if canonical, ok := liveChannelAliases[trimmed]; ok {
			return canonical
		}
		return trimmed
	}
	return key
}

// ---------- xmltv 流式解析 ----------

type liveEpgXMLChannel struct {
	ID    string   `xml:"id,attr"`
	Names []string `xml:"display-name"`
}

type liveEpgXMLProgramme struct {
	Start   string   `xml:"start,attr"`
	Stop    string   `xml:"stop,attr"`
	Channel string   `xml:"channel,attr"`
	Titles  []string `xml:"title"`
	Descs   []string `xml:"desc"`
}

type liveEpgRow struct {
	title string
	desc  string
	start time.Time
	stop  time.Time
}

type liveEpgParseTargets struct {
	byID   map[string]string // tvg-id（小写）→ 请求键
	byKey  map[string]string // 台名 key → 请求键
	idRef  map[string]string // xmltv channel id → 请求键
	idKind map[string]string // xmltv channel id → tvgId|name
	rows   map[string][]liveEpgRow
}

// liveEpgCharsetReader 让 GB2312/GBK 编码的 xmltv 也能解析（这类文件在国内很常见）；
// 未知编码退回原文，宁可乱码也不要整份失败。
func liveEpgCharsetReader(charset string, input io.Reader) (io.Reader, error) {
	switch strings.ToLower(strings.TrimSpace(charset)) {
	case "gbk", "gb2312", "gb-2312", "gb18030", "gb_2312-80":
		return transform.NewReader(input, simplifiedchinese.GBK.NewDecoder()), nil
	}
	return input, nil
}

func liveEpgParseTime(raw string) (time.Time, bool) {
	text := strings.TrimSpace(raw)
	if text == "" {
		return time.Time{}, false
	}
	layouts := []string{
		"20060102150405 -0700",
		"20060102150405 -07:00",
		"20060102150405",
		"2006-01-02T15:04:05Z07:00",
		"2006-01-02 15:04:05",
	}
	for _, layout := range layouts {
		if parsed, err := time.ParseInLocation(layout, text, time.Local); err == nil {
			return parsed, true
		}
	}
	return time.Time{}, false
}

func liveEpgFirstText(values []string) string {
	for _, value := range values {
		if text := strings.TrimSpace(value); text != "" {
			return text
		}
	}
	return ""
}

func (targets *liveEpgParseTargets) matchChannel(ch liveEpgXMLChannel) {
	id := strings.TrimSpace(ch.ID)
	if id == "" {
		return
	}
	if _, done := targets.idRef[id]; done {
		return
	}
	if ref, ok := targets.byID[strings.ToLower(id)]; ok {
		targets.idRef[id] = ref
		targets.idKind[id] = "tvgId"
		return
	}
	for _, name := range ch.Names {
		key := liveChannelKey(name)
		if key == "" {
			continue
		}
		if ref, ok := targets.byKey[key]; ok {
			targets.idRef[id] = ref
			targets.idKind[id] = "name"
			return
		}
	}
}

func (targets *liveEpgParseTargets) addProgramme(row liveEpgXMLProgramme) {
	id := strings.TrimSpace(row.Channel)
	if id == "" {
		return
	}
	if _, ok := targets.idRef[id]; !ok {
		// 部分文件不写 <channel> 声明，直接用 tvg-id 兜底命中。
		ref, hit := targets.byID[strings.ToLower(id)]
		if !hit {
			return
		}
		targets.idRef[id] = ref
		targets.idKind[id] = "tvgId"
	}
	if len(targets.rows[id]) >= liveEpgRawLimit {
		return
	}
	start, ok := liveEpgParseTime(row.Start)
	if !ok {
		return
	}
	title := liveEpgFirstText(row.Titles)
	if title == "" {
		return
	}
	stop, _ := liveEpgParseTime(row.Stop)
	if !stop.IsZero() && stop.Before(start) {
		stop = time.Time{}
	}
	targets.rows[id] = append(targets.rows[id], liveEpgRow{
		title: title,
		desc:  liveEpgFirstText(row.Descs),
		start: start,
		stop:  stop,
	})
}

// liveEpgParseStream 流式解析：命中频道才有结构体，未命中整段跳过。
func liveEpgParseStream(body io.Reader, targets *liveEpgParseTargets) error {
	decoder := xml.NewDecoder(body)
	decoder.Strict = false
	decoder.CharsetReader = liveEpgCharsetReader
	for {
		token, err := decoder.Token()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			return err
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		switch start.Name.Local {
		case "channel":
			var channel liveEpgXMLChannel
			if err := decoder.DecodeElement(&channel, &start); err != nil {
				return err
			}
			targets.matchChannel(channel)
		case "programme":
			var programme liveEpgXMLProgramme
			if err := decoder.DecodeElement(&programme, &start); err != nil {
				return err
			}
			targets.addProgramme(programme)
		}
	}
}

// ---------- 拉取 ----------

type liveEpgBody struct {
	reader  io.Reader
	closers []io.Closer
}

func (body *liveEpgBody) Read(p []byte) (int, error) { return body.reader.Read(p) }

func (body *liveEpgBody) Close() error {
	var first error
	for _, closer := range body.closers {
		if err := closer.Close(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

// openLiveEpgStream 发起 EPG 请求并返回可流式读取的正文；gzip 按魔数识别
// （部分源直接给 .xml.gz 但不带 Content-Encoding，靠传输层解压不可靠）。
func (d *Downloader) openLiveEpgStream(ctx context.Context, url string, headers map[string]string) (io.ReadCloser, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", liveUserAgent)
	req.Header.Set("Accept", "*/*")
	for key, value := range sanitizeLiveHeaders(headers) {
		req.Header.Set(key, value)
	}
	resp, err := d.doCatalogRequestWithTimeout(req, liveEpgFetchWindow)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		resp.Body.Close()
		return nil, fmt.Errorf("节目单请求失败：%s", resp.Status)
	}
	buffered := bufio.NewReaderSize(io.LimitReader(resp.Body, liveEpgMaxBody), 64<<10)
	body := &liveEpgBody{closers: []io.Closer{resp.Body}}
	magic, err := buffered.Peek(2)
	if err == nil && len(magic) == 2 && magic[0] == 0x1f && magic[1] == 0x8b {
		gz, gzErr := gzip.NewReader(buffered)
		if gzErr != nil {
			resp.Body.Close()
			return nil, gzErr
		}
		body.closers = append([]io.Closer{gz}, body.closers...)
		// 解压后必须再封一次顶：LimitReader 套在压缩流上只能限制「压缩包体积」，
		// 几十 KB 的 .xml.gz 可能膨胀到 GB 级，逐 token 解析会直接吃满内存。
		body.reader = io.LimitReader(gz, liveEpgMaxInflated)
		return body, nil
	}
	body.reader = buffered
	return body, nil
}

// ---------- 组装 ----------

func liveEpgRequestRefs(raw []liveEpgRef) []liveEpgRef {
	refs := make([]liveEpgRef, 0, len(raw))
	seen := make(map[string]bool, len(raw))
	for _, ref := range raw {
		name := strings.TrimSpace(ref.Name)
		id := strings.TrimSpace(ref.TVGID)
		if name == "" && id == "" {
			continue
		}
		item := liveEpgRef{Name: name, TVGID: id}
		key := item.key()
		if key == "name:" || seen[key] {
			continue
		}
		seen[key] = true
		refs = append(refs, item)
		if len(refs) >= liveEpgMaxRefs {
			break
		}
	}
	return refs
}

func liveEpgCacheKey(sources []liveSourceInput, refs []liveEpgRef) string {
	keys := make([]string, 0, len(refs))
	for _, ref := range refs {
		keys = append(keys, ref.key())
	}
	sort.Strings(keys)
	urls := make([]string, 0, len(sources))
	for _, source := range sources {
		urls = append(urls, source.URL+liveHeaderCacheSuffix(source.Headers))
	}
	sum := sha256.Sum256([]byte(strings.Join(urls, "\n") + "\x00" + strings.Join(keys, "\n")))
	return hex.EncodeToString(sum[:12])
}

// liveEpgProgramOf 把解析行转成回传结构（Stop 只在原值存在时给出）。
func liveEpgProgramOf(row liveEpgRow) liveEpgProgram {
	program := liveEpgProgram{
		Title: row.title,
		Desc:  row.desc,
		Start: row.start.Format(time.RFC3339),
	}
	if !row.stop.IsZero() {
		program.Stop = row.stop.Format(time.RFC3339)
	}
	return program
}

func liveEpgBuildChannel(rows []liveEpgRow, now, dayStart, until time.Time) (liveEpgChannelResult, bool) {
	if len(rows) == 0 {
		return liveEpgChannelResult{}, false
	}
	sorted := make([]liveEpgRow, len(rows))
	copy(sorted, rows)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].start.Before(sorted[j].start) })
	day := make([]liveEpgProgram, 0, 16)
	nowIndex, nextIndex := -1, -1
	// now/next 与回传表解耦：超过上限（48 条）后仍在全量节目里判定。否则频道
	// 接近午夜时真实在播的一档必然落在 48 条之外，界面会退化成「暂无正在播」。
	var nowOverflow, nextOverflow *liveEpgRow
	for index := range sorted {
		row := sorted[index]
		stop := row.stop
		if stop.IsZero() {
			stop = row.start.Add(30 * time.Minute)
		}
		if row.start.After(until) {
			break
		}
		// 跨天节目（昨天开播、今天结束）必须保留：它可能正是当前在播的一档。
		if !stop.After(dayStart) {
			continue
		}
		appended := -1
		if len(day) < liveEpgMaxPrograms {
			day = append(day, liveEpgProgramOf(row))
			appended = len(day) - 1
		}
		if !row.start.After(now) && stop.After(now) {
			if appended >= 0 {
				nowIndex = appended
			} else {
				copied := row
				nowOverflow = &copied
			}
		}
		if nextIndex < 0 && row.start.After(now) {
			if appended >= 0 {
				nextIndex = appended
			} else {
				copied := row
				nextOverflow = &copied
			}
		}
	}
	result := liveEpgChannelResult{Matched: true, Programs: day}
	if nowIndex >= 0 && nowIndex < len(day) {
		program := day[nowIndex]
		result.Now = &program
	} else if nowOverflow != nil {
		program := liveEpgProgramOf(*nowOverflow)
		result.Now = &program
	}
	if nextIndex >= 0 && nextIndex < len(day) {
		program := day[nextIndex]
		result.Next = &program
	} else if nextOverflow != nil {
		program := liveEpgProgramOf(*nextOverflow)
		result.Next = &program
	}
	return result, true
}

// nativeLiveEpg 是 live.epg 的实现：并发度为 1、按源顺序补齐未命中的频道。
// 单个 xmltv 源通常覆盖全部央卫视频道，多源只在互有缺口时才需要。
func (engine *nativeEngine) nativeLiveEpg(ctx context.Context, input nativeInput) (any, error) {
	refs := liveEpgRequestRefs(input.EpgChannels)
	if len(refs) == 0 {
		return liveEpgResult{}, nil
	}
	sources := make([]liveSourceInput, 0, len(input.LiveEPG))
	seen := make(map[string]bool, len(input.LiveEPG))
	for _, source := range input.LiveEPG {
		url := strings.TrimSpace(source.URL)
		lower := strings.ToLower(url)
		if url == "" || (!strings.HasPrefix(lower, "http://") && !strings.HasPrefix(lower, "https://")) {
			continue
		}
		key := url + liveHeaderCacheSuffix(source.Headers)
		if seen[key] {
			continue
		}
		seen[key] = true
		sources = append(sources, liveSourceInput{URL: url, Headers: source.Headers})
		if len(sources) >= liveEpgMaxSources {
			break
		}
	}
	if len(sources) == 0 {
		return liveEpgResult{}, nil
	}

	d := engine.downloader
	cacheKey := liveEpgCacheKey(sources, refs)
	if cached, ok := d.liveEpgLookup(cacheKey); ok {
		return cached, nil
	}

	targets := &liveEpgParseTargets{
		byID:   make(map[string]string, len(refs)),
		byKey:  make(map[string]string, len(refs)),
		idRef:  make(map[string]string, len(refs)),
		idKind: make(map[string]string, len(refs)),
		rows:   make(map[string][]liveEpgRow, len(refs)),
	}
	for _, ref := range refs {
		if ref.TVGID != "" {
			targets.byID[strings.ToLower(ref.TVGID)] = ref.key()
		}
		if key := liveChannelKey(ref.Name); key != "" {
			if _, exists := targets.byKey[key]; !exists {
				targets.byKey[key] = ref.key()
			}
		}
	}

	deadline := time.Now().Add(liveEpgTotalBudget)
	warnings := make([]string, 0, 2)
	used := 0
	for _, source := range sources {
		if len(targets.idRef) >= len(refs) {
			break
		}
		if time.Until(deadline) <= time.Second {
			warnings = append(warnings, "节目单获取超时")
			break
		}
		stream, err := d.openLiveEpgStream(ctx, source.URL, source.Headers)
		if err != nil {
			warnings = append(warnings, "节目单源不可用，已跳过")
			continue
		}
		parseErr := liveEpgParseStream(stream, targets)
		stream.Close()
		used++
		if parseErr != nil && len(targets.rows) == 0 {
			warnings = append(warnings, "节目单格式无法解析")
		}
	}

	refToID := make(map[string]string, len(targets.idRef))
	for id, ref := range targets.idRef {
		if _, exists := refToID[ref]; !exists {
			refToID[ref] = id
		}
	}
	now := time.Now()
	dayStart := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, now.Location())
	until := now.Add(24 * time.Hour)
	out := make([]liveEpgChannelResult, 0, len(refs))
	matchedAny := false
	for _, ref := range refs {
		item := liveEpgChannelResult{Name: ref.Name, TVGID: ref.TVGID}
		if id, ok := refToID[ref.key()]; ok {
			if built, hit := liveEpgBuildChannel(targets.rows[id], now, dayStart, until); hit {
				built.Name = item.Name
				built.TVGID = item.TVGID
				built.Match = targets.idKind[id]
				item = built
				matchedAny = true
			}
		}
		out = append(out, item)
	}

	result := liveEpgResult{
		Channels:  out,
		FetchedAt: now.Format(time.RFC3339),
		Warning:   strings.Join(warnings, "；"),
	}
	ttl := liveEpgTTL
	if used == 0 {
		// 所有源都没能打开（网络失败/超时）：负缓存，避免反复重拉几十 MB。
		ttl = liveEpgFailTTL
		if result.Warning == "" {
			result.Warning = "节目单源暂不可用"
		}
	} else if !matchedAny && result.Warning == "" {
		// 源可用但没命中：走正常 TTL。以前这里也写 5 分钟负缓存，导致源偶发
		// 返回残缺内容时，用户 5 分钟内重试都拿不到数据。
		result.Warning = "节目单里没有匹配到这些频道"
	}
	d.liveEpgStore(cacheKey, result, ttl)
	return result, nil
}
