package core

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"

	"duanjuapp/native/provider"
)

const (
	cfInterfaceKey = "65dc07d1b7915c6b2937432b091837a7"
	cfParamKey     = "BxJand%xf5h3sycH"
	cfParamIV      = "BxJand%xf5h3sycH"
	cfToken        = "cloudfront-test-guest-token"
)

func cfSHA(b []byte) []byte { h := sha256.Sum256(b); return h[:] }

// cfEncryptResponse 是 decryptResponse 的逆：固定 12 字节前缀 + 派生 key/iv + AES-CBC。
func cfEncryptResponse(t *testing.T, plain []byte) string {
	t.Helper()
	prefix := []byte("123456789012")
	r := append(append([]byte{}, []byte(cfInterfaceKey)...), prefix...)
	l := len(r) >> 1
	s := cfSHA(r)[8:24]
	c := append(append([]byte{}, s...), r[:l]...)
	a := append(append([]byte{}, r[l:]...), s...)
	d := cfSHA(c)
	f := cfSHA(a)
	key := append(append(append([]byte{}, d[:8]...), f[8:24]...), d[24:]...)
	iv := append(append(append([]byte{}, f[:4]...), d[12:20]...), f[28:]...)
	pad := aes.BlockSize - len(plain)%aes.BlockSize
	padded := append(append([]byte{}, plain...), make([]byte, pad)...)
	for i := len(plain); i < len(padded); i++ {
		padded[i] = byte(pad)
	}
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	out := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(out, padded)
	return base64.StdEncoding.EncodeToString(append(prefix, out...))
}

func cfEnvelope(t *testing.T, payload any) string {
	t.Helper()
	raw, _ := json.Marshal(payload)
	enc := cfEncryptResponse(t, raw)
	env, _ := json.Marshal(map[string]any{"code": 200, "msg": "success", "hash": true, "data": enc})
	return string(env)
}

func cfDecryptParam(t *testing.T, b64 string) map[string]any {
	t.Helper()
	data, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		t.Fatal(err)
	}
	block, err := aes.NewCipher([]byte(cfParamKey))
	if err != nil {
		t.Fatal(err)
	}
	plain := make([]byte, len(data))
	cipher.NewCBCDecrypter(block, []byte(cfParamIV)).CryptBlocks(plain, data)
	if len(plain) > 0 {
		pad := int(plain[len(plain)-1])
		if pad > 0 && pad <= 16 {
			plain = plain[:len(plain)-pad]
		}
	}
	var out map[string]any
	_ = json.Unmarshal(plain, &out)
	return out
}

