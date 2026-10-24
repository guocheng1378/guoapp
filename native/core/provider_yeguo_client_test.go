package core

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"
)

func TestYeguoAPIClientUsesRouteMethods(t *testing.T) {
	var sawCategories, sawCatalog, sawSearch, sawPlay bool
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if err := request.ParseForm(); err != nil {
			t.Errorf("parse form: %v", err)
		}
		switch request.URL.Path {
		case "/api/home/contentOptions":
			sawCategories = true
			if request.Method != http.MethodGet {
				t.Errorf("categories route used %s", request.Method)
			}
		case "/api/theater/exploreList":
			sawCatalog = true
			if request.Method != http.MethodPost {
				t.Errorf("catalog route used %s", request.Method)
			}
			if request.URL.RawQuery != "" || request.Form.Get("page") != "2" {
				t.Errorf("catalog query/form mismatch: query=%q form=%q", request.URL.RawQuery, request.PostForm.Encode())
			}
		case "/api/search/result":
			sawSearch = true
			if request.Method != http.MethodPost {
				t.Errorf("search route used %s", request.Method)
			}
			if request.URL.RawQuery != "" || request.Form.Get("keyword") != "样本" || request.Form.Get("page") != "3" {
				t.Errorf("search query/form mismatch: query=%q form=%q", request.URL.RawQuery, request.Form.Encode())
			}
		case "/api/playlet/play":
			sawPlay = true
			if request.Method != http.MethodPost {
				t.Errorf("play route used %s", request.Method)
			}
			if request.URL.RawQuery != "" || request.Form.Get("episode_id") != "456" {
				t.Errorf("play query/form mismatch: query=%q form=%q", request.URL.RawQuery, request.Form.Encode())
			}
		default:
			t.Errorf("unexpected route: %s", request.URL.Path)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(response, `{"status":"1","data":{"ok":"1"}}`)
	}))
	defer server.Close()

	client := &yeguoAPIClient{
		downloader: &Downloader{client: server.Client()},
		site:       yeguoBaseURL,
		access:     &yeguoAccess{base: server.URL, identifier: "fixture-trace", loadedAt: time.Now()},
	}
	if _, err := client.call(context.Background(), "/api/home/contentOptions", nil); err != nil {
		t.Fatal(err)
	}
	if _, err := client.call(context.Background(), "/api/theater/exploreList", url.Values{"page": {"2"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.call(context.Background(), "/api/search/result", url.Values{"keyword": {"样本"}, "page": {"3"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := client.call(context.Background(), "/api/playlet/play", url.Values{"episode_id": {"456"}}); err != nil {
		t.Fatal(err)
	}
	if !sawCategories || !sawCatalog || !sawSearch || !sawPlay {
		t.Fatalf("missing yeguo routes: categories=%t catalog=%t search=%t play=%t", sawCategories, sawCatalog, sawSearch, sawPlay)
	}
}

func TestYeguoAPIBaseFallsBackToPathinfoEntry(t *testing.T) {
	// 新版站点（Nuxt CSR）的 __NUXT_DATA__ 不再提供 apiBaseURL，回退同域 pathinfo 入口。
	base, err := yeguoAPIBase(nil, "", "https://www.yeguodj.com/")
	if err != nil || base != "https://www.yeguodj.com/api.php" {
		t.Fatalf("pathinfo fallback failed: %q %v", base, err)
	}
	if base, err := yeguoAPIBase(nil, "https://api.custom.test/", "https://www.yeguodj.com/"); err != nil || base != "https://api.custom.test" {
		t.Fatalf("configured api base lost: %q %v", base, err)
	}
	if _, err := yeguoAPIBase(nil, "", "   "); err == nil {
		t.Fatal("missing api entry must fail validation")
	}
}

// 页面不供 apiBaseURL 时从 module 脚本反查 baseURL:xxx() → xxx=()=>"…"
// （移植自 Xanerix/guoapp 3b24e89）： helper 函数优先于同名干扰项，
// 带 query/片段的地址一律拒绝。
func TestYeguoScriptAPIBaseFollowsRequestHelper(t *testing.T) {
	script := "globalThis.$fetch=Qi.create({baseURL:ta()});ta=()=>ea().baseURL,xud=()=>`https://wrong.example/api.php`," +
		"ud=()=>`https://api.example/api.php/`;function $(e,t){return u(e,{baseURL:ud(),method:a})}" +
		"var Bd=(e={},t)=>$(`/api/home/homePage`,e,t)"
	if got := yeguoScriptAPIBase(script); got != "https://api.example/api.php" {
		t.Fatalf("api base = %q", got)
	}
	if got := yeguoScriptAPIBase("ud=()=>`https://api.example/api.php?x=1`;u(e,{baseURL:ud()})"); got != "" {
		t.Fatalf("api base with query accepted: %q", got)
	}
	if got := yeguoScriptAPIBase("function f(){}"); got != "" {
		t.Fatalf("script without base call accepted: %q", got)
	}
}

func TestYeguoCallAcceptsEncryptedErrcodeEnvelope(t *testing.T) {
	key, iv := []byte("0123456789abcdef"), []byte("fedcba9876543210")
	block, err := aes.NewCipher(key)
	if err != nil {
		t.Fatal(err)
	}
	padded := pkcs7Pad([]byte(`{"data":{"ok":"1"}}`), aes.BlockSize)
	ciphertext := make([]byte, len(padded))
	cipher.NewCBCEncrypter(block, iv).CryptBlocks(ciphertext, padded)
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/theater/exploreList" {
			t.Errorf("unexpected route: %s", request.URL.Path)
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = fmt.Fprintf(response, `{"errcode":0,"timestamp":%q,"data":%q}`,
			"1760000000", base64.StdEncoding.EncodeToString(ciphertext))
	}))
	defer server.Close()

	client := &yeguoAPIClient{
		downloader: &Downloader{client: server.Client()},
		site:       yeguoBaseURL,
		access: &yeguoAccess{base: server.URL, key: key, iv: iv, signKey: []byte("fixture-sign"),
			identifier: "fixture-trace", loadedAt: time.Now()},
	}
	data, err := client.call(context.Background(), "/api/theater/exploreList", url.Values{"page": {"1"}})
	if err != nil {
		t.Fatal(err)
	}
	if mapString(data, "ok") != "1" {
		t.Fatalf("decrypted errcode envelope lost the payload: %+v", data)
	}
}

func TestResolveYeguoMediaKeepsCodecAlternatives(t *testing.T) {
	server := httptest.NewServer(http.HandlerFunc(func(response http.ResponseWriter, request *http.Request) {
		if request.URL.Path != "/api/playlet/play" {
			t.Fatalf("unexpected route: %s", request.URL.Path)
		}
		if err := request.ParseForm(); err != nil {
			t.Fatalf("parse form: %v", err)
		}
		if request.Form.Get("playlet_id") != "123" || request.Form.Get("episode_id") != "456" {
			t.Fatalf("wrong yeguo playback request: %s", request.Form.Encode())
		}
		response.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(response, `{"status":"1","data":{"playlet_id":"123","id":"456","episode_sort":"7","episode_duration":"12.5","resolution":"1920x1080","video_url":"https://media.example.test/h264.mp4","video_url_h265":"https://media.example.test/h265.mp4"}}`)
	}))
	defer server.Close()

	downloader := &Downloader{}
	client := downloader.yeguoClient()
	client.access = &yeguoAccess{base: server.URL, identifier: "fixture-trace", loadedAt: time.Now()}
	media, err := downloader.resolveYeguoMedia(context.Background(), Task{
		DramaID: providerDramaID(sourceYeguo, "123"),
		Chapter: Chapter{
			ID: providerChapterID(sourceYeguo, "123", "456"),
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if media.URL != "https://media.example.test/h264.mp4" || len(media.Variants) != 2 ||
		media.Variants[0].URL != "https://media.example.test/h264.mp4" ||
		media.Variants[1].URL != "https://media.example.test/h265.mp4" {
		t.Fatalf("yeguo alternatives were not preserved: %+v", media)
	}
	choices := nativePlaybackChoices(media, 0)
	if len(choices.media) != 2 {
		t.Fatalf("playback choices lost yeguo alternatives: %+v", choices.media)
	}
}
