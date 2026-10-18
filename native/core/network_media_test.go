package core

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func TestLegacyPlaybackAndDownloadUseAuthenticatedPlaylistAndSourceKey(t *testing.T) {
	var keys atomic.Int32
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		switch request.URL.Path {
		case "/api/app/vid/h5/m3u8/opaque-video":
			if request.URL.Query().Get("token") != "fixture-session" || request.URL.Query().Get("c") != defaultCDNURL {
				t.Error("legacy playlist lost its own session")
			}
			return sourceFixtureResponse(request, 200, "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"/api/app/vid/sec\"\n#EXTINF:4,\nsegment.ts\n#EXT-X-ENDLIST\n"), nil
		case "/api/app/vid/sec":
			keys.Add(1)
			if request.Header.Get("Origin") != legacyFrontendURL || request.Header.Get("Referer") != legacyFrontendURL+"/" {
				t.Error("legacy key lost source headers")
			}
			return sourceFixtureResponse(request, 200, "0123456789abcdef"), nil
		case "/api/app/vid/h5/m3u8/segment.ts":
			return sourceFixtureResponse(request, 200, "synthetic-segment"), nil
		default:
			t.Error("unexpected legacy resource", request.URL.Path)
			return nil, errors.New("blocked")
		}
	})
	d.cfg.APIBase = "https://legacy.example.test"
	d.cfg.Token = "fixture-session"
	d.cfg.InterfaceKey, d.cfg.ParamKey, d.cfg.ParamIV = fixtureLegacyProtocol.InterfaceKey, fixtureLegacyProtocol.ParamKey, fixtureLegacyProtocol.ParamIV
	media, err := d.resolveProviderMedia(context.Background(), Task{DramaID: "cloudfront:fixture", Chapter: Chapter{Source: sourceCloudFront, VideoURL: "opaque-video"}})
	if err != nil || media.Duration.Seconds() != 4 {
		t.Fatal("legacy resolver failed", err)
	}
	engine := &nativeEngine{downloader: d, directory: d.cfg.dataDir}
	manager := newNativeDownloads(engine)
	engine.downloads = manager
	t.Cleanup(manager.close)
	result, err := manager.transferMedia(context.Background(), nativeDownloadJob{ID: "legacy-fixture"}, media)
	if err != nil || result.file != "index.m3u8" || keys.Load() != 1 {
		t.Fatal("legacy download failed", err, keys.Load())
	}
	if _, err := os.Stat(filepath.Join(manager.root, "legacy-fixture", "index.m3u8")); err != nil {
		t.Fatal(err)
	}
}

func TestLegacyDiscoverySkipsFailedHost(t *testing.T) {
	d := sourceFixtureDownloader(t, func(request *http.Request) (*http.Response, error) {
		if request.URL.Path != "/api/app/ping/check" {
			return nil, errors.New("unexpected request")
		}
		return sourceFixtureResponse(request, 200, `{"code":200}`), nil
	})
	first, err := d.apiEndpoint(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	d.resetAPIEndpoint(first)
	next, err := d.apiEndpoint(context.Background())
	if err != nil || next == first {
		t.Fatal("failed host was immediately reselected", next, err)
	}
	var wrapped legacyTabList
	if json.Unmarshal([]byte(`{"list":[{"id":"tab","name":"分类"}]}`), &wrapped) != nil || len(wrapped) != 1 {
		t.Fatal("tab format unsupported")
	}
}