// fakeCloudfrontServer 复刻黄果旧版协议：前端脚本给 key、ping、POST 登录、
// GET 分类/目录/详情（响应加密）、取流 playlist。
func fakeCloudfrontServer(t *testing.T) *httptest.Server {
	t.Helper()
	mux := http.NewServeMux()
	mainJS := fmt.Sprintf(`var ue={};ue["interfaceKey"]="%s";ue["imgKey"]="2019ysapp7527";ue["parameterKey"]="%s";ue["parameterIv"]="%s";`,
		cfInterfaceKey, cfParamKey, cfParamIV)
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.URL.Path == "/":
			w.Header().Set("Content-Type", "text/html")
			_, _ = w.Write([]byte(`<html><script src="/js/main-test.js"></script></html>`))
		case r.URL.Path == "/js/main-test.js":
			w.Header().Set("Content-Type", "application/javascript")
			_, _ = w.Write([]byte(mainJS))
		case r.URL.Path == "/api/app/ping/check":
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(`{"code":200,"msg":"success"}`))
		case r.URL.Path == "/api/app/mine/login/h5":
			w.Header().Set("Content-Type", "application/json")
			if r.Method != http.MethodPost {
				http.Error(w, "method", http.StatusMethodNotAllowed)
				return
			}
			_, _ = w.Write([]byte(cfEnvelope(t, map[string]any{"token": cfToken, "isVip": false})))
		case r.URL.Path == "/api/app/playlet-tab/all":
			w.Header().Set("Content-Type", "application/json")
			if r.Header.Get("Authorization") != cfToken {
				http.Error(w, "no token", http.StatusForbidden)
				return
			}
			_, _ = w.Write([]byte(cfEnvelope(t, []any{
				map[string]any{"id": "tab1", "name": "热播"},
				map[string]any{"id": "tab2", "name": "古装"},
			})))
		case strings.HasPrefix(r.URL.Path, "/api/app/playlet/home/tab/"):
			w.Header().Set("Content-Type", "application/json")
			params := cfDecryptParam(t, r.URL.Query().Get("data"))
			if params["pageNumber"] == nil {
				t.Errorf("目录参数缺失 pageNumber: %v", params)
			}
			_, _ = w.Write([]byte(cfEnvelope(t, map[string]any{"list": []any{
				map[string]any{"id": "cf001", "title": "测试短剧一", "cover": "https://cdn.example/cf1.jpg",
					"totalEpisode": 12, "categoryName": "热播"},
				map[string]any{"id": "cf002", "title": "战神归来", "coverUrl": "https://cdn.example/cf2.jpg",
					"episodeCount": 30},
			}})))
		case strings.HasPrefix(r.URL.Path, "/api/app/playlet/detail/"):
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(cfEnvelope(t, map[string]any{
				"id": "cf001", "title": "测试短剧一", "name": "测试短剧一", "intro": "简介",
				"cover": "https://cdn.example/cf1.jpg", "totalEpisode": 12,
				"chapters": []any{
					map[string]any{"id": "ch2", "title": "第二集", "currentEpisode": 2, "videoUrl": "vid-two"},
					map[string]any{"id": "ch1", "title": "第一集", "currentEpisode": 1, "videoUrl": "vid-one"},
				},
			})))
		case strings.HasPrefix(r.URL.Path, "/api/app/playlet-chapter/list/"):
			w.Header().Set("Content-Type", "application/json")
			_, _ = w.Write([]byte(cfEnvelope(t, map[string]any{"list": []any{}})))
		case strings.HasPrefix(r.URL.Path, "/api/app/vid/h5/m3u8/"):
			w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
			_, _ = w.Write([]byte("#EXTM3U\n#EXT-X-VERSION:3\n#EXTINF:4,\nseg.ts\n#EXT-X-ENDLIST\n"))
		default:
			http.NotFound(w, r)
		}
	})
	return httptest.NewServer(mux)
}

func installCloudfrontTestModule(t *testing.T, base string, id string) string {
	t.Helper()
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatalf("内置模块读取失败：%v", failures)
	}
	source, found := modules["cloudfront"]
	if !found || source.code == nil {
		t.Fatal("未找到内置 cloudfront 模块")
	}
	manifest := source.manifest
	manifest.ID = id
	manifest.Name = "黄果旧版测试"
	manifest.Base = base
	manifest.BaseURL = ""
	manifest.Referer = base + "/"
	manifest.RequiresAllSources = false
	raw, err := json.Marshal(manifest)
	if err != nil {
		t.Fatal(err)
	}
	root := t.TempDir()
	if err := writeJSModuleDir(root, id, raw, source.code); err != nil {
		t.Fatal(err)
	}
	return root
}

