package core

import (
	"context"
	"duanjuapp/native/provider"
	"fmt"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"
)

// providerHostsHot 是 providerHosts 的包级热更覆盖表（远程配置 sourceConfig
// 的 providerHosts 键，经 applySourceConfig 校验后由 setProviderHosts 写入）。
// Downloader 实例内的 providerHosts 是运行时状态（候选线路探测成功后核心还会
// 回写实测可用域名，最后写入者获胜），所以热更既写透现有引擎、也播种进包级表，
// 让之后新建的引擎带上最新覆盖。
var (
	providerHostsHotMu sync.RWMutex
	providerHostsHot   map[string]string
)

// setProviderHosts 热更通用源站域名覆盖表（调用方负责校验；nil 表示清空覆盖）。
// 值已由 applySourceConfig 规范化为无尾斜杠根地址。
func setProviderHosts(hosts map[string]string) {
	providerHostsHotMu.Lock()
	providerHostsHot = cloneProviderHosts(hosts)
	snapshot := cloneProviderHosts(providerHostsHot)
	providerHostsHotMu.Unlock()
	persistProviderHosts(snapshot)
	nativeState.Lock()
	engine := nativeState.engine
	nativeState.Unlock()
	if engine == nil || engine.downloader == nil {
		return
	}
	downloader := engine.downloader
	downloader.providerMu.Lock()
	downloader.providerHosts = cloneProviderHosts(hosts)
	downloader.providerMu.Unlock()
}

// providerHostsSeed 快照包级覆盖表，供新建引擎播种。
func providerHostsSeed() map[string]string {
	providerHostsHotMu.RLock()
	defer providerHostsHotMu.RUnlock()
	return cloneProviderHosts(providerHostsHot)
}

// cloneProviderHosts 复制覆盖表，避免包级表与引擎运行时状态共享底层存储。
func cloneProviderHosts(hosts map[string]string) map[string]string {
	if len(hosts) == 0 {
		return map[string]string{}
	}
	out := make(map[string]string, len(hosts))
	for source, host := range hosts {
		out[source] = host
	}
	return out
}

// providerHostOverride 读取指定源的热更/优选域名覆盖（providerMu 保护）。
func (d *Downloader) providerHostOverride(source string) string {
	d.providerMu.Lock()
	host := d.providerHosts[source]
	d.providerMu.Unlock()
	return host
}

type providerMedia struct {
	credentials *providerMediaCredentials
	URL         string
	Label       string
	Referer     string
	Duration    time.Duration
	Playlist    string
	HLSKey      []byte
	CENCKey     []byte
	Quality     int
	Variants    []providerMedia
	// Official 标记该线路来自站源官方票据（目前只有真果·鉴有官方线）。
	// 播放器线路面板按它把官方源与第三方源分开：官方线平铺、第三方折叠。
	Official bool
}

// providerMediaReferer 兜底 Referer：取本次实际命中的 host（媒体地址所在域）。
//
// 站源配置里的 base 只是「默认入口」：优选域名与两跳回退都会让真实请求落到
// 另一个 host 上，沿用 base 当 Referer 会被防盗链判成跨站引用。这里只在
// 兜底路径（章节没有自带 Referer）使用媒体地址自身的来源；自带 Referer 的
// 站源（maccms 族：和合/星果/番茄/猫果/雅果等）行为完全不变。
func providerMediaReferer(mediaURL, fallback string) string {
	parsed, err := url.Parse(strings.TrimSpace(mediaURL))
	if err == nil && (parsed.Scheme == "http" || parsed.Scheme == "https") && parsed.Host != "" {
		return parsed.Scheme + "://" + parsed.Host + "/"
	}
	return fallback
}

