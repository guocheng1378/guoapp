package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"duanjuapp/native/provider"
)

const (
	yzAESKey = "aZ9$kU5%qI7=yC2=zH2#gM0@pX7^wF3a"
	yzAESIV  = "hY2&tN3]kF7,dL7="
	yzToken  = "gAAAAABq_GupSEHMTfWZRh-test-guest-token-value"
)

// yzEnvelope 按云追真网协议把业务对象包成 code=10000 + AES-CBC + Base64 响应。
func yzEnvelope(t *testing.T, result any) string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"code": 10000, "message": "成功", "result": result})
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher([]byte(yzAESKey))
	if err != nil {
		t.Fatal(err)
	}
	pad := aes.BlockSize - len(raw)%aes.BlockSize
	padded := append([]byte{}, raw...)
	for i := 0; i < pad; i++ {
		padded = append(padded, byte(pad))
	}
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, []byte(yzAESIV)).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(out)
}

// fakeYunzhuiServer 按云追真网结构提供 7 个 POST 接口，全部返回加密响应。
// 用 channel id 331=推荐、333=国产剧(type_id=2,area=内地)，与真网一致。
func fakeYunzhuiServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	var serverURL string
	write := func(w http.ResponseWriter, result any) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(yzEnvelope(t, result)))
	}
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		// 媒体 CDN：m3u8 播放列表端点（prepareWebMedia 会抓它展开 playlist）。
		if r.Method == http.MethodGet && strings.HasSuffix(r.URL.Path, ".m3u8") {
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:10.0,\nseg0.ts\n#EXT-X-ENDLIST\n"))
			return
		}
		if r.Method != http.MethodPost {
			http.Error(w, "POST only", http.StatusMethodNotAllowed)
			return
		}
		// 每个请求都必须带齐签名相关头（校验模块确实按协议构造）。
		for _, key := range []string{"app_id", "device_id", "cur_time", "sign", "Content-Type"} {
			if r.Header.Get(key) == "" {
				http.Error(w, "missing header "+key, http.StatusBadRequest)
				return
			}
		}
		if r.Header.Get("app_id") != "yunzhuishipin" {
			http.Error(w, "bad app_id", http.StatusForbidden)
			return
		}
		if len(r.Header.Get("device_id")) != 16 || len(r.Header.Get("sign")) != 32 {
			http.Error(w, "bad device/sign", http.StatusForbidden)
			return
		}
		_ = r.ParseForm()
		switch r.URL.Path {
		case "/api/new_public/init_v2":
			write(w, map[string]any{"user_info": map[string]any{"token": yzToken, "nickname": "游客"}})
		case "/api/new_channel/get_list_v2":
			write(w, []any{
				map[string]any{"id": 331, "channel_name": "推荐", "vod_type_id": 0, "screen_area": "", "screen_sort": ""},
				map[string]any{"id": 333, "channel_name": "国产剧", "vod_type_id": 2, "screen_area": "内地", "screen_sort": ""},
				map[string]any{"id": 334, "channel_name": "电影", "vod_type_id": 1, "screen_area": "", "screen_sort": ""},
			})
		case "/api/new_search/recommend_v2":
			write(w, []any{yzDrama(175520, "谷雨", "30"), yzDrama(144834, "第二部", "18")})
		case "/api/new_search/screen_v2":
			write(w, []any{yzDrama(175520, "谷雨", "30"), yzDrama(144834, "第二部", "18")})
		case "/api/new_search/result_v2":
			write(w, []any{yzDrama(999001, "战神归来", "12")})
		case "/api/new_video/result_v2":
			write(w, yzDetail())
		case "/api/new_video/collection_v2":
			write(w, yzCollection(serverURL))
		default:
			http.NotFound(w, r)
		}
	})
	server := httptest.NewServer(mux)
	serverURL = server.URL
	t.Cleanup(server.Close)
	return server
}

