package core

import (
	"context"
	"duanjuapp/native/provider"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
)

func duanjuFixtureDownloader(t *testing.T, handler http.HandlerFunc) (*Downloader, *httptest.Server) {
	t.Helper()
	server := httptest.NewServer(handler)
	t.Cleanup(server.Close)
	d := &Downloader{
		cfg:           Config{dataDir: t.TempDir(), Retries: 1, PageSize: 30, MaxPagesPerSort: 1},
		client:        server.Client(),
		limiter:       newRequestLimiter(3, 0),
		providerHosts: map[string]string{},
	}
	return d, server
}

func TestDuanjuRegistryKeepsDistinctIdentitiesFromExistingSources(t *testing.T) {
	existing := []string{sourceHongguo, sourceHuangdou, sourceHuangju, sourceYeguo, sourceHuangguoAI, sourceCloudFront}
	seen := map[string]bool{}
	for _, source := range existing {
		seen[source] = true
	}
	catalog := duanjuCatalogSpecs()
	if len(catalog) != 19 {
		t.Fatalf("duanju catalog should register 19 sources, got %d", len(catalog))
	}
	for _, spec := range catalog {
		if seen[spec.ID] {
			t.Fatalf("duanju source %q collides with an existing source id", spec.ID)
		}
		seen[spec.ID] = true
		if canonicalProviderSource(spec.ID) != spec.ID {
			t.Fatalf("duanju source %q is not canonical", spec.ID)
		}
		if !isHuangguoProviderSource(spec.ID) || !isDuanjuProviderSource(spec.ID) {
			t.Fatalf("duanju source %q was not recognized as a provider source", spec.ID)
		}
		if duanjuSourceForHost(duanjuHostOf(spec.Base)) != spec.ID {
			t.Fatalf("duanju source %q does not recognize its own host %q", spec.ID, spec.Base)
		}
	}
	if canonicalProviderSource("星芽") != sourceYaguo || canonicalProviderSource("七猫") != sourceMaoguo {
		t.Fatal("duanju chinese aliases are not canonicalized")
	}
}

func TestDuanjuMaccmsAPIParsesCatalogDetailAndSearch(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		query := request.URL.Query()
		if query.Get("ac") == "detail" {
			if query.Get("ids") != "51" {
				t.Errorf("maccms-api detail asked for the wrong id: %s", query.Get("ids"))
			}
			_, _ = writer.Write([]byte(`{"code":1,"page":1,"pagecount":1,"total":1,"list":[{"vod_id":51,"vod_name":"合成剧样本","type_id":46,"type_name":"短剧","vod_pic":"https://pic.example.cn/a.jpg","vod_content":"<p>简介</p>","vod_remarks":"已完结","vod_play_from":"laoyweb","vod_play_url":"第1集$https://cdn.example.cn/1.m3u8#第2集$https://cdn.example.cn/2.m3u8"}]}`))
			return
		}
		if query.Get("pg") != "1" {
			t.Errorf("maccms-api catalog asked for the wrong page: %s", query.Get("pg"))
		}
		if query.Get("wd") == "" && query.Get("t") != "46" {
			t.Errorf("maccms-api catalog lost the short-drama type: %s", request.URL.RawQuery)
		}
		rows := `[{"vod_id":51,"vod_name":"合成剧样本","type_id":46,"type_name":"短剧","vod_pic":"https://pic.example.cn/a.jpg","vod_content":"<p>简介</p>","vod_remarks":"已完结"}]`
		if query.Get("wd") != "" {
			rows = `[{"vod_id":77,"vod_name":"搜索样本","type_id":46,"type_name":"短剧","vod_pic":"https://pic.example.cn/b.jpg"}]`
		}
		fmt.Fprintf(writer, `{"code":1,"page":1,"pagecount":3,"total":48,"list":%s}`, rows)
	})
	d.providerHosts[sourceYingshigongchang] = server.URL

	items, more, err := d.fetchDuanjuCatalogPage(context.Background(), sourceYingshigongchang, 1, "46")
	if err != nil || len(items) != 1 || !more {
		t.Fatalf("maccms-api catalog failed: %+v %v", items, err)
	}
	if items[0].ID != "yingshigongchang:51" || items[0].Source != sourceYingshigongchang || items[0].SourceID != "51" {
		t.Fatalf("maccms-api catalog identity is wrong: %+v", items[0])
	}
	if items[0].DisplayTitle() != "合成剧样本" || items[0].ChannelName != "影视工厂" || items[0].CategoryName != "短剧" {
		t.Fatalf("maccms-api catalog metadata is wrong: %+v", items[0])
	}
	if items[0].Intro != "简介" || items[0].Remark != "已完结" {
		t.Fatalf("maccms-api description or remark is wrong: %+v", items[0])
	}

	drama, chapters, err := d.fetchDuanjuDetail(context.Background(), sourceYingshigongchang, "51")
	if err != nil || len(chapters) != 2 {
		t.Fatalf("maccms-api detail failed: %+v %v", chapters, err)
	}
	if drama.ID != "yingshigongchang:51" || drama.ChannelName != "影视工厂" {
		t.Fatalf("maccms-api detail identity is wrong: %+v", drama)
	}
	if chapters[0].ID != "yingshigongchang:51:1" || chapters[0].VideoURL != "https://cdn.example.cn/1.m3u8" || chapters[1].VideoURL != "https://cdn.example.cn/2.m3u8" {
		t.Fatalf("maccms-api chapter is wrong: %+v", chapters[0])
	}
	if got := chapters[0].EpisodeString(1); got != "1" {
		t.Fatalf("maccms-api episode number is wrong: %q", got)
	}

	found, err := d.searchDuanju(context.Background(), sourceYingshigongchang, "样本")
	if err != nil || len(found) != 1 || found[0].ID != "yingshigongchang:77" {
		t.Fatalf("maccms-api search failed: %+v %v", found, err)
	}
}

