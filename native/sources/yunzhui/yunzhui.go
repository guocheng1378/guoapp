package yunzhui

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
	"sync"
	"time"

	"duanjuapp/native/provider"
)

const (
	apiAppID   = "yunzhuishipin"
	apiPackage = "com.hjmore.jsyfjz"
	apiVersion = "51000"
	imgBase    = "http://wim.xzjykj.com/"
	tokenTTL   = 30 * time.Minute
	storeKey   = "yunzhui"
)

var apiHosts = []string{"u.gslock.com", "u.alvzz.com", "u.irltk.com", "u.yyxdmn.com"}

type channelSpec struct {
	Name     string
	TypeID   string
	Area     string
	Sort     string
	Featured bool
}

type Source struct {
	spec provider.Spec

	mu           sync.Mutex
	hostIdx      int
	token        string
	tokenAt      time.Time
	device       string
	loaded       bool
	channelSpecs map[string]channelSpec
}

func New(spec provider.Spec) *Source {
	return &Source{spec: spec}
}

// ensureLoaded 懒加载持久化的游客身份（device/token）。
// 不能在 New() 里读盘：provider 的 Store 由 core 引擎在 newNativeEngine 里
// 注入，而本包的 init() 注册早于引擎创建——那时 store 还是 nil，磁盘上的
// 身份永远读不回来，等于每次启动都换一个新游客。
func (s *Source) ensureLoaded() {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.loaded {
		return
	}
	s.loaded = true
	if data, err := provider.ReadStore(storeKey); err == nil {
		var saved struct {
			Device  string `json:"device"`
			Token   string `json:"token"`
			TokenAt int64  `json:"tokenAt"`
		}
		if json.Unmarshal(data, &saved) == nil && len(saved.Device) == 16 {
			s.device = saved.Device
			s.token = saved.Token
			if saved.TokenAt > 0 {
				s.tokenAt = time.UnixMilli(saved.TokenAt)
			}
		}
	}
	if s.device == "" {
		buf := make([]byte, 8)
		_, _ = rand.Read(buf)
		s.device = hex.EncodeToString(buf)
	}
}

func (s *Source) Spec() provider.Spec { return s.spec }

func (s *Source) host() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	return apiHosts[s.hostIdx%len(apiHosts)]
}

func (s *Source) rotate() {
	s.mu.Lock()
	s.hostIdx++
	s.mu.Unlock()
}

func (s *Source) persistLocked() {
	data, err := json.Marshal(map[string]any{
		"device":  s.device,
		"token":   s.token,
		"tokenAt": s.tokenAt.UnixMilli(),
	})
	if err == nil {
		_ = provider.WriteStore(storeKey, data)
	}
}

func (s *Source) call(ctx context.Context, host provider.Host, path string, form map[string]string, authed bool) (map[string]any, error) {
	// 每次请求前确保游客身份已就绪（首次会读盘恢复 device/token）。
	s.ensureLoaded()
	if form == nil {
		form = map[string]string{}
	}
	token := ""
	if authed {
		cached, err := s.ensureToken(ctx, host)
		if err != nil {
			return nil, err
		}
		token = cached
	}
	ts := strconv.FormatInt(time.Now().UnixMilli(), 10)
	fields := map[string][]string{}
	for k, v := range form {
		fields[k] = []string{v}
	}
	var lastErr error
	for attempt := 0; attempt < len(apiHosts); attempt++ {
		request := provider.Request{
			Source:  s.spec.ID,
			Method:  "POST",
			Address: "https://" + s.host() + path,
			Form:    fields,
			Timeout: 20 * time.Second,
			Headers: map[string]string{
				"app_id":       apiAppID,
				"package_name": apiPackage,
				"version":      apiVersion,
				"sys_platform": "2",
				"mob_mfr":      "xiaomi",
				"mobmodel":     "2211133C",
				"sysrelease":   "15",
				"device_id":    s.device,
				"channel_code": "official",
				"cur_time":     ts,
				"token":        token,
				"sign":         sign(s.device, ts),
				"Content-Type": "application/x-www-form-urlencoded",
			},
		}
		raw, err := host.Bytes(ctx, request)
		if err != nil {
			lastErr = err
			s.rotate()
			continue
		}
		plain, err := decrypt(raw)
		if err != nil {
			plain = raw
		}
		var decoded map[string]any
		if err := json.Unmarshal(plain, &decoded); err != nil {
			lastErr = err
			s.rotate()
			continue
		}
		if num(decoded["code"]) != "10000" {
			lastErr = errors.New("yunzhui: " + str(decoded["message"]))
			s.rotate()
			continue
		}
		return decoded, nil
	}
	if lastErr == nil {
		lastErr = errors.New("yunzhui: request failed")
	}
	return nil, lastErr
}

