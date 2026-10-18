package core

import (
	"bytes"
	"context"
	"duanjuapp/native/provider"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"
)

func duanjuCachedToken(source string, ttl time.Duration, fetch func(context.Context) (string, error)) (string, error) {
	return provider.CachedToken(source, ttl, fetch)
}

func sortDuanjuChapters(chapters []Chapter) {
	provider.SortChapters(chapters)
}

func duanjuFindBool(node map[string]any, keys ...string) bool {
	return provider.FindBool(node, keys...)
}

type duanjuRequest struct {
	Source  string
	Method  string
	Address string
	Referer string
	Agent   string
	Headers map[string]string
	Body    []byte
	Form    url.Values
	Timeout time.Duration
}

func (d *Downloader) duanjuDo(ctx context.Context, request duanjuRequest) ([]byte, error) {
	if err := ctx.Err(); err != nil {
		return nil, err
	}
	method := strings.ToUpper(strings.TrimSpace(request.Method))
	if method == "" {
		method = http.MethodGet
	}
	address := strings.TrimSpace(request.Address)
	if address == "" {
		return nil, errors.New("站源地址为空")
	}
	body := request.Body
	if len(request.Form) > 0 && len(body) == 0 {
		body = []byte(request.Form.Encode())
	}
	var reader io.Reader
	if len(body) > 0 {
		reader = bytes.NewReader(body)
	}
	httpRequest, err := http.NewRequestWithContext(ctx, method, address, reader)
	if err != nil {
		return nil, err
	}
	agent := firstNonEmpty(request.Agent, duanjuUserAgent)
	httpRequest.Header.Set("User-Agent", agent)
	httpRequest.Header.Set("Accept-Language", "zh-CN,zh;q=0.9")
	httpRequest.Header.Set("Accept", "*/*")
	if referer := strings.TrimSpace(request.Referer); referer != "" {
		httpRequest.Header.Set("Referer", referer)
	}
	if len(request.Form) > 0 && len(request.Body) == 0 {
		httpRequest.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	for key, value := range request.Headers {
		if strings.EqualFold(key, "Host") || strings.EqualFold(key, "Content-Length") {
			continue
		}
		httpRequest.Header.Set(key, value)
	}
	timeout := request.Timeout
	if timeout <= 0 {
		timeout = providerTimeout
	}
	response, err := d.doCatalogRequestWithTimeout(httpRequest, timeout)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, duanjuMaxBodyBytes+1))
	if err != nil {
		return nil, err
	}
	if len(payload) > duanjuMaxBodyBytes {
		return nil, errors.New("站源返回内容过大")
	}
	if response.StatusCode < 200 || response.StatusCode >= 300 {
		return nil, &requestBackoff{status: response.StatusCode, host: duanjuHostOf(address), until: time.Now().Add(time.Minute)}
	}
	return payload, nil
}

func duanjuHostOf(address string) string {
	parsed, err := url.Parse(address)
	if err != nil {
		return ""
	}
	return parsed.Hostname()
}

func (d *Downloader) duanjuJSON(ctx context.Context, request duanjuRequest) (map[string]any, error) {
	payload, err := d.duanjuDo(ctx, request)
	if err != nil {
		return nil, err
	}
	var decoded map[string]any
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, errors.New("站源返回的数据格式无法识别")
	}
	return decoded, nil
}

func duanjuFindString(node map[string]any, keys ...string) string {
	return provider.FindString(node, keys...)
}

func duanjuFindInt(node map[string]any, keys ...string) int {
	return provider.FindInt(node, keys...)
}

func parseDuanjuNumber(value string) (int, error) {
	return provider.ParseNumber(value)
}

func duanjuFindMap(node map[string]any, keys ...string) map[string]any {
	return provider.FindMap(node, keys...)
}

func duanjuFindList(node map[string]any, keys ...string) []any {
	return provider.FindList(node, keys...)
}

func duanjuMapList(value any) []map[string]any {
	return provider.MapList(value)
}

func duanjuStringList(value any) []string {
	return provider.StringList(value)
}

func duanjuCSV(values []string) string {
	return provider.CSV(values)
}

func duanjuCover(base string, node map[string]any, keys ...string) string {
	return provider.Cover(base, node, keys...)
}

func duanjuReleaseStatus(raw string, total, current int) string {
	return provider.ReleaseStatus(raw, total, current)
}

func duanjuEpisodeNumber(raw string, fallback int) int {
	raw = strings.TrimSpace(raw)
	if number := episodeIndex(raw, 0); number > 0 {
		return number
	}
	if number, err := strconv.Atoi(raw); err == nil && number > 0 {
		return number
	}
	if fallback > 0 {
		return fallback
	}
	return 1
}

func duanjuChapter(source, sourceID string, number int, title, videoURL, pageURL, referer string) Chapter {
	if number <= 0 {
		number = 1
	}
	if strings.TrimSpace(title) == "" {
		title = "第" + strconv.Itoa(number) + "集"
	}
	return Chapter{
		ID:             providerChapterID(source, sourceID, strconv.Itoa(number)),
		Source:         source,
		Title:          truncate(title, 256),
		CurrentEpisode: rawEpisode(number),
		VideoURL:       strings.TrimSpace(videoURL),
		PageURL:        strings.TrimSpace(pageURL),
		Referer:        strings.TrimSpace(referer),
	}
}

func duanjuChapterKey(number int) string { return strconv.Itoa(number) }