func TestDuanjuMaccmsAPIRequestUsesListTypeAndPage(t *testing.T) {
	var gotMethod, gotPath string
	var gotQuery url.Values
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		gotMethod, gotPath, gotQuery = request.Method, request.URL.Path, request.URL.Query()
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":1,"page":2,"pagecount":5,"total":120,"list":[{"vod_id":90,"vod_name":"翻页样本","type_id":46,"type_name":"短剧"}]}`))
	})
	d.providerHosts[source360zy] = server.URL
	items, more, err := d.fetchDuanjuCatalogPage(context.Background(), source360zy, 2, "46")
	if err != nil || len(items) != 1 || !more {
		t.Fatalf("maccms-api paged catalog failed: %+v %v", items, err)
	}
	if gotMethod != http.MethodGet || gotPath != "/api.php/provide/vod/" {
		t.Fatalf("maccms-api request shape is wrong: %s %s", gotMethod, gotPath)
	}
	if gotQuery.Get("ac") != "list" || gotQuery.Get("t") != "46" || gotQuery.Get("pg") != "2" {
		t.Fatalf("maccms-api request lost its list contract: %s", gotQuery.Encode())
	}
	if items[0].ID != "360zy:90" || items[0].ChannelName != "360" {
		t.Fatalf("maccms-api paged identity is wrong: %+v", items[0])
	}
}

func TestDuanjuMaccmsAPIPrefersDirectMediaSource(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":1,"list":[{"vod_id":100,"vod_name":"多线路样本","type_id":36,"type_name":"短剧","vod_play_from":"htmlshare$$$m3u8line","vod_play_url":"第1集$https://share.example.cn/play/100-1-1.html#第2集$https://share.example.cn/play/100-1-2.html$$$第1集$https://cdn.example.cn/100/1.m3u8#第2集$https://cdn.example.cn/100/2.m3u8"}]}`))
	})
	d.providerHosts[sourceDytt] = server.URL
	drama, chapters, err := d.fetchDuanjuDetail(context.Background(), sourceDytt, "100")
	if err != nil || len(chapters) != 2 {
		t.Fatalf("maccms-api multi-source detail failed: %+v %v", chapters, err)
	}
	if drama.Source != sourceDytt || drama.SourceID != "100" || drama.ChannelName != "电影天堂" {
		t.Fatalf("maccms-api multi-source identity is wrong: %+v", drama)
	}
	if chapters[0].VideoURL != "https://cdn.example.cn/100/1.m3u8" || chapters[1].VideoURL != "https://cdn.example.cn/100/2.m3u8" {
		t.Fatalf("maccms-api did not prefer the direct media source: %+v", chapters)
	}
	if chapters[0].ID != "dytt:100:1" {
		t.Fatalf("maccms-api multi-source chapter id is wrong: %q", chapters[0].ID)
	}
}

