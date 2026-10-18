package maccmsweb

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"golang.org/x/net/html"

	"duanjuapp/native/provider"
)

var (
	episodeLink = regexp.MustCompile(`(?i)/(?:vod/)?play/|/vodplay/|/drama-play|episode_id=`)
	detailLink  = regexp.MustCompile(`(?i)/(?:index\.php/vod/)?(?:detail|vod|show|view|movie|drama|zywview|xzyxvd)/`)
	detailPath  = regexp.MustCompile(`(?i)/(?:voddetail|detail|show|vod|drama|movie|tv)/([0-9]+)(?:[-./]|$)`)
)

// profile 描述每个网页型站源的地址构造差异，解析逻辑五站共享。
type profile struct {
	catalogAddress func(base, category string, page int) (string, error)
	searchAddress  func(base, query string) (string, error)
	detailURLs     func(base, sourceID string) []string
}

var sourceCategories = map[string][]provider.CatalogCategory{
	provider.SourceHuaguo: {
		{ID: "27", Name: "短剧"},
	},
}

var profiles = map[string]profile{
	provider.SourceHuaguo: {
		catalogAddress: func(base, category string, page int) (string, error) {
			if page <= 1 && strings.TrimSpace(category) == "" {
				return base + "/", nil
			}
			class := strings.TrimSpace(category)
			if class == "" {
				class = "27"
			}
			return fmt.Sprintf("%s/search.html?page=%d&searchtype=5&tid=%s&year=", base, page, url.QueryEscape(class)), nil
		},
		searchAddress: func(base, query string) (string, error) {
			return fmt.Sprintf("%s/search.html?searchword=%s", base, url.QueryEscape(query)), nil
		},
		detailURLs: func(base, sourceID string) []string {
			return []string{
				fmt.Sprintf("%s/zywview/%s.html", base, sourceID),
				fmt.Sprintf("%s/zywdetail/%s.html", base, sourceID),
				fmt.Sprintf("%s/detail/%s.html", base, sourceID),
			}
		},
	},
	provider.SourceFaguo: {
		catalogAddress: func(base, category string, page int) (string, error) {
			class := strings.TrimSpace(category)
			if class == "" {
				return fmt.Sprintf("%s/xzyxvt/%dzmn.html", base, page), nil
			}
			if strings.Contains(class, "zmn") {
				return base + strings.SplitN(class, "zmn", 2)[0] + strconv.Itoa(page) + "zmn.html", nil
			}
			return "", errors.New("发果分类无效")
		},
		searchAddress: func(base, query string) (string, error) {
			return fmt.Sprintf("%s/xzyxvc/%s-wdyswzqun1num.html", base, url.PathEscape(query)), nil
		},
		detailURLs: func(base, sourceID string) []string {
			return []string{
				fmt.Sprintf("%s/xzyxvd/%s.html", base, sourceID),
				fmt.Sprintf("%s/detail/%s.html", base, sourceID),
				fmt.Sprintf("%s/voddetail/%s.html", base, sourceID),
			}
		},
	},
	provider.SourceWuguo: {
		catalogAddress: func(base, category string, page int) (string, error) {
			class := strings.TrimSpace(category)
			if class == "" {
				return base + "/", nil
			}
			return fmt.Sprintf("%s%s/page/%d.html", base, strings.TrimSuffix(class, ".html"), page), nil
		},
		searchAddress: func(base, query string) (string, error) {
			return fmt.Sprintf("%s/index.php/vod/search/page/1/wd/%s.html", base, url.PathEscape(query)), nil
		},
		detailURLs: func(base, sourceID string) []string {
			return []string{
				fmt.Sprintf("%s/index.php/vod/detail/id/%s.html", base, sourceID),
				fmt.Sprintf("%s/dramaDetail/%s.html", base, sourceID),
				fmt.Sprintf("%s/detail/%s.html", base, sourceID),
			}
		},
	},
	provider.SourceWangguo: {
		catalogAddress: func(base, category string, page int) (string, error) {
			class := strings.TrimSpace(category)
			if class == "" {
				return fmt.Sprintf("%s/show/duanju-----------.html", base), nil
			}
			return fmt.Sprintf("%s%s%d---.html", base, strings.SplitN(class, "---.html", 2)[0], page), nil
		},
		searchAddress: func(base, query string) (string, error) {
			return fmt.Sprintf("%s/search/%s----------1---.html", base, url.PathEscape(query)), nil
		},
		detailURLs: func(base, sourceID string) []string {
			return []string{
				fmt.Sprintf("%s/vod/%s.html", base, sourceID),
				fmt.Sprintf("%s/index.php/vod/detail/id/%s.html", base, sourceID),
				fmt.Sprintf("%s/detail/%s.html", base, sourceID),
			}
		},
	},
}

