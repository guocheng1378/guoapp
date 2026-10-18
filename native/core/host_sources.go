package core

import (
	"context"
	"net/url"

	"duanjuapp/native/provider"
)

type downloaderHost struct {
	downloader *Downloader
}

func (d *Downloader) host() provider.Host {
	return downloaderHost{downloader: d}
}

func (h downloaderHost) request(request provider.Request) duanjuRequest {
	form := url.Values{}
	for key, values := range request.Form {
		for _, value := range values {
			form.Add(key, value)
		}
	}
	return duanjuRequest{
		Source:  request.Source,
		Method:  request.Method,
		Address: request.Address,
		Referer: request.Referer,
		Agent:   request.Agent,
		Headers: request.Headers,
		Body:    request.Body,
		Form:    form,
		Timeout: request.Timeout,
	}
}

func (h downloaderHost) JSON(ctx context.Context, request provider.Request) (map[string]any, error) {
	return h.downloader.duanjuJSON(ctx, h.request(request))
}

func (h downloaderHost) Text(ctx context.Context, request provider.Request) (string, error) {
	referer := request.Referer
	if referer == "" {
		referer = request.Address
	}
	return h.downloader.fetchProviderText(ctx, request.Address, referer)
}

func (h downloaderHost) Bytes(ctx context.Context, request provider.Request) ([]byte, error) {
	return h.downloader.duanjuDo(ctx, h.request(request))
}

func (h downloaderHost) BaseURL(source string) string {
	return h.downloader.duanjuBaseURL(source)
}

func (h downloaderHost) MediaPlaylist(ctx context.Context, address, referer string) (string, string, error) {
	return h.downloader.fetchMediaPlaylist(ctx, address, referer)
}