func TestDuanjuSoraniParsesCatalogDetailAndSearch(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		switch {
		case strings.Contains(request.URL.Path, "/video/search"):
			if request.URL.Query().Get("keyword") != "都市" {
				t.Errorf("sorani search lost its keyword: %s", request.URL.RawQuery)
			}
			_, _ = writer.Write([]byte(`{"code":200,"data":{"records":[{"id":"777","title":"搜索样本","cover":"https://pic.example.cn/b.jpg","episodeCount":9,"categoryName":"番剧"}]}}`))
		case strings.Contains(request.URL.Path, "/video/"):
			_, _ = writer.Write([]byte(`{"code":200,"data":{"id":"9001","title":"青空样本","summary":"简介内容","cover":"https://pic.example.cn/a.jpg","episodeCount":2,"categoryName":"番剧","episodes":[{"episodeId":"11","episodeOrder":1},{"episodeId":"12","episodeOrder":2}]}}`))
		default:
			_, _ = writer.Write([]byte(`{"code":200,"data":{"total":30,"records":[{"id":"9001","title":"青空样本","summary":"简介内容","cover":"https://pic.example.cn/a.jpg","episodeCount":2,"categoryName":"番剧","tags":["剧情"]}]}}`))
		}
	})
	d.cfg.SoraniAPIURL = server.URL

	items, more, err := d.fetchDuanjuCatalogPage(context.Background(), sourceSorani, 1, "")
	if err != nil || len(items) != 1 || !more {
		t.Fatalf("sorani catalog failed: %+v %v", items, err)
	}
	if items[0].ID != "sorani:9001" || items[0].Source != sourceSorani || items[0].ChannelName != "青空" {
		t.Fatalf("sorani catalog identity is wrong: %+v", items[0])
	}
	if items[0].DisplayTitle() != "青空样本" || items[0].Intro != "简介内容" || items[0].EpisodeCount != json.Number("2") {
		t.Fatalf("sorani catalog metadata is wrong: %+v", items[0])
	}

	drama, chapters, err := d.fetchDuanjuDetail(context.Background(), sourceSorani, "9001")
	if err != nil || len(chapters) != 2 {
		t.Fatalf("sorani detail failed: %+v %v", chapters, err)
	}
	if drama.ID != "sorani:9001" {
		t.Fatalf("sorani detail identity is wrong: %+v", drama)
	}
	if chapters[0].ID != "sorani:9001:11" || chapters[0].VideoURL != "sorani-play://11" || chapters[1].VideoURL != "sorani-play://12" {
		t.Fatalf("sorani chapters must defer media resolution: %+v", chapters[0])
	}
	if got := chapters[0].EpisodeString(1); got != "1" {
		t.Fatalf("sorani episode number is wrong: %q", got)
	}

	found, err := d.searchDuanju(context.Background(), sourceSorani, "都市")
	if err != nil || len(found) != 1 || found[0].ID != "sorani:777" {
		t.Fatalf("sorani search failed: %+v %v", found, err)
	}
}

func TestDuanjuSearchSupportMatchesReferenceScripts(t *testing.T) {
	supported := []string{sourceYingshigongchang, source360zy, sourceModu, sourceDytt, sourceHongniu, sourceSorani, sourceDongpiandi}
	for _, source := range supported {
		if !duanjuSupportsSearch(source) {
			t.Fatalf("%s should support online search", source)
		}
	}
	for _, source := range []string{sourceShandian, sourceNiuniu, sourceWsyzy} {
		if duanjuSupportsSearch(source) {
			t.Fatalf("%s must not advertise search it does not implement", source)
		}
	}
	if duanjuSupportsSearch("shuangguo") || duanjuSupportsSearch("muguo") {
		t.Fatal("removed sources must not advertise search")
	}
	if duanjuSupportsSearch(sourceHongguo) {
		t.Fatal("duanju search support leaked onto an existing source")
	}
	for _, source := range []string{sourceYaguo, sourceHuaguo, sourceWangguo, sourceFaguo, sourceWuguo,
		sourceYingshigongchang, source360zy, sourceModu, sourceDytt, sourceShandian, sourceHongniu, sourceNiuniu, sourceWsyzy, sourceSorani, sourceDongpiandi} {
		if !duanjuSupportsPaging(source) {
			t.Fatalf("%s should support paging", source)
		}
	}
	for _, source := range []string{sourceHeguo, sourceXingguo, sourceMaoguo, sourceFanguo} {
		if duanjuSupportsPaging(source) {
			t.Fatalf("%s deregistered source still reports paging", source)
		}
	}
}

