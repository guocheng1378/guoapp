package core

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"
)

func hongguoRouterPage(t *testing.T, page map[string]any) string {
	t.Helper()
	body, err := json.Marshal(map[string]any{"loaderData": page})
	if err != nil {
		t.Fatal(err)
	}
	return "<html><script>window._ROUTER_DATA = " + string(body) + "</script></html>"
}

func hongguoWebChaptersFixture(t *testing.T, transport sourceFixtureTransport) *Downloader {
	t.Helper()
	return sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/detail" {
			t.Fatalf("unexpected request path: %s", request.URL.Path)
		}
		return transport(request)
	})
}

func hongguoWebDetailPage(series map[string]any) map[string]any {
	return map[string]any{"detail_page": map[string]any{"seriesDetail": series}}
}

func TestHongguoWebChaptersRequiresCompleteEpisodes(t *testing.T) {
	complete := hongguoWebDetailPage(map[string]any{
		"series_name": "合成测试", "episode_cnt": 3,
		"vid_list": []any{"800001", "800002", "800003"},
	})
	d := hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, complete)), nil
	})
	title, chapters, err := d.fetchHongguoWebChapters(context.Background(), "700001")
	if err != nil || len(chapters) != 3 || title != "合成测试" {
		t.Fatalf("complete web details rejected: %q %v", title, err)
	}
	if chapters[0].VideoURL != "hongguo-cenc://800001" || chapters[2].CurrentEpisode == nil {
		t.Fatalf("wrong chapter mapping: %+v", chapters)
	}

	truncated := hongguoWebDetailPage(map[string]any{
		"series_name": "合成测试", "episode_cnt": 5,
		"vid_list": []any{"800001", "800002", "800003"},
	})
	d = hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, truncated)), nil
	})
	if _, _, err := d.fetchHongguoWebChapters(context.Background(), "700001"); err == nil {
		t.Fatal("truncated web details accepted")
	}

	gapped := hongguoWebDetailPage(map[string]any{
		"series_name": "合成测试", "episode_cnt": 3,
		"vid_list": []any{"800001", "", "800003", "800004"},
	})
	d = hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, gapped)), nil
	})
	if _, _, err := d.fetchHongguoWebChapters(context.Background(), "700001"); err == nil {
		t.Fatal("gapped web details accepted")
	}

	invalid := hongguoWebDetailPage(map[string]any{
		"series_name": "合成测试", "episode_cnt": 2,
		"vid_list": []any{"800001", "not-a-vid"},
	})
	d = hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, invalid)), nil
	})
	if _, _, err := d.fetchHongguoWebChapters(context.Background(), "700001"); err == nil {
		t.Fatal("invalid video id accepted")
	}
}

func TestHongguoWebMediaUsesPublicSEOAddress(t *testing.T) {
	page := map[string]any{"player_(series_id)/(vid)/page": map[string]any{
		"protectedPlayback": true,
		"publicVideoSeo": map[string]any{
			"available": true, "seriesId": "700001", "itemId": "800001",
			"posterUrl": "https://poster.example.test/x.jpg", "durationSeconds": 91.5,
		},
	}}
	probes := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/player/700001/800001":
			return sourceFixtureResponse(request, 200, hongguoRouterPage(t, page)), nil
		case "/video/public/800001/360p.mp4":
			probes++
			response := sourceFixtureResponse(request, 206, "x")
			response.Header.Set("Content-Range", "bytes 0-0/1024")
			return response, nil
		default:
			t.Fatalf("unexpected request path: %s", request.URL.Path)
			return nil, nil
		}
	})
	media, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001")
	if err != nil {
		t.Fatalf("public seo media rejected: %v", err)
	}
	want := "https://hongguoduanju.com/video/public/800001/360p.mp4"
	if media.URL != want || media.Quality != 360 || media.Duration.Seconds() != 91.5 {
		t.Fatalf("wrong public seo media: %+v", media)
	}
	if len(media.Variants) != 1 || media.Variants[0].URL != want {
		t.Fatalf("missing variant: %+v", media.Variants)
	}
	if probes != 1 {
		t.Fatalf("expected one warm-up probe, got %d", probes)
	}

	mismatched := map[string]any{"player_(series_id)/(vid)/page": map[string]any{
		"publicVideoSeo": map[string]any{"available": true, "seriesId": "700002", "itemId": "800001"},
	}}
	d = sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/player/700001/800001" {
			t.Fatalf("unexpected request path: %s", request.URL.Path)
		}
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, mismatched)), nil
	})
	if _, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001"); err == nil {
		t.Fatal("mismatched series accepted")
	}

	locked := map[string]any{"player_(series_id)/(vid)/page": map[string]any{
		"publicVideoSeo": map[string]any{"available": false, "seriesId": "700001", "itemId": "800001"},
	}}
	d = sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/player/700001/800001" {
			t.Fatalf("unexpected request path: %s", request.URL.Path)
		}
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, locked)), nil
	})
	if _, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001"); err == nil {
		t.Fatal("unavailable episode accepted")
	}
}

