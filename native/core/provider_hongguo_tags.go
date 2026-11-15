package core

import (
	"context"
	"errors"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
	"strings"
)

// 红果题材标签：站点在「新分类落地页」下发的 dialog_bottom 选择器里给出
// 一批真实题材（selector_item_id 形如 cate_xxx），比本地写死的 hongguoAppGenres
// 更能跟站点同步。分类 ID 统一加 tag: 前缀，目录分页按该前缀单独走落地页接口。
const (
	hongguoTagPrefix        = "tag:"
	hongguoTagLandingPath   = "/reading/bookapi/new_category/landing/v/"
	hongguoTagPanelCategory = "5000"
	hongguoTagPageSize      = 12
)

var hongguoTagPattern = regexp.MustCompile(`^tag:cate_[0-9]{1,9}$`)

type hongguoTagCursor struct {
	page    int
	offset  int
	session string
}

func hongguoTagQuery(offset int, session string) url.Values {
	query := url.Values{
		"genre_type": {"130"}, "query_gender": {"1"}, "category_type": {"5"}, "page_version": {"2"},
		"source": {"detail"}, "limit": {strconv.Itoa(hongguoTagPageSize)}, "offset": {strconv.Itoa(offset)},
		"client_req_type": {"3"},
	}
	if offset > 0 {
		query.Set("client_req_type", "2")
	}
	if session != "" {
		query.Set("session_id", session)
	}
	return query
}

// fetchHongguoTagCategories 拉取站点真实题材标签，产出 tag:cate_xxx 分类。
func (downloader *Downloader) fetchHongguoTagCategories(ctx context.Context) ([]nativeCategory, error) {
	query := hongguoTagQuery(0, "")
	query.Set("category_id", hongguoTagPanelCategory)
	query.Set("selected_item_from_front_page", hongguoTagPanelCategory)
	query.Set("is_merged_landing_page", "true")
	query.Set("category_new_page_715", "1")
	result, err := downloader.hongguoAppRequest(ctx, http.MethodGet, hongguoTagLandingPath, query, nil)
	if err != nil {
		return nil, err
	}
	var categories []nativeCategory
	seen := map[string]bool{}
	for _, value := range anyList(nestedMap(result, "data", "selector")["rows"]) {
		row, _ := value.(map[string]any)
		if mapString(row, "type") != "dialog_bottom" {
			continue
		}
		for _, value := range anyList(row["items"]) {
			item, _ := value.(map[string]any)
			id := hongguoTagPrefix + mapString(item, "selector_item_id")
			name := strings.TrimSpace(mapString(item, "show_name"))
			if name == "" || seen[id] || !hongguoTagPattern.MatchString(id) {
				continue
			}
			seen[id] = true
			categories = append(categories, nativeCategory{ID: id, Name: name})
		}
	}
	if len(categories) == 0 {
		return nil, errors.New("红果题材列表为空")
	}
	return categories, nil
}

// fetchHongguoTagPage 按题材分页取剧集；游标（下一页 offset/session）记在
// client.tagCursors 里，缺省或页号不连续时按页号重建。
func (downloader *Downloader) fetchHongguoTagPage(ctx context.Context, category string, page int) ([]Drama, bool, error) {
	client := downloader.hongguoClient()
	client.mu.Lock()
	cursor := client.tagCursors[category]
	client.mu.Unlock()
	if cursor.page != page-1 {
		cursor = hongguoTagCursor{page: page - 1, offset: (page - 1) * hongguoTagPageSize}
	}
	query := hongguoTagQuery(cursor.offset, cursor.session)
	query.Set("category_id", "0")
	query.Set("selected_items", strings.TrimPrefix(category, hongguoTagPrefix))
	query.Set("selected_order", "new_sort_hot")
	result, err := downloader.hongguoAppRequest(ctx, http.MethodGet, hongguoTagLandingPath, query, nil)
	if err != nil {
		return nil, false, err
	}
	data := nestedMap(result, "data")
	rows := anyList(data["video_info"])
	dramas := make([]Drama, 0, len(rows))
	for _, row := range rows {
		if drama := hongguoDramaFromAny(row, "真人剧"); drama.ID != "" {
			dramas = append(dramas, drama)
		}
	}
	if len(rows) > 0 && len(dramas) == 0 {
		return nil, false, errors.New("红果题材未返回可识别的剧集")
	}
	more, _ := data["has_more"].(bool)
	next, parseErr := strconv.Atoi(mapString(data, "offset"))
	if parseErr != nil || next <= cursor.offset {
		next, more = cursor.offset+len(rows), more && len(rows) > 0
	}
	client.mu.Lock()
	client.tagCursors[category] = hongguoTagCursor{page: page, offset: next, session: mapString(data, "session_id")}
	client.mu.Unlock()
	return dramas, more, nil
}