func TestBundledCloudfrontCatalogDetailSearchMedia(t *testing.T) {
	server := fakeCloudfrontServer(t)
	root := installCloudfrontTestModule(t, server.URL, "cloudfrontclique")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatalf("模块注册失败：%v", err)
	}
	defer provider.Unregister("cloudfrontclique")

	entry, found := provider.Get("cloudfrontclique")
	if !found {
		t.Fatal("模块未进入注册表")
	}
	ctx := t.Context()

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("模块应实现 Cataloguer")
	}
	cats, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(cats) != 2 || cats[0].ID != "tab1" {
		t.Fatalf("分类 = %v %v", cats, err)
	}
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 1, "tab1", "")
	if err != nil || len(items) != 2 {
		t.Fatalf("目录 = %v %v %v", items, hasMore, err)
	}
	item := items[0]
	if item.ID != "cloudfrontclique:cf001" || item.Title != "测试短剧一" {
		t.Fatalf("条目 ID/标题错误：%+v", item)
	}
	if fmt.Sprintf("%v", item.EpisodeCount) != "12" {
		t.Fatalf("集数映射错误：%+v", item.EpisodeCount)
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("模块应实现 Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "cf001")
	if err != nil || drama.Title != "测试短剧一" || drama.Intro != "简介" {
		t.Fatalf("详情 = %+v %v", drama, err)
	}
	if len(chapters) != 2 || chapters[0].ID != "cloudfrontclique:cf001:1" || chapters[0].Title != "第一集" {
		t.Fatalf("分集排序/ID 错误：%+v", chapters)
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("模块应实现 Searcher")
	}
	hits, err := searcher.Search(ctx, nil, "战神")
	if err != nil || len(hits) != 1 || hits[0].ID != "cloudfrontclique:cf002" {
		t.Fatalf("搜索 = %v %v", hits, err)
	}

	resolver, ok := entry.(provider.MediaResolver)
	if !ok {
		t.Fatal("模块应实现 MediaResolver")
	}
	media, err := resolver.ResolveMedia(ctx, nil, provider.Task{Chapter: chapters[0]})
	if err != nil || media.URL == "" {
		t.Fatalf("取流 = %+v %v", media, err)
	}
}

func TestBundledCloudfrontTakesOverBuiltin(t *testing.T) {
	previous, had := provider.Get("cloudfront")
	if !had {
		t.Fatal("内置 cloudfront 源应已注册")
	}
	server := fakeCloudfrontServer(t)
	root := installCloudfrontTestModule(t, server.URL, "cloudfront")
	d := &Downloader{client: server.Client()}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()
	entry, found := provider.Get("cloudfront")
	if !found {
		t.Fatal("cloudfront 未注册")
	}
	if _, ok := entry.(provider.MediaResolver); !ok {
		t.Fatalf("cloudfront 应由 JS 媒体模块接管：%T", entry)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), nil, 1, "tab1", "")
	if err != nil || len(items) != 2 || items[0].Title != "测试短剧一" {
		t.Fatalf("接管后目录 = %v %v", items, err)
	}
}

// 真网冒烟：GUOAPP_CLOUDFRONT_LIVE=1 时跑一遍分类/目录/详情/取流。
func TestCloudfrontLiveNetworkSmoke(t *testing.T) {
	if os.Getenv("GUOAPP_CLOUDFRONT_LIVE") == "" {
		t.Skip("未设置 GUOAPP_CLOUDFRONT_LIVE")
	}
	modules, failures := readBundledJSModules()
	if len(failures) > 0 {
		t.Fatal(failures)
	}
	source := modules["cloudfront"]
	previous, had := provider.Get("cloudfront")
	raw, _ := json.Marshal(source.manifest)
	root := t.TempDir()
	if err := writeJSModuleDir(root, "cloudfront", raw, source.code); err != nil {
		t.Fatal(err)
	}
	d := &Downloader{client: &http.Client{Timeout: 30 * 1e9}}
	if _, err := RegisterJSModules(d, root); err != nil {
		t.Fatal(err)
	}
	defer func() {
		if had {
			provider.Register(previous)
		}
	}()
	entry, _ := provider.Get("cloudfront")
	cats, err := entry.(provider.Cataloguer).Categories(t.Context(), nil)
	if err != nil || len(cats) == 0 {
		t.Fatalf("真网分类 = %d %v", len(cats), err)
	}
	items, _, err := entry.(provider.Cataloguer).CatalogPage(t.Context(), nil, 1, cats[0].ID, "")
	if err != nil || len(items) == 0 {
		t.Fatalf("真网目录 = %d %v", len(items), err)
	}
	t.Logf("真网目录 %d 条，首条 %s [%s]", len(items), items[0].Title, items[0].ID)
	drama, chapters, err := entry.(provider.Detailer).Detail(t.Context(), nil, items[0].SourceID)
	if err != nil || len(chapters) == 0 {
		t.Fatalf("真网详情 = %v %v", drama.Title, err)
	}
	t.Logf("真网详情 %s 共 %d 集", drama.Title, len(chapters))
}
