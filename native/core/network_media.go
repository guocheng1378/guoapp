package core

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strings"
)

func mediaRequestHeaders(request *http.Request, referer string) {
	request.Header.Set("User-Agent", hongguoWebMediaUserAgent(request.URL.String()))
	request.Header.Set("Referer", referer)
	request.Header.Set("Accept", "*/*")
	request.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	request.Header.Set("Sec-Fetch-Mode", "cors")
	request.Header.Set("Sec-Fetch-Dest", "empty")
	if origin, err := url.Parse(referer); err == nil && origin.Host != "" {
		request.Header.Set("Origin", origin.Scheme+"://"+origin.Host)
	}
}

func (d *Downloader) doMediaRequest(request *http.Request) (*http.Response, error) {
	return d.doMediaRequestWithClient(request, d.client)
}

func (d *Downloader) doMediaRequestWithClient(request *http.Request, client *http.Client) (*http.Response, error) {
	mediaRequestHeaders(request, request.Header.Get("Referer"))
	if credentials, _ := request.Context().Value(providerMediaCredentialsKey{}).(*providerMediaCredentials); credentials != nil {
		if err := credentials.apply(request); err != nil {
			return nil, err
		}
		client = credentials.client(client)
	}
	response, err := d.mediaRequestRefererless(client, request)
	if err != nil {
		return nil, err
	}
	if d.limiter != nil {
		d.limiter.observe(request, response)
	}
	observeSourceResponse(request.Context(), response)
	return response, nil
}

// mediaRequestRefererless retries once without the Referer header when the
// server answers 403 because of a hotlink guard. A successful retry marks
// the host as refusing Referer, later requests to it go out bare.
//
// Background: hotlink policies differ per CDN. Under one host the API
// domain, the media domain and the main site domain can each accept or
// reject the same Referer (yunzhui rejects every non-empty one). A
// hardcoded Referer breaks as soon as a site tightens its policy, so the
// fallback is measured at runtime and every source recovers on its own.
func (d *Downloader) mediaRequestRefererless(client *http.Client, request *http.Request) (*http.Response, error) {
	host := ""
	if request.URL != nil {
		host = strings.ToLower(request.URL.Hostname())
	}
	referer := request.Header.Get("Referer")
	if host != "" && referer != "" && d.mediaHostRefererless(host) {
		// The host was measured as refusing the Referer header: send it bare
		// right away instead of paying a rejected request first.
		stripped := request.Clone(request.Context())
		stripped.Header.Del("Referer")
		stripped.Header.Del("Origin")
		return client.Do(stripped)
	}
	response, err := client.Do(request)
	if err != nil {
		return nil, err
	}
	if response.StatusCode != http.StatusForbidden || referer == "" || host == "" {
		return response, nil
	}
	// Only a hotlink page counts as a Referer problem: a bare 403 without an
	// HTML body is an expired address or a permission error, and those must
	// keep going through the renewal path instead of spending one more
	// request on every hit.
	if !strings.Contains(strings.ToLower(response.Header.Get("Content-Type")), "text/html") {
		return response, nil
	}
	retry := request.Clone(request.Context())
	retry.Header.Del("Referer")
	retry.Header.Del("Origin")
	second, err := client.Do(retry)
	if err != nil {
		return response, nil
	}
	if second.StatusCode == http.StatusForbidden {
		second.Body.Close()
		return response, nil
	}
	response.Body.Close()
	d.markMediaHostRefererless(host)
	return second, nil
}

// mediaHostRefererless reports whether the host was measured as refusing
// the Referer header.
func (d *Downloader) mediaHostRefererless(host string) bool {
	d.refererlessMu.Lock()
	defer d.refererlessMu.Unlock()
	return d.refererlessHosts[host]
}

// markMediaHostRefererless remembers that the host refuses Referer, so the
// following requests to it go out without the header.
func (d *Downloader) markMediaHostRefererless(host string) {
	d.refererlessMu.Lock()
	defer d.refererlessMu.Unlock()
	if d.refererlessHosts == nil {
		d.refererlessHosts = map[string]bool{}
	}
	d.refererlessHosts[host] = true
}

func (d *Downloader) fetchMediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	if !isProviderHTTPMediaURL(address) {
		return "", "", errors.New("播放列表地址无效")
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return "", "", err
	}
	request.Header.Set("Referer", referer)
	response, err := d.doMediaRequest(request)
	if err != nil {
		return "", "", err
	}
	defer response.Body.Close()
	body, err := io.ReadAll(io.LimitReader(response.Body, (4<<20)+1))
	if err != nil || len(body) > 4<<20 {
		return "", "", errors.New("播放列表过大或读取失败")
	}
	if response.StatusCode != http.StatusOK || catalogResponseBlockReason(response, body) != "" {
		return "", "", d.catalogResponseError(request, response, body)
	}
	text := strings.TrimSpace(strings.TrimPrefix(string(body), "\ufeff"))
	if !strings.HasPrefix(text, "#EXTM3U") {
		var envelope apiEnvelope
		if json.Unmarshal(body, &envelope) == nil && strings.Trim(string(envelope.Code), `"`) == "5005" {
			return "", "", &legacyAPIError{code: "5005", message: "播放会话已失效"}
		}
		return "", "", errors.New("站源未返回有效的播放列表，链接可能已失效")
	}
	finalURL := address
	if response.Request != nil && response.Request.URL != nil {
		finalURL = response.Request.URL.String()
	}
	return text, finalURL, nil
}