type episode struct {
	Key   string
	Title string
	URL   string
	Index int
}

type Source struct {
	spec    provider.Spec
	profile profile
}

func New(spec provider.Spec) *Source {
	return &Source{spec: spec, profile: profiles[spec.ID]}
}

func (s *Source) Spec() provider.Spec { return s.spec }

func (s *Source) base(host provider.Host) string {
	if host != nil {
		if base := host.BaseURL(s.spec.ID); base != "" {
			return base
		}
	}
	return s.spec.Base
}

func (s *Source) fetchPage(ctx context.Context, host provider.Host, address, referer string) (*html.Node, error) {
	body, err := host.Text(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: referer})
	if err != nil {
		return nil, err
	}
	if len(body) > 4<<20 {
		return nil, errors.New("站源页面过大")
	}
	return html.Parse(strings.NewReader(body))
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	if categories, found := sourceCategories[s.spec.ID]; found {
		return categories, nil
	}
	return nil, errors.New("该站源暂未提供分类")
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.base(host)
	address, err := s.profile.catalogAddress(base, category, page)
	if err != nil {
		return nil, false, err
	}
	document, err := s.fetchPage(ctx, host, address, base+"/")
	if err != nil {
		return nil, false, err
	}
	items := s.cards(document, base)
	return items, len(items) > 0, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	var lastErr error
	for _, address := range s.profile.detailURLs(base, sourceID) {
		document, err := s.fetchPage(ctx, host, address, base+"/")
		if err != nil {
			lastErr = err
			continue
		}
		episodes := episodesFromDocument(document)
		if len(episodes) == 0 {
			lastErr = errors.New("未解析到分集列表")
			continue
		}
		drama := provider.Drama{
			ID:          provider.DramaID(s.spec.ID, sourceID),
			Source:      s.spec.ID,
			SourceID:    sourceID,
			Title:       detailTitle(document),
			Intro:       detailIntro(document),
			Cover:       detailCover(document, address),
			Category:    detailCategory(document),
			ChannelName: provider.SourceName(s.spec.ID),
		}
		var chapters []provider.Chapter
		for index, entry := range episodes {
			number := provider.EpisodeNumber(provider.FirstNonEmpty(entry.Title, entry.Key), index+1)
			link := provider.Absolute(base, entry.URL)
			if link == "" {
				continue
			}
			chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number, entry.Title, link, link, base+"/"))
		}
		if len(chapters) == 0 {
			lastErr = errors.New("未解析到可播放分集")
			continue
		}
		provider.SortChapters(chapters)
		drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
		return drama, chapters, nil
	}
	if lastErr == nil {
		lastErr = errors.New("未找到该剧的详情页")
	}
	return provider.Drama{}, nil, lastErr
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	base := s.base(host)
	address, err := s.profile.searchAddress(base, query)
	if err != nil {
		return nil, err
	}
	document, err := s.fetchPage(ctx, host, address, base+"/")
	if err != nil {
		return nil, err
	}
	return s.cards(document, base), nil
}