func (d *Downloader) providerBaseURL(source string) string {
	source = canonicalProviderSource(source)
	// 远程 providerHosts 与运行时学到的域名对所有源生效。此前只有 default 分支读覆盖，
	// 导致 hongguo/huangdou/huangju/yeguo/huangguoai 的覆盖配置被静默忽略（死配置）。
	if override := d.providerHostOverride(source); override != "" {
		return strings.TrimRight(override, "/")
	}
	var configured, fallback string
	switch source {
	case sourceHuangguoAI:
		configured, fallback = d.cfg.HuangguoAIURL, huangguoAIBaseURL
	case sourceHuangdou:
		configured, fallback = d.cfg.HuangdouURL, huangdouBaseURL
	case sourceHongguo:
		configured, fallback = d.cfg.HongguoURL, hongguoBaseURL
	case sourceHuangju:
		configured, fallback = d.cfg.HuangjuURL, huangjuBaseURL
	case sourceYeguo:
		configured, fallback = d.cfg.YeguoURL, yeguoBaseURL
	default:
		// duanju 族只能在 default 分支识别：这些源同时也注册在 provider 规格表里，
		// 提前判定会把 hongguo/huangdou 等内置源一并当成 duanju 族并绕过 cfg 注入。
		if spec, found := duanjuSourceSpecFor(source); found {
			return d.duanjuBaseURL(spec.ID)
		}
		fallback = "https://d2pypzndaqisk.cloudfront.net"
	}
	return strings.TrimRight(firstNonEmpty(configured, fallback), "/")
}

func providerSourceForURL(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return provider.ForHost(parsed.Hostname())
}

// providerSourceFromOverrides 用热更/学到的覆盖表反查 URL 属于哪个源。
// URL 已是覆盖后的新域时 provider.ForHost 认不出来，而覆盖表本身就是
// 「源 → 新域」的映射，据此仍能定位源，避免丢掉该源的镜像候选链。
func (d *Downloader) providerSourceFromOverrides(raw string) string {
	parsed, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	host := strings.ToLower(parsed.Hostname())
	if host == "" {
		return ""
	}
	d.providerMu.Lock()
	defer d.providerMu.Unlock()
	for source, override := range d.providerHosts {
		overridden, err := url.Parse(override)
		if err != nil || overridden.Host == "" {
			continue
		}
		if strings.ToLower(overridden.Hostname()) == host {
			return canonicalProviderSource(source)
		}
	}
	return ""
}

func (d *Downloader) providerURLCandidates(raw string) []string {
	source := providerSourceForURL(raw)
	if source == "" {
		source = d.providerSourceFromOverrides(raw)
	}
	if source == "" || source == sourceHuangju || source == sourceYeguo || isDuanjuProviderSource(source) {
		return []string{raw}
	}
	parsed, err := url.Parse(raw)
	if err != nil {
		return []string{raw}
	}
	preferred := d.providerHostOverride(source)
	var candidates []string
	seen := map[string]bool{}
	add := func(candidate string) {
		if candidate != "" && !seen[candidate] {
			seen[candidate] = true
			candidates = append(candidates, candidate)
		}
	}
	add(rehostProviderURL(parsed, preferred))
	// 镜像链只与「源」有关，与 base 当前指向哪个域无关：base 被热更覆盖成新域后
	// 仍按 source 展开内置镜像，避免「一覆盖就丢候选」。
	if source == sourceHuangguoAI {
		for _, candidate := range providerURLCandidates(raw) {
			add(candidate)
		}
	}
	// 主域排在镜像之后：huangguoai.com 当前半死（间歇超时），
	// 一次超时会拖慢整个 resolve 链路，只在镜像全部失败时兜底。
	add(rehostProviderURL(parsed, d.providerBaseURL(source)))
	return candidates
}