func TestHongguoWebMediaWarmsColdPublicAddress(t *testing.T) {
	page := map[string]any{"player_(series_id)/(vid)/page": map[string]any{
		"publicVideoSeo": map[string]any{"available": true, "seriesId": "700001", "itemId": "800001", "durationSeconds": 91.5},
	}}
	probes := 0
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/player/700001/800001":
			return sourceFixtureResponse(request, 200, hongguoRouterPage(t, page)), nil
		case "/video/public/800001/360p.mp4":
			probes++
			if probes < hongguoRouterPageAttempts {
				return sourceFixtureResponse(request, 404, "not found"), nil
			}
			response := sourceFixtureResponse(request, 206, "x")
			response.Header.Set("Content-Range", "bytes 0-0/1024")
			return response, nil
		default:
			t.Fatalf("unexpected request path: %s", request.URL.Path)
			return nil, nil
		}
	})
	media, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001")
	if err != nil || media.URL != "https://hongguoduanju.com/video/public/800001/360p.mp4" {
		t.Fatalf("cold public media not warmed: %+v %v", media, err)
	}
	if probes != hongguoRouterPageAttempts {
		t.Fatalf("expected %d probes, got %d", hongguoRouterPageAttempts, probes)
	}

	probes = 0
	d = sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/player/700001/800001":
			return sourceFixtureResponse(request, 200, hongguoRouterPage(t, page)), nil
		default:
			probes++
			return sourceFixtureResponse(request, 404, "not found"), nil
		}
	})
	if _, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001"); err == nil {
		t.Fatal("persistent 404 media accepted")
	}
	if probes != hongguoMediaWarmAttempts {
		t.Fatalf("expected %d probes, got %d", hongguoMediaWarmAttempts, probes)
	}
}

func TestHongguoWebMediaKeepsLegacyPlayerInfo(t *testing.T) {
	page := map[string]any{"player_page": map[string]any{
		"vid": "800001", "series_id": "700001",
		"video_player_info": map[string]any{"main_url": "https://media.example.test/legacy.mp4", "duration": "60"},
	}}
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, page)), nil
	})
	media, err := d.resolveHongguoWebMedia(context.Background(), "700001", "800001")
	if err != nil || media.URL != "https://media.example.test/legacy.mp4" || media.Duration.Seconds() != 60 {
		t.Fatalf("legacy player info broken: %+v %v", media, err)
	}
}

func TestHongguoRouterPageRetriesRandomNotFound(t *testing.T) {
	attempts := 0
	page := hongguoWebDetailPage(map[string]any{
		"series_name": "合成测试", "episode_cnt": 1,
		"vid_list": []any{"800001"},
	})
	d := hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		attempts++
		if attempts == 1 {
			return sourceFixtureResponse(request, http.StatusNotFound, "not found"), nil
		}
		return sourceFixtureResponse(request, 200, hongguoRouterPage(t, page)), nil
	})
	title, chapters, err := d.fetchHongguoWebChapters(context.Background(), "700001")
	if err != nil || len(chapters) != 1 || title != "合成测试" {
		t.Fatalf("random 404 not retried: %q %v", title, err)
	}
	if attempts != 2 {
		t.Fatalf("expected 2 attempts, got %d", attempts)
	}

	failures := 0
	d = hongguoWebChaptersFixture(t, func(request *http.Request) (*http.Response, error) {
		failures++
		return sourceFixtureResponse(request, http.StatusNotFound, "not found"), nil
	})
	if _, _, err := d.fetchHongguoWebChapters(context.Background(), "700001"); err == nil {
		t.Fatal("persistent 404 accepted")
	}
	if failures != hongguoRouterPageAttempts {
		t.Fatalf("expected %d attempts, got %d", hongguoRouterPageAttempts, failures)
	}
}