// 网页型站源的分集保存在播放页里，需要按页即时解析真实播放地址。
func (s *Source) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	base := s.base(host)
	name := provider.SourceName(s.spec.ID)
	pageURL := strings.TrimSpace(task.Chapter.PageURL)
	if pageURL == "" {
		return provider.Media{}, fmt.Errorf("%s分集缺少播放页面，请刷新详情后重试", name)
	}
	referer := provider.FirstNonEmpty(task.Chapter.Referer, base+"/")
	body, err := host.Text(ctx, provider.Request{Source: s.spec.ID, Address: pageURL, Referer: referer})
	if err != nil {
		return provider.Media{}, err
	}
	address := provider.NormalizePlaybackURL(provider.PlayerURL(body))
	if address == "" {
		return provider.Media{}, fmt.Errorf("%s未返回有效播放地址，请刷新章节后重试", name)
	}
	return provider.ResolveWebMedia(ctx, host, address, pageURL, name)
}

func episodeNodes(document *html.Node) []*html.Node {
	var nodes []*html.Node
	collect := func(match func(*html.Node) bool) {
		for _, list := range provider.HTMLNodes(document, match) {
			nodes = append(nodes, provider.HTMLNodes(list, func(node *html.Node) bool { return node.Data == "a" })...)
		}
	}
	for _, name := range []string{"content__playlist", "playlink", "pcDrama_catalogItem", "catalogItem", "playlist"} {
		collect(classMatcher(name))
	}
	if len(nodes) == 0 {
		for _, name := range []string{"tab-pane", "playlist", "playList"} {
			collect(classMatcher(name))
		}
	}
	if len(nodes) == 0 {
		nodes = provider.HTMLNodes(document, func(node *html.Node) bool {
			return node.Data == "a" && episodeLink.MatchString(provider.HTMLAttr(node, "href"))
		})
	}
	return nodes
}

func episodesFromDocument(document *html.Node) []episode {
	var episodes []episode
	seen := map[string]bool{}
	for index, anchor := range episodeNodes(document) {
		link := strings.TrimSpace(provider.HTMLAttr(anchor, "href"))
		title := provider.HTMLText(anchor)
		if link == "" {
			continue
		}
		if strings.Contains(title, "APP") || strings.Contains(title, "下载") {
			continue
		}
		key := link
		if seen[key] {
			continue
		}
		seen[key] = true
		episodes = append(episodes, episode{
			Key:   strconv.Itoa(index + 1),
			Title: title,
			URL:   link,
			Index: index + 1,
		})
	}
	return episodes
}