func (d *Downloader) resolveProviderMedia(ctx context.Context, task Task) (providerMedia, error) {
	chapter := task.Chapter
	chapter.Source = canonicalProviderSource(chapter.Source)
	if chapter.Source == "" {
		chapter.Source = sourceFromDramaID(task.DramaID)
	}
	if chapter.Source == sourceCloudFront {
		return d.resolveLegacyMedia(ctx, task)
	}
	if chapter.Source == sourceHuangju {
		return d.resolveHuangjuMedia(ctx, task)
	}
	if chapter.Source == sourceYeguo {
		return d.resolveYeguoMedia(ctx, task)
	}
	if chapter.Source == sourceSorani {
		return d.resolveSoraniMedia(ctx, task)
	}
	if isDuanjuProviderSource(chapter.Source) {
		if chapter.Source == sourceDongpiandi {
			// 真果·鉴：站点推荐线路常失效/过慢，播放期做存活验证与实测换线。
			return d.resolveDongpiandiMedia(ctx, task)
		}
		return d.resolveDuanjuMedia(ctx, task)
	}
	if strings.HasPrefix(chapter.VideoURL, "hongguo-cenc://") {
		return d.resolveHongguoMedia(ctx, task)
	}
	// 2026-10-20：黄果AI 分集页真实形态是 /video/{id}/ep-{N}/（活页，自带
	// 该集地址）；「PageURL 为空」的旧任务才需要整合集刷新重建。
	if chapter.PageURL == "" && chapter.Source == sourceHuangguoAI {
		if source, sourceID, valid := splitProviderDramaID(task.DramaID); valid {
			_, chapters, err := d.GetHuangguoChapters(ctx, source, sourceID)
			if err != nil {
				return providerMedia{}, fmt.Errorf("刷新旧任务播放地址失败: %w", err)
			}
			matched := false
			for _, fresh := range chapters {
				if fresh.ID == chapter.ID {
					chapter = fresh
					matched = true
					break
				}
			}
			if !matched {
				return providerMedia{}, fmt.Errorf("原章节已变化，请更新该合集后重新下载")
			}
		}
	}
	media := providerMedia{URL: chapter.VideoURL, Referer: firstNonEmpty(chapter.Referer, providerMediaReferer(chapter.VideoURL, d.providerBaseURL(chapter.Source)+"/"))}
	if chapter.Source == sourceHuangdou {
		_, sourceID, valid := splitProviderDramaID(task.DramaID)
		if valid {
			sequence, err := strconv.Atoi(chapter.EpisodeString(task.Index))
			if err != nil || sequence < 1 {
				return providerMedia{}, fmt.Errorf("黄豆集数无效")
			}
			client := newHuangdouAPIClient(d)
			media, err = d.resolveHuangdouPlayback(ctx, client, sourceID, sequence)
			if err != nil {
				return providerMedia{}, err
			}
			media.Referer = client.host + "/home"
		}
	}
	if chapter.PageURL != "" && chapter.Source == sourceHuangguoAI && !isProviderHTTPMediaURL(media.URL) {
		responses := &playbackResponseURLs{}
		pageContext := context.WithValue(ctx, playbackResponseURLsKey{}, responses)
		body, err := d.fetchProviderText(pageContext, chapter.PageURL, media.Referer)
		if err != nil {
			return providerMedia{}, err
		}
		pageURL := chapter.PageURL
		if actual, ok := responses.values.Load(chapter.PageURL); ok {
			pageURL = actual.(string)
		}
		if chapter.Source == sourceHuangguoAI {
			media.URL = parseAIVideoURL(body, pageURL)
		} else {
			media.URL = parseDataHLS(body, pageURL)
		}
		media.Referer = pageURL
	}
	if !isProviderHTTPMediaURL(media.URL) {
		return providerMedia{}, fmt.Errorf("%s 未返回有效播放地址，请刷新章节或确认站点访问权限", chapter.Source)
	}
	parsed, _ := url.Parse(media.URL)
	if strings.HasSuffix(strings.ToLower(parsed.Path), ".m3u8") {
		playlist, finalURL, err := d.fetchMediaPlaylist(ctx, media.URL, media.Referer)
		if err != nil {
			return providerMedia{}, fmt.Errorf("获取播放列表失败: %w", err)
		}
		if !strings.HasPrefix(strings.TrimSpace(strings.TrimPrefix(playlist, "\ufeff")), "#EXTM3U") {
			return providerMedia{}, fmt.Errorf("站点未返回有效 M3U8，可能需要登录或链接已失效")
		}
		if duration := m3u8Duration(playlist); duration > 0 {
			media.Duration = duration
		}
		media.Playlist = playlist
		media.URL = finalURL
	}
	return media, nil
}