func yzDrama(id int, title, serial string) map[string]any {
	return map[string]any{
		"id": id, "vod_name": title, "vod_blurb": "云追简介", "remarks": "第1-30集",
		"vod_pic": "/upload/" + fmt.Sprint(id) + ".jpg", "vod_serial": serial,
		"type_pid": 2, "vod_area": "内地", "vod_year": "2026", "vod_douban_score": "8.1",
		"click_count": "12345", "total_view_count": "99999", "vod_tag": "国产, 喜剧/爱情",
		"vod_isend": 1,
	}
}

func yzDetail() map[string]any {
	drama := yzDrama(175520, "谷雨", "30")
	drama["vod_collection"] = []any{
		map[string]any{"id": 4682182, "collection": "2", "title": "2", "title_desc": "第2集", "vod_token": "tok2", "cur_time": 1794927528},
		map[string]any{"id": 4682183, "collection": "1", "title": "1", "title_desc": "第1集", "vod_token": "tok1", "cur_time": 1794927529},
	}
	return drama
}

func yzCollection(base string) map[string]any {
	return map[string]any{
		"m3u8_json": []any{
			map[string]any{"zname": "备用高清", "url": base + "/vod/ep.m3u8"},
		},
		"vod_url": base + "/vod/fallback.m3u8",
	}
}

func installYunzhuiTestModule(t *testing.T, base string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["yunzhui"]
	if !found || source.code == nil {
		t.Fatal("未找到内置云追模块")
	}
	manifest := source.manifest
	manifest.ID = "yunzhuiclique"
	manifest.Name = "云追测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = ""
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatalf("清单序列化失败：%v", err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yunzhuiclique", raw, source.code); err != nil {
		t.Fatalf("模块写入失败：%v", err)
	}
	return root
}

func TestBundledYunzhuiModuleCatalogDetailSearch(t *testing.T) {
	server := fakeYunzhuiServer(t)
	root := installYunzhuiTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("yunzhuiclique")

	entry, found := provider.Get("yunzhuiclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 3 || categories[0].ID != "331" || categories[1].Name != "国产剧" {
		t.Fatalf("分类 = %v %v", categories, err)
	}

	// 推荐频道（331）走 recommend_v2，hasMore=false。
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "331", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("推荐目录 = %v %v %v", items, hasMore, err)
	}
	// 国产剧频道（333）走 screen_v2，type_id=2/area=内地，hasMore=<20 为 false。
	items, hasMore, err = cataloguer.CatalogPage(ctx, nil, 1, "333", "")
	if err != nil || len(items) != 2 || hasMore {
		t.Fatalf("分类目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "yunzhuiclique:175520" || item.Title != "谷雨" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if fmt.Sprintf("%v", item.Episodes) != "30" {
		t.Fatalf("集数映射错误：%+v", item.Episodes)
	}
	if fmt.Sprintf("%v", item.Cover) != "http://wim.xzjykj.com/upload/175520.jpg" {
		t.Fatalf("封面拼接错误：%+v", item.Cover)
	}
	if item.Category != "国产剧" || item.Area != "内地" || item.Score != "8.1" {
		t.Fatalf("分类/地区/评分错误：%+v", item)
	}
	if len(item.Tags) != 3 || item.Tags[0] != "国产" {
		t.Fatalf("标签切分错误：%+v", item.Tags)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "175520")
	if err != nil || drama.Title != "谷雨" || drama.Desc != "云追简介" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 {
		t.Fatalf("分集数错误：%+v", chapters)
	}
	// 按 currentEpisode 排序：第1集在前；云追章节无直链但 id/pageUrl 稳定。
	if chapters[0].ID != "yunzhuiclique:175520:1" || chapters[0].Title != "第1集" {
		t.Fatalf("分集排序/ID/标题错误：%+v", chapters[0])
	}
	if chapters[0].VideoURL != "" {
		t.Fatalf("云追章节不应带直链：%+v", chapters[0])
	}
	if chapters[0].PageURL == "" {
		t.Fatal("分集缺少稳定播放页地址")
	}
	if chapters[0].Referer != "" {
		t.Fatalf("云追章节不应带 Referer：%+v", chapters[0])
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "战神")
	if err != nil || len(hits) != 1 || hits[0].ID != "yunzhuiclique:999001" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}
	if fmt.Sprintf("%v", hits[0].Episodes) != "12" {
		t.Fatalf("搜索结果集数映射错误：%+v", hits[0].Episodes)
	}
}

