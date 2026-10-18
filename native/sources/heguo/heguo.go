package heguo

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"

	"duanjuapp/native/provider"
)

const (
	searchPath       = "/seo/video/6007"
	searchPName      = "www.kuaikaw.cn"
	searchSourceType = 1
)

var (
	nextDataPattern    = regexp.MustCompile(`(?s)<script id="__NEXT_DATA__" type="application/json">(.*?)</script>`)
	nextEpisodePattern = regexp.MustCompile(`(?i)(https?://[^"'\s<>\\]+\.(?:mp4|m3u8)[^"'\s<>\\]*)`)
)

var categories = []provider.CatalogCategory{
	{ID: "462", Name: "甜宠"},
	{ID: "1102", Name: "古装仙侠"},
	{ID: "1145", Name: "现代言情"},
	{ID: "1170", Name: "青春"},
	{ID: "585", Name: "豪门恩怨"},
	{ID: "417-464", Name: "逆袭"},
	{ID: "439-465", Name: "重生"},
	{ID: "1159", Name: "系统"},
	{ID: "1147", Name: "总裁"},
	{ID: "943", Name: "职场商战"},
}

type Source struct {
	spec provider.Spec
}

func New(spec provider.Spec) *Source {
	return &Source{spec: spec}
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

func formatCount(value int) string {
	if value <= 0 {
		return ""
	}
	return strconv.Itoa(value) + "集"
}

func nextPageProps(body string) map[string]any {
	matches := nextDataPattern.FindStringSubmatch(body)
	if len(matches) < 2 {
		return nil
	}
	var decoded map[string]any
	if json.Unmarshal([]byte(matches[1]), &decoded) != nil {
		return nil
	}
	props, _ := decoded["props"].(map[string]any)
	pageProps, _ := props["pageProps"].(map[string]any)
	return pageProps
}

func (s *Source) dramaFromBook(book map[string]any, base string) provider.Drama {
	id := provider.FindString(book, "bookId", "book_id", "id")
	if id == "" {
		return provider.Drama{}
	}
	status := provider.FindString(book, "statusDesc")
	total := provider.FindInt(book, "totalChapterNum")
	remark := strings.TrimSpace(status + " " + formatCount(total))
	return provider.Drama{
		ID:            provider.DramaID(s.spec.ID, id),
		Source:        s.spec.ID,
		SourceID:      id,
		Title:         provider.FindString(book, "bookName", "title", "name"),
		Intro:         provider.FindString(book, "introduction", "intro", "description"),
		Cover:         provider.Cover(base, book, "coverWap", "cover", "coverUrl"),
		Remark:        remark,
		EpisodeCount:  json.Number(strconv.Itoa(total)),
		ChannelName:   provider.SourceName(s.spec.ID),
		ReleaseStatus: provider.ReleaseStatus(status, total, 0),
	}
}

func (s *Source) books(pageProps map[string]any, base string) []provider.Drama {
	var items []provider.Drama
	seen := map[string]bool{}
	appendBooks := func(rows []any) {
		for _, entry := range rows {
			book, ok := entry.(map[string]any)
			if !ok {
				continue
			}
			drama := s.dramaFromBook(book, base)
			if drama.ID == "" || seen[drama.ID] {
				continue
			}
			seen[drama.ID] = true
			items = append(items, drama)
		}
	}
	for _, key := range []string{"bannerList", "bookList", "recommendList"} {
		appendBooks(provider.FindList(pageProps, key))
	}
	for _, entry := range provider.FindList(pageProps, "seoColumnVos") {
		column, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		appendBooks(provider.FindList(column, "bookInfos"))
	}
	return items
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	return categories, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	base := s.base(host)
	address := base + "/"
	if class := strings.TrimSpace(category); class != "" {
		address = base + "/browse/" + url.PathEscape(class) + "/" + strconv.Itoa(page)
	}
	body, err := host.Text(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return nil, false, err
	}
	pageProps := nextPageProps(body)
	if pageProps == nil {
		return nil, false, errors.New("河果页面结构无法识别")
	}
	items := s.books(pageProps, base)
	totalPages := provider.FindInt(pageProps, "pages")
	current := provider.FindInt(pageProps, "page")
	if current <= 0 {
		current = page
	}
	return items, totalPages > current, nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	base := s.base(host)
	address := base + "/drama/" + url.PathEscape(sourceID)
	body, err := host.Text(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
	if err != nil {
		return provider.Drama{}, nil, err
	}
	pageProps := nextPageProps(body)
	if pageProps == nil {
		return provider.Drama{}, nil, errors.New("河果详情页结构无法识别")
	}
	book := provider.FindMap(pageProps, "bookInfoVo")
	if book == nil {
		return provider.Drama{}, nil, errors.New("河果未返回剧集资料")
	}
	drama := s.dramaFromBook(book, base)
	drama.ID, drama.Source, drama.SourceID = provider.DramaID(s.spec.ID, sourceID), s.spec.ID, sourceID
	drama.Category = provider.CSV(provider.StringList(book["categoryList"]))
	drama.Tags = provider.StringList(book["categoryList"])
	if performers := provider.StringList(book["performerList"]); len(performers) > 0 {
		drama.Remark = strings.TrimSpace(drama.Remark)
	}
	var chapters []provider.Chapter
	for index, entry := range provider.FindList(pageProps, "chapterList") {
		chapter, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		chapterID := provider.FindString(chapter, "chapterId", "chapter_id", "id")
		title := provider.FindString(chapter, "chapterName", "title")
		if chapterID == "" {
			continue
		}
		number := provider.FindInt(chapter, "chapterNum", "sort", "index")
		if number <= 0 {
			number = index + 1
		}
		pageURL := base + "/episode/" + url.PathEscape(sourceID) + "/" + url.PathEscape(chapterID)
		chapters = append(chapters, provider.NewChapter(s.spec.ID, sourceID, number, title, "", pageURL, base+"/"))
	}
	if len(chapters) == 0 {
		return drama, nil, errors.New("河果未返回可播放分集")
	}
	provider.SortChapters(chapters)
	drama.EpisodeCount = json.Number(strconv.Itoa(len(chapters)))
	return drama, chapters, nil
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	keyword := strings.TrimSpace(query)
	if keyword == "" {
		return nil, errors.New("请输入搜索关键词")
	}
	base := s.base(host)
	body, err := json.Marshal(map[string]any{
		"sourceType": searchSourceType,
		"keyword":    keyword,
		"index":      1,
	})
	if err != nil {
		return nil, err
	}
	response, err := host.JSON(ctx, provider.Request{
		Source:  s.spec.ID,
		Method:  http.MethodPost,
		Address: base + searchPath,
		Referer: base + "/",
		Headers: map[string]string{"Content-Type": "application/json", "pname": searchPName},
		Body:    body,
	})
	if err != nil {
		return nil, err
	}
	items := s.searchBooks(response, base)
	if len(items) == 0 {
		return nil, errors.New("河果未搜索到相关剧集")
	}
	return items, nil
}

func (s *Source) searchBooks(response map[string]any, base string) []provider.Drama {
	data := provider.FindMap(response, "data")
	var items []provider.Drama
	seen := map[string]bool{}
	for _, entry := range provider.FindList(data, "bookList") {
		book, ok := entry.(map[string]any)
		if !ok {
			continue
		}
		drama := s.dramaFromBook(book, base)
		if drama.ID == "" || seen[drama.ID] {
			continue
		}
		seen[drama.ID] = true
		items = append(items, drama)
	}
	return items
}

func (s *Source) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	base := s.base(host)
	pageURL := strings.TrimSpace(task.Chapter.PageURL)
	if pageURL == "" {
		return provider.Media{}, errors.New("河果分集缺少播放页面，请刷新详情后重试")
	}
	body, err := host.Text(ctx, provider.Request{Source: s.spec.ID, Address: pageURL, Referer: base + "/"})
	if err != nil {
		return provider.Media{}, err
	}
	address := ""
	if pageProps := nextPageProps(body); pageProps != nil {
		if chapter := provider.FindMap(pageProps, "chapterInfo"); chapter != nil {
			if video := provider.FindMap(chapter, "chapterVideoVo"); video != nil {
				for _, key := range []string{"mp4", "mp4720p", "vodMp4Url"} {
					if candidate := provider.FindString(video, key); candidate != "" {
						address = candidate
						break
					}
				}
			}
		}
	}
	if address == "" {
		if matches := nextEpisodePattern.FindStringSubmatch(body); len(matches) > 1 {
			address = strings.ReplaceAll(matches[1], `\/`, `/`)
		}
	}
	if address == "" {
		return provider.Media{}, errors.New("河果未返回有效播放地址，请刷新章节后重试")
	}
	return provider.ResolveWebMedia(ctx, host, address, pageURL, provider.SourceName(s.spec.ID))
}