func TestHongguoWebMediaUserAgent(t *testing.T) {
	if agent := hongguoWebMediaUserAgent("https://hongguoduanju.com/video/public/800001/360p.mp4"); agent != hongguoWebUserAgent {
		t.Fatalf("hongguo media got wrong agent: %q", agent)
	}
	if agent := hongguoWebMediaUserAgent("https://www.hongguoduanju.com/video/public/800001/360p.mp4"); agent != hongguoWebUserAgent {
		t.Fatalf("www hongguo media got wrong agent: %q", agent)
	}
	if agent := hongguoWebMediaUserAgent("https://p3-novel.byteimg.com/example.mp4"); agent != userAgent {
		t.Fatalf("other hosts must keep the default agent: %q", agent)
	}
	if agent := hongguoWebMediaUserAgent("not a url"); agent != userAgent {
		t.Fatalf("invalid address must keep the default agent: %q", agent)
	}
}

func TestHongguoPublicVideoPath(t *testing.T) {
	if path := hongguoPublicVideoPath("800001"); path != "/video/public/800001/360p.mp4" {
		t.Fatalf("wrong public path: %q", path)
	}
	if path := hongguoPublicVideoPath("bad id"); path != "" {
		t.Fatalf("invalid id produced a path: %q", path)
	}
	if !hongguoSEOAvailable(map[string]any{"available": true}) {
		t.Fatal("boolean true rejected")
	}
	if hongguoSEOAvailable(map[string]any{"available": false}) {
		t.Fatal("boolean false accepted")
	}
	if !hongguoSEOAvailable(map[string]any{"available": "true"}) {
		t.Fatal("string true rejected")
	}
	if hongguoSEOAvailable(map[string]any{}) {
		t.Fatal("missing flag accepted")
	}
}

func TestHongguoPlaybackAPIDirectURLFallback(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, `{"parse":0,"url":"https://media.example.test/direct.mp4"}`), nil
	})
	media, err := d.resolveHongguoPlaybackAPI(context.Background(), "700001", "800001")
	if err != nil || media.URL != "https://media.example.test/direct.mp4" {
		t.Fatalf("direct url fallback failed: %+v %v", media, err)
	}
	if len(media.Variants) != 1 || media.Variants[0].URL != media.URL {
		t.Fatalf("missing direct variant: %+v", media.Variants)
	}

	d = sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		return sourceFixtureResponse(request, 200, `{"parse":0,"url":"javascript:alert(1)"}`), nil
	})
	if _, err := d.resolveHongguoPlaybackAPI(context.Background(), "700001", "800001"); err == nil {
		t.Fatal("unsafe direct url accepted")
	}
}

func TestHongguoDetailCacheEvictsOldestEntries(t *testing.T) {
	details := map[string]hongguoDetailEntry{}
	now := time.Now()
	for index := 0; index < hongguoDetailCacheLimit; index++ {
		details[fmt.Sprintf("%019d", index)] = hongguoDetailEntry{ExpiresAt: now.Add(time.Duration(index) * time.Second)}
	}
	hongguoEvictOldestDetails(details)
	if len(details) != hongguoDetailCacheLimit-1 {
		t.Fatalf("cache size after eviction: %d", len(details))
	}
	if _, found := details[fmt.Sprintf("%019d", 0)]; found {
		t.Fatal("oldest entry survived eviction")
	}
	if _, found := details[fmt.Sprintf("%019d", hongguoDetailCacheLimit-1)]; !found {
		t.Fatal("newest entry was evicted")
	}
}