// 导出了 resolveMedia 的模块应装配成 MediaResolver；取流经 collection_v2。
func TestBundledYunzhuiResolveMedia(t *testing.T) {
	server := fakeYunzhuiServer(t)
	root := installYunzhuiTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("yunzhuiclique")
	entry, _ := provider.Get("yunzhuiclique")
	resolver, ok := entry.(provider.MediaResolver)
	if !ok {
		t.Fatal("模块应实现 MediaResolver")
	}

	media, err := resolver.ResolveMedia(t.Context(), nil, provider.Task{
		DramaID: "yunzhuiclique:175520",
		Chapter: provider.Chapter{
			ID:             "yunzhuiclique:175520:1",
			CurrentEpisode: json.RawMessage("1"),
		},
		Index: 0,
	})
	if err != nil {
		t.Fatalf("取流失败：%v", err)
	}
	if media.URL != server.URL+"/vod/ep.m3u8" {
		t.Fatalf("主线路错误：%+v", media)
	}
	if media.Referer != "" {
		t.Fatalf("云追媒体不能带 Referer：%+v", media)
	}
	if len(media.Variants) != 1 || media.Variants[0].URL != server.URL+"/vod/fallback.m3u8" || media.Variants[0].Referer != "" {
		t.Fatalf("备用线路错误：%+v", media.Variants)
	}
	if !strings.Contains(media.Playlist, "#EXTM3U") {
		t.Fatalf("playlist 未展开：%+v", media)
	}
}

// 云追迁移为 JS 模块后必须保留榜单能力：manifest 声明 rankings、main.js 导出 rankingPage。
// 回归点：迁移前 Go provider 实现 provider.Ranker，迁移后若模块不导出 rankingPage，
// fetchRankingPage 的模块分支拿不到数据、default 分支又因 JS provider 非 Ranker
// 报「不支持的榜单站源 yunzhui」，8 个云追榜全部消失。
func TestBundledYunzhuiRankingPage(t *testing.T) {
	server := fakeYunzhuiServer(t)
	root := installYunzhuiTestModule(t, server.URL)
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("yunzhuiclique")

	// 包装类型（jsModuleMediaProvider）解包后仍须提供榜单能力。
	ranker, ok := moduleCapabilityProvider("yunzhuiclique").(moduleRankingProvider)
	if !ok {
		t.Fatal("云追 JS 模块应提供 moduleRankingProvider 能力")
	}

	// 8 个云追榜都能取到条目（fake server 的 screen_v2 固定返回 2 条）。
	boardIDs := []string{
		"yunzhui-daily-drama", "yunzhui-daily-movie", "yunzhui-daily-variety", "yunzhui-daily-short",
		"yunzhui-total-drama", "yunzhui-total-movie", "yunzhui-total-variety", "yunzhui-total-short",
	}
	for _, boardID := range boardIDs {
		items, err := ranker.ModuleRankingPage(t.Context(), nil, boardID, 1)
		if err != nil || len(items) != 2 {
			t.Fatalf("榜单 %s = %v %v", boardID, items, err)
		}
		if items[0].Title != "谷雨" {
			t.Fatalf("榜单 %s 首条标题错误：%+v", boardID, items[0])
		}
	}
	// 未知榜单 id 必须报错，不能静默返回空。
	if _, err := ranker.ModuleRankingPage(t.Context(), nil, "yunzhui-unknown", 1); err == nil {
		t.Fatal("未知榜单 id 应报错")
	}

	// 端到端：fetchRankingPage 命中模块分支，不再落到 default 的“不支持的榜单站源”。
	page, err := d.fetchRankingPage(t.Context(), rankingBoard{
		ID: "yunzhui-daily-drama", Source: "yunzhuiclique", Name: "国产剧日榜",
	}, 1)
	if err != nil || len(page.Items) != 2 {
		t.Fatalf("fetchRankingPage = %+v %v", page, err)
	}
	if page.Items[0].Rank != 1 || page.Items[0].Drama.Title != "谷雨" {
		t.Fatalf("榜单条目错误：%+v", page.Items[0])
	}
}