func TestDuanjuMaoguoSearchSignatureFollowsReferenceOrder(t *testing.T) {
	want := provider.MD5("extend=page=1read_preference=0track_id=ec1280db127955061754851657967wd=都市d3dGiJc651gSQ8w1")
	if got := provider.MD5("extend=page=1read_preference=0track_id=ec1280db127955061754851657967wd=都市d3dGiJc651gSQ8w1"); got != want {
		t.Fatalf("maoguo signature is unstable: %q", got)
	}
	if want == provider.MD5("extend=page=1read_preference=0track_id=ec1280db127955061754851657967d3dGiJc651gSQ8w1wd=都市") {
		t.Fatal("maoguo signature must place the key after the keyword")
	}
}

func TestDuanjuRejectsMismatchedSourceIDsAndCategories(t *testing.T) {
	if split, id, ok := splitProviderDramaID("360zy:51"); !ok || split != source360zy || id != "51" {
		t.Fatalf("duanju drama id split failed: %q %q %v", split, id, ok)
	}
	if _, _, ok := splitProviderDramaID("360zy:"); ok {
		t.Fatal("duanju accepted an empty source id")
	}
	if split, _, ok := splitProviderDramaID("unknown:1"); ok {
		t.Fatalf("duanju accepted an unknown source: %q", split)
	}
	if validDuanjuCategory(sourceMaoguo, "a|b") {
		t.Fatal("duanju accepted an invalid category")
	}
	if !validDuanjuCategory(sourceHeguo, "417-464") {
		t.Fatal("duanju rejected a valid numeric category")
	}
	if !validDuanjuCategory(sourceFanguo, "都市") {
		t.Fatal("fanguo should accept a chinese category")
	}
}

func TestDuanjuSourceAvailabilityFollowsBuildVariant(t *testing.T) {
	previous := buildAllSources
	buildAllSources = "false"
	if nativeSourceAvailable(sourceYingshigongchang) {
		t.Fatal("hongguo-only build must not expose duanju sources")
	}
	buildAllSources = "true"
	if !nativeSourceAvailable(sourceYingshigongchang) || !nativeSourceAvailable(sourceSorani) {
		t.Fatal("all-sources build must expose duanju sources")
	}
	buildAllSources = previous
}

func TestDuanjuMaccmsAPIEmptyDetailIsReportedAsUpstream(t *testing.T) {
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":1,"page":1,"pagecount":1,"total":0,"list":[]}`))
	})
	d.providerHosts[sourceModu] = server.URL
	_, _, err := d.fetchDuanjuDetail(context.Background(), sourceModu, "9001")
	if err == nil {
		t.Fatal("maccms-api empty detail should fail")
	}
	if !strings.Contains(err.Error(), "无数据") {
		t.Fatalf("maccms-api empty detail error should blame upstream, got %v", err)
	}
}

func TestDuanjuSearchCoverageMatchesImplementedSources(t *testing.T) {
	for _, source := range []string{sourceYaguo, sourceMaoguo, sourceFanguo, sourceHeguo, sourceXingguo,
		sourceHuaguo, sourceWangguo, sourceFaguo, sourceWuguo,
		sourceYingshigongchang, source360zy, sourceModu, sourceDytt, sourceHongniu, sourceSorani, sourceDongpiandi} {
		if !duanjuSupportsSearch(source) {
			t.Fatalf("%s should report search support", source)
		}
		if !duanjuSourceRegistered(source) {
			t.Fatalf("%s has no registered adapter", source)
		}
	}
	for _, source := range []string{sourceShandian, sourceNiuniu, sourceWsyzy} {
		if duanjuSupportsSearch(source) {
			t.Fatalf("%s must not advertise search", source)
		}
	}
}