func (s *Source) ensureToken(ctx context.Context, host provider.Host) (string, error) {
	s.mu.Lock()
	if s.token != "" && time.Since(s.tokenAt) < tokenTTL {
		value := s.token
		s.mu.Unlock()
		return value, nil
	}
	s.mu.Unlock()

	decoded, err := s.call(ctx, host, "/api/new_public/init_v2", nil, false)
	if err != nil {
		return "", err
	}
	result, _ := decoded["result"].(map[string]any)
	info, _ := result["user_info"].(map[string]any)
	token := str(info["token"])
	if token == "" {
		return "", errors.New("yunzhui: empty guest token")
	}
	s.mu.Lock()
	s.token, s.tokenAt = token, time.Now()
	s.persistLocked()
	s.mu.Unlock()
	return token, nil
}

func (s *Source) channels(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, map[string]channelSpec, error) {
	decoded, err := s.call(ctx, host, "/api/new_channel/get_list_v2", nil, false)
	if err != nil {
		return nil, nil, err
	}
	list, _ := decoded["result"].([]any)
	order := make([]provider.CatalogCategory, 0, len(list))
	specs := make(map[string]channelSpec, len(list))
	for _, row := range list {
		item, _ := row.(map[string]any)
		id := num(item["id"])
		name := str(item["channel_name"])
		if id == "" || name == "" {
			continue
		}
		specs[id] = channelSpec{
			Name:     name,
			TypeID:   num(item["vod_type_id"]),
			Area:     str(item["screen_area"]),
			Sort:     str(item["screen_sort"]),
			Featured: name == "推荐",
		}
		order = append(order, provider.CatalogCategory{ID: id, Name: name})
	}
	if len(order) == 0 {
		return nil, nil, errors.New("yunzhui: empty channels")
	}
	return order, specs, nil
}

func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
	order, specs, err := s.channels(ctx, host)
	if err != nil {
		return nil, err
	}
	s.mu.Lock()
	s.channelSpecs = specs
	s.mu.Unlock()
	return order, nil
}

func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
	return s.CatalogPageSorted(ctx, host, page, category, "")
}

func (s *Source) CatalogPageSorted(ctx context.Context, host provider.Host, page int, category, sort string) ([]provider.Drama, bool, error) {
	if page < 1 {
		page = 1
	}
	s.mu.Lock()
	specs := s.channelSpecs
	s.mu.Unlock()
	if specs == nil {
		if _, loaded, err := s.channels(ctx, host); err == nil {
			s.mu.Lock()
			s.channelSpecs = loaded
			specs = loaded
			s.mu.Unlock()
		}
	}
	spec, found := specs[category]
	if !found {
		for _, candidate := range specs {
			if candidate.Name == category {
				spec, found = candidate, true
				break
			}
		}
	}
	if spec.Featured {
		decoded, err := s.call(ctx, host, "/api/new_search/recommend_v2", nil, false)
		if err != nil {
			return nil, false, err
		}
		return s.dramas(decoded), false, nil
	}
	form := map[string]string{"pn": strconv.Itoa(page), "type_id": spec.TypeID}
	if spec.Area != "" {
		form["area"] = spec.Area
	}
	if spec.Sort != "" {
		form["sort"] = spec.Sort
	}
	if mapped := mapSort(sort); mapped != "" {
		form["sort"] = mapped
	}
	decoded, err := s.call(ctx, host, "/api/new_search/screen_v2", form, false)
	if err != nil {
		return nil, false, err
	}
	list := s.dramas(decoded)
	return list, len(list) >= 20, nil
}

func mapSort(sort string) string {
	switch sort {
	case "heat", "views":
		return "最热"
	case "date":
		return "日榜"
	}
	return ""
}