// 云追模块以真实 id 安装时应接管内置 Go provider。
func TestBundledYunzhuiTakesOverBuiltinProvider(t *testing.T) {
	previous, had := provider.Get("yunzhui")
	if !had {
		t.Fatal("内置云追源应已注册")
	}
	server := fakeYunzhuiServer(t)
	modules, _ := readBundledJSModules()
	source := modules["yunzhui"]
	manifest := source.manifest
	manifest.Base = server.URL
	manifest.BaseURL = ""
	manifest.Referer = ""
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yunzhui", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()

	entry, found := provider.Get("yunzhui")
	if !found {
		t.Fatal("云追源未注册")
	}
	if _, ok := entry.(*jsModuleMediaProvider); !ok {
		t.Fatalf("云追源应由 JS 模块接管，实际类型 %T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(context.Background(), nil, 1, "333", "")
	if err != nil || len(items) != 2 || items[0].Title != "谷雨" {
		t.Fatalf("接管后的目录 = %v %v", items, err)
	}
}

// 真网冒烟：GUOAPP_YUNZHUI_LIVE=1 时跑一遍分类/目录/详情/搜索/取流。
func TestYunzhuiLiveNetworkSmoke(t *testing.T) {
	if os.Getenv("GUOAPP_YUNZHUI_LIVE") == "" {
		t.Skip("未设置 GUOAPP_YUNZHUI_LIVE，跳过真网冒烟")
	}
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["yunzhui"]
	if !found {
		t.Fatal("未找到内置云追模块")
	}
	previous, had := provider.Get("yunzhui")
	raw, err := json.Marshal(source.manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, "yunzhui", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: &http.Client{Timeout: 30 * time.Second}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()

	entry, _ := provider.Get("yunzhui")
	ctx := context.Background()
	categories, err := entry.(provider.Cataloguer).Categories(ctx, nil)
	if err != nil || len(categories) == 0 {
		t.Fatalf("真网分类 = %d %v", len(categories), err)
	}
	t.Logf("真网分类 %d 个，首个 = %s %s", len(categories), categories[0].ID, categories[0].Name)
	items, _, err := entry.(provider.Cataloguer).CatalogPage(ctx, nil, 1, categories[1].ID, "")
	if err != nil || len(items) == 0 {
		t.Fatalf("真网目录 = %d %v", len(items), err)
	}
	t.Logf("真网目录 %d 条，首条 = %s [%s]", len(items), items[0].Title, items[0].ID)
	drama, chapters, err := entry.(provider.Detailer).Detail(ctx, nil, items[0].SourceID)
	if err != nil || len(chapters) == 0 {
		t.Fatalf("真网详情 = %v %v", drama.Title, err)
	}
	t.Logf("真网详情 %s 共 %d 集，首集 = %s", drama.Title, len(chapters), chapters[0].Title)
	hits, err := entry.(provider.Searcher).Search(ctx, nil, "战神")
	if err != nil {
		t.Fatalf("真网搜索失败：%v", err)
	}
	t.Logf("真网搜索「战神」命中 %d 条", len(hits))
	if resolver, ok := entry.(provider.MediaResolver); ok {
		media, err := resolver.ResolveMedia(ctx, nil, provider.Task{
			DramaID: items[0].ID,
			Chapter: chapters[0],
			Index:   0,
		})
		if err != nil || media.URL == "" {
			t.Fatalf("真网取流失败：%+v %v", media, err)
		}
		if strings.Contains(media.URL, "m3u8") {
			t.Logf("真网取流 = %s...", media.URL[:min(80, len(media.URL))])
		}
	}
}