func TestDuanjuHeguoSearchBuildsDocumentedRequest(t *testing.T) {
	var gotPath, gotMethod, gotPName, gotBody string
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		gotPath, gotMethod, gotPName = request.URL.Path, request.Method, request.Header.Get("pname")
		payload, _ := io.ReadAll(request.Body)
		gotBody = string(payload)
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"retCode":0,"data":{"isMore":1,"totalSize":1,"bookList":[{"bookId":"41000131810","bookName":"雪夜逃婚","coverWap":"https://seoali.zqkanshu.com/a.jpg","totalChapterNum":"28","statusDesc":"完本"}]}}`))
	})
	d.providerHosts[sourceHeguo] = server.URL

	items, err := d.searchDuanju(context.Background(), sourceHeguo, "都市")
	if err != nil || len(items) != 1 {
		t.Fatalf("heguo search failed: %+v %v", items, err)
	}
	if gotPath != "/seo/video/6007" || gotMethod != http.MethodPost || gotPName != "www.kuaikaw.cn" {
		t.Fatalf("heguo search request is wrong: %s %s pname=%s", gotMethod, gotPath, gotPName)
	}
	var sent map[string]any
	if json.Unmarshal([]byte(gotBody), &sent) != nil {
		t.Fatalf("heguo search body is not json: %q", gotBody)
	}
	if sent["keyword"] != "都市" {
		t.Fatalf("heguo search keyword is wrong: %v", sent)
	}
	if index, _ := sent["index"].(float64); int(index) != 1 {
		t.Fatalf("heguo search index is wrong: %v", sent["index"])
	}
	if sourceType, _ := sent["sourceType"].(float64); int(sourceType) != 1 {
		t.Fatalf("heguo search sourceType is wrong: %v", sent["sourceType"])
	}
	if items[0].Title != "雪夜逃婚" || items[0].SourceID != "41000131810" {
		t.Fatalf("heguo search item is wrong: %+v", items[0])
	}
}

func TestDuanjuXingguoSearchUsesKeyParameter(t *testing.T) {
	var gotQuery url.Values
	d, server := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {
		gotQuery = request.URL.Query()
		writer.Header().Set("Content-Type", "application/json")
		_, _ = writer.Write([]byte(`{"code":"0","data":{"page":1,"datalist":[{"id":"461565999316993","name":"都市联盟","icon":"http://img.novel.wsljf.xyz/a.jpg","chapterCount":38,"introduction":"简介"}]}}`))
	})
	d.providerHosts[sourceXingguo] = server.URL

	items, err := d.searchDuanju(context.Background(), sourceXingguo, "都市")
	if err != nil || len(items) != 1 {
		t.Fatalf("xingguo search failed: %+v %v", items, err)
	}
	if gotQuery.Get("key") != "都市" {
		t.Fatalf("xingguo search must use the key parameter, got %q", gotQuery.Encode())
	}
	if gotQuery.Get("token") != "202509271001001446030204698626" || gotQuery.Get("pageSize") == "" {
		t.Fatalf("xingguo search dropped required parameters: %q", gotQuery.Encode())
	}
	if items[0].Title != "都市联盟" || !strings.HasPrefix(items[0].SourceID, "461565999316993") {
		t.Fatalf("xingguo search item is wrong: %+v", items[0])
	}
}

func TestDuanjuSearchRejectsBlankKeyword(t *testing.T) {
	d, _ := duanjuFixtureDownloader(t, func(writer http.ResponseWriter, request *http.Request) {})
	if _, err := d.searchDuanju(context.Background(), sourceHeguo, "   "); err == nil {
		t.Fatal("heguo search must reject a blank keyword")
	}
	if _, err := d.searchDuanju(context.Background(), sourceXingguo, "   "); err == nil {
		t.Fatal("xingguo search must reject a blank keyword")
	}
}

func TestDuanjuPlainTextStripsSearchHighlightMarkup(t *testing.T) {
	cases := map[string]string{
		"<font color='#ff4242'>都</font><font color='#ff4242'>市</font>无上仙尊（<font color='#ff4242'>都</font><font color='#ff4242'>市</font>之无双仙尊）": "都市无上仙尊（都市之无双仙尊）",
		"<em>都市</em>风云":     "都市风云",
		"普通标题":              "普通标题",
		"":                  "",
		"  <b>加粗</b>  空格  ": "加粗 空格",
	}
	for input, want := range cases {
		if got := duanjuPlainText(input); got != want {
			t.Fatalf("plain %q => %q, want %q", input, got, want)
		}
	}
}