func cardCover(card *html.Node, pageURL string) string {
	for _, image := range provider.HTMLNodes(card, func(node *html.Node) bool { return node.Data == "img" }) {
		for _, attribute := range []string{"data-original", "data-src", "src"} {
			if address := provider.CoverAddress(provider.HTMLAttr(image, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	for _, anchor := range provider.HTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		for _, attribute := range []string{"data-original", "data-src"} {
			if address := provider.CoverAddress(provider.HTMLAttr(anchor, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	return ""
}

func cardTitle(card *html.Node) string {
	for _, attribute := range []string{"title", "alt"} {
		for _, node := range provider.HTMLNodes(card, func(node *html.Node) bool {
			return node.Data == "a" || node.Data == "img"
		}) {
			if text := strings.TrimSpace(provider.HTMLAttr(node, attribute)); text != "" {
				return text
			}
		}
	}
	for _, node := range provider.HTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		if text := provider.HTMLText(node); text != "" {
			return text
		}
	}
	return ""
}

func cardLink(card *html.Node, base string) string {
	for _, anchor := range provider.HTMLNodes(card, func(node *html.Node) bool { return node.Data == "a" }) {
		link := provider.HTMLAttr(anchor, "href")
		if link == "" || strings.Contains(link, "javascript:") {
			continue
		}
		if address := provider.Absolute(base, link); address != "" {
			return address
		}
	}
	return ""
}

func cardRemark(card *html.Node) string {
	for _, name := range []string{"meta-post-type2", "imagelabel", "module-item-note", "pic-text", "lastChapter", "SecondList_totalChapterNum", "SecondList_bookType"} {
		if node := provider.HTMLFirstClass(card, name); node != nil {
			if text := provider.HTMLText(node); text != "" {
				return text
			}
		}
	}
	return ""
}

var cardClasses = []string{
	"col-lg-2", "col-xl-2", "module-item", "module-poster-item", "public-list-box",
	"videoBox", "detail-list-item", "col-md-6", "col-6", "listItem", "FeaturedList_featuredItem",
	"BrowseList_listItem", "SecondList_secondListItem", "vodlist__item", "v_list",
	"entry-wrapper", "TagBookList_tagItem",
}

func (s *Source) cards(document *html.Node, base string) []provider.Drama {
	var cards []*html.Node
	seen := map[*html.Node]bool{}
	for _, name := range cardClasses {
		for _, node := range provider.HTMLNodes(document, classMatcher(name)) {
			if !seen[node] {
				seen[node] = true
				cards = append(cards, node)
			}
		}
	}
	if len(cards) == 0 {
		cards = anchorCards(document)
	}
	var items []provider.Drama
	ids := map[string]bool{}
	for _, card := range cards {
		link := cardLink(card, base)
		title := cardTitle(card)
		if link == "" || title == "" {
			continue
		}
		sourceID := sourceIDFromURL(link)
		if sourceID == "" || ids[sourceID] {
			continue
		}
		ids[sourceID] = true
		remark := cardRemark(card)
		items = append(items, provider.Drama{
			ID:           provider.DramaID(s.spec.ID, sourceID),
			Source:       s.spec.ID,
			SourceID:     sourceID,
			Title:        title,
			Cover:        cardCover(card, link),
			Remark:       remark,
			EpisodeCount: json.Number(strconv.Itoa(provider.EpisodeNumber(remark, 0))),
			ChannelName:  provider.SourceName(s.spec.ID),
		})
	}
	return items
}

func classMatcher(name string) func(*html.Node) bool {
	return func(node *html.Node) bool {
		for _, value := range strings.Fields(provider.HTMLAttr(node, "class")) {
			if value == name || strings.HasSuffix(value, "-"+name) {
				return true
			}
		}
		return false
	}
}

func anchorCards(document *html.Node) []*html.Node {
	var cards []*html.Node
	seen := map[*html.Node]bool{}
	for _, anchor := range provider.HTMLNodes(document, func(node *html.Node) bool {
		return node.Data == "a" && detailLink.MatchString(provider.HTMLAttr(node, "href"))
	}) {
		for parent := anchor.Parent; parent != nil && parent.Type == html.ElementNode; parent = parent.Parent {
			if seen[parent] {
				break
			}
			if parent.Data != "li" && parent.Data != "div" {
				continue
			}
			seen[parent] = true
			cards = append(cards, parent)
		}
	}
	return cards
}

func sourceIDFromURL(link string) string {
	parsed, err := url.Parse(link)
	if err != nil {
		return ""
	}
	path := strings.TrimSuffix(parsed.Path, ".html")
	if matches := detailPath.FindStringSubmatch(path + "/"); len(matches) > 1 {
		return matches[1]
	}
	cleaned := strings.Trim(path, "/")
	parts := strings.Split(cleaned, "/")
	for index := len(parts) - 1; index >= 0; index-- {
		candidate := strings.TrimSuffix(parts[index], ".html")
		if provider.IsNumericID(candidate) {
			return candidate
		}
		if _, tail, found := strings.Cut(candidate, "-"); found && provider.IsNumericID(tail) {
			return tail
		}
	}
	if id := parsed.Query().Get("id"); provider.IsNumericID(id) {
		return id
	}
	return ""
}

var titleSuffixes = []string{"在线观看", "免费观看", "高清完整版", "完整版", "全集", "在线播放", "高清", "免费"}

func detailTitle(document *html.Node) string {
	for _, name := range []string{"module-info-heading", "detail-title", "video-info-title", "page-title"} {
		if node := provider.HTMLFirstClass(document, name); node != nil {
			if text := provider.HTMLText(node); text != "" {
				return cleanTitle(text)
			}
		}
	}
	if node := provider.HTMLNodes(document, func(node *html.Node) bool { return node.Data == "title" }); len(node) > 0 {
		return cleanTitle(provider.HTMLText(node[0]))
	}
	return ""
}

func cleanTitle(raw string) string {
	text := strings.TrimSpace(raw)
	if text == "" {
		return ""
	}
	if cut, _, found := strings.Cut(text, " - "); found {
		text = strings.TrimSpace(cut)
	}
	if cut, _, found := strings.Cut(text, " _ "); found {
		text = strings.TrimSpace(cut)
	}
	for _, separator := range []string{"-", "_", "|"} {
		for {
			cut, _, found := strings.Cut(text, separator)
			if !found {
				break
			}
			head := strings.TrimSpace(cut)
			if !titleTailIsSeo(text[len(cut)+len(separator):]) {
				break
			}
			text = head
		}
	}
	for changed := true; changed; {
		changed = false
		for _, suffix := range titleSuffixes {
			if strings.HasSuffix(text, suffix) && len(text) > len(suffix) {
				text = strings.TrimSpace(strings.TrimSuffix(text, suffix))
				changed = true
			}
		}
	}
	text = strings.Trim(text, "-_|·— ")
	if text == "" {
		return strings.TrimSpace(raw)
	}
	return text
}

func titleTailIsSeo(tail string) bool {
	tail = strings.TrimSpace(tail)
	if tail == "" {
		return true
	}
	for _, marker := range []string{"短剧", "全集", "在线观看", "免费", "高清", "完整版", "视频", "剧场", "影院", "网"} {
		if strings.Contains(tail, marker) {
			return true
		}
	}
	return false
}

func detailIntro(document *html.Node) string {
	for _, name := range []string{"module-info-introduction-content", "detail-content", "video-info-content", "introduction_introEllipsis"} {
		if node := provider.HTMLFirstClass(document, name); node != nil {
			if text := provider.HTMLText(node); text != "" {
				return provider.Truncate(text, 2000)
			}
		}
	}
	for _, meta := range provider.HTMLNodes(document, func(node *html.Node) bool { return node.Data == "meta" }) {
		if strings.EqualFold(provider.HTMLAttr(meta, "name"), "description") {
			if content := strings.TrimSpace(provider.HTMLAttr(meta, "content")); content != "" {
				return provider.Truncate(content, 2000)
			}
		}
	}
	return ""
}

func detailCover(document *html.Node, pageURL string) string {
	for _, name := range []string{"module-item-pic", "detail-pic", "video-info-pic", "pic"} {
		for _, node := range provider.HTMLNodes(document, func(node *html.Node) bool { return provider.HTMLClass(node, name) }) {
			if address := cardCover(node, pageURL); address != "" {
				return address
			}
		}
	}
	for _, image := range provider.HTMLNodes(document, func(node *html.Node) bool { return node.Data == "img" }) {
		for _, attribute := range []string{"data-original", "data-src", "src"} {
			if address := provider.CoverAddress(provider.HTMLAttr(image, attribute), pageURL); address != "" {
				return address
			}
		}
	}
	return ""
}

func detailCategory(document *html.Node) string {
	for _, name := range []string{"module-info-tag-link", "detail-tag", "video-info-actor"} {
		nodes := provider.HTMLNodes(document, func(node *html.Node) bool { return provider.HTMLClass(node, name) })
		if len(nodes) > 0 {
			var parts []string
			for _, anchor := range provider.HTMLNodes(nodes[0], func(node *html.Node) bool { return node.Data == "a" }) {
				if text := provider.HTMLText(anchor); text != "" {
					parts = append(parts, text)
				}
			}
			if len(parts) > 0 {
				return provider.CSV(parts)
			}
		}
	}
	return ""
}