func (s *Source) dramas(decoded map[string]any) []provider.Drama {
	list, _ := decoded["result"].([]any)
	out := make([]provider.Drama, 0, len(list))
	for _, row := range list {
		if item, ok := row.(map[string]any); ok {
			out = append(out, s.toDrama(item))
		}
	}
	return out
}

func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
	query = strings.TrimSpace(query)
	if query == "" {
		return nil, nil
	}
	decoded, err := s.call(ctx, host, "/api/new_search/result_v2", map[string]string{"kw": query, "pn": "1"}, false)
	if err != nil {
		return nil, err
	}
	return s.dramas(decoded), nil
}

func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
	decoded, err := s.detailRaw(ctx, host, sourceID)
	if err != nil {
		return provider.Drama{}, nil, err
	}
	drama := s.toDrama(decoded)
	chapters := make([]provider.Chapter, 0)
	list, _ := decoded["vod_collection"].([]any)
	for _, row := range list {
		item, _ := row.(map[string]any)
		number, _ := strconv.Atoi(num(item["collection"]))
		chapters = append(chapters, provider.NewChapter(
			s.spec.ID, sourceID, number,
			str(item["title_desc"]), "", "", "",
		))
	}
	provider.SortChapters(chapters)
	return drama, chapters, nil
}

func (s *Source) detailRaw(ctx context.Context, host provider.Host, sourceID string) (map[string]any, error) {
	decoded, err := s.call(ctx, host, "/api/new_video/result_v2", map[string]string{"vod_id": sourceID}, true)
	if err != nil {
		return nil, err
	}
	result, _ := decoded["result"].(map[string]any)
	if len(result) == 0 {
		return nil, errors.New("yunzhui: empty detail")
	}
	return result, nil
}

func (s *Source) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
	dramaID := strings.TrimSpace(task.DramaID)
	if dramaID == "" {
		return provider.Media{}, errors.New("yunzhui: missing drama id")
	}
	// Task.DramaID 形如 "yunzhui:175520"（带站源前缀），而 vod_id 只认数字部分，
	// 直接透传会取不到剧目。优先用注册表反解，退化时手工剥掉前缀。
	if _, sourceID, ok := provider.SplitDramaID(dramaID); ok && sourceID != "" {
		dramaID = sourceID
	} else if index := strings.Index(dramaID, ":"); index >= 0 {
		dramaID = dramaID[index+1:]
	}
	detail, err := s.detailRaw(ctx, host, dramaID)
	if err != nil {
		return provider.Media{}, err
	}
	episode := pickEpisode(detail, task.Chapter.EpisodeString(task.Index+1))
	if episode == nil {
		return provider.Media{}, errors.New("yunzhui: episode not found")
	}
	decoded, err := s.call(ctx, host, "/api/new_video/collection_v2", map[string]string{
		"vod_token":     str(episode["vod_token"]),
		"cur_time":      num(episode["cur_time"]),
		"vod_id":        dramaID,
		"collection_id": num(episode["id"]),
		"session_id":    "",
		"sig":           "",
		"nc_token":      "",
		"phone":         "",
		"code":          "",
	}, true)
	if err != nil {
		return provider.Media{}, err
	}
	result, _ := decoded["result"].(map[string]any)
	medias := buildMedias(result)
	if len(medias) == 0 {
		return provider.Media{}, errors.New("yunzhui: no playable source")
	}
	primary := medias[0]
	primary.Variants = append(primary.Variants, medias[1:]...)
	return primary, nil
}

func buildMedias(result map[string]any) []provider.Media {
// The CDN answers 403 to every non-empty Referer (verified against chw.ycblhs.com
// with u.gslock.com / chw.ycblhs.com / www.gslock.com), so the media address must
// be requested without a Referer header at all.

	out := make([]provider.Media, 0, 4)
	var items []map[string]any
	switch raw := result["m3u8_json"].(type) {
	case string:
		if strings.TrimSpace(raw) != "" {
			_ = json.Unmarshal([]byte(raw), &items)
		}
	case []any:
		for _, row := range raw {
			if item, ok := row.(map[string]any); ok {
				items = append(items, item)
			}
		}
	}
	for _, item := range items {
		if address := str(item["url"]); address != "" {
			out = append(out, provider.Media{URL: address})
		}
	}
	if fallback := str(result["vod_url"]); fallback != "" {
		out = append(out, provider.Media{URL: fallback})
	}
	return out
}

func pickEpisode(detail map[string]any, episode string) map[string]any {
	list, _ := detail["vod_collection"].([]any)
	var first map[string]any
	for _, row := range list {
		item, _ := row.(map[string]any)
		if first == nil {
			first = item
		}
		if num(item["collection"]) == episode || str(item["title"]) == episode {
			return item
		}
	}
	return first
}

func (s *Source) Probe(ctx context.Context, host provider.Host) (string, error) {
	decoded, err := s.call(ctx, host, "/api/new_public/init_v2", nil, false)
	if err != nil {
		return "", err
	}
	result, _ := decoded["result"].(map[string]any)
	info, _ := result["user_info"].(map[string]any)
	page, _, err := s.screen(ctx, host, map[string]string{"pn": "1"})
	if err != nil {
		return "", err
	}
	if len(page) == 0 {
		return "", errors.New("yunzhui: empty catalog")
	}
	return fmt.Sprintf("接口正常（%s），首屏 %d 条", str(info["nickname"]), len(page)), nil
}

func (s *Source) screen(ctx context.Context, host provider.Host, form map[string]string) ([]provider.Drama, bool, error) {
	decoded, err := s.call(ctx, host, "/api/new_search/screen_v2", form, false)
	if err != nil {
		return nil, false, err
	}
	list := s.dramas(decoded)
	return list, len(list) >= 20, nil
}

func (s *Source) toDrama(raw map[string]any) provider.Drama {
	id := num(raw["id"])
	title := str(raw["vod_name"])
	drama := provider.Drama{
		ID:            s.spec.ID + ":" + id,
		Source:        s.spec.ID,
		SourceID:      id,
		Title:         title,
		Name:          title,
		Desc:          firstNonEmpty(str(raw["vod_blurb"]), str(raw["remarks"])),
		Cover:         s.coverURL(str(raw["vod_pic"])),
		Episodes:      num(raw["vod_serial"]),
		Category:      categoryName(num(raw["type_pid"])),
		Area:          str(raw["vod_area"]),
		Year:          str(raw["vod_year"]),
		Score:         str(raw["vod_douban_score"]),
		Heat:          firstNonEmpty(num(raw["click_count"]), num(raw["total_view_count"])),
		Tags:          splitTags(str(raw["vod_tag"])),
		ReleaseStatus: releaseStatus(num(raw["vod_isend"])),
	}
	if drama.Cover == "" {
		drama.Cover = nil
	}
	return drama
}

func (s *Source) coverURL(pic string) string {
	pic = strings.TrimSpace(pic)
	if pic == "" {
		return ""
	}
	if strings.HasPrefix(pic, "http://") || strings.HasPrefix(pic, "https://") {
		return pic
	}
	return imgBase + strings.TrimPrefix(pic, "/")
}

func splitTags(value string) []string {
	if strings.TrimSpace(value) == "" {
		return nil
	}
	parts := strings.FieldsFunc(value, func(r rune) bool { return r == ',' || r == '，' || r == '/' })
	out := make([]string, 0, len(parts))
	for _, part := range parts {
		if trimmed := strings.TrimSpace(part); trimmed != "" {
			out = append(out, trimmed)
		}
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func releaseStatus(value string) string {
	switch value {
	case "1":
		return "finished"
	case "0":
		return "ongoing"
	}
	return "unknown"
}

func categoryName(pid string) string {
	switch pid {
	case "1":
		return "电影"
	case "2":
		return "国产剧"
	case "3":
		return "综艺"
	case "4":
		return "国漫"
	}
	return ""
}

func str(value any) string {
	switch typed := value.(type) {
	case string:
		return typed
	case float64:
		if typed == float64(int64(typed)) {
			return strconv.FormatInt(int64(typed), 10)
		}
		return strconv.FormatFloat(typed, 'f', -1, 64)
	case int:
		return strconv.Itoa(typed)
	case json.Number:
		return typed.String()
	default:
		return ""
	}
}

func num(value any) string { return str(value) }

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if strings.TrimSpace(value) != "" {
			return value
		}
	}
	return ""
}
