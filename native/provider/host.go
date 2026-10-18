package provider

import (
	"context"
	"time"
)

type Request struct {
	Source  string
	Method  string
	Address string
	Referer string
	Agent   string
	Headers map[string]string
	Body    []byte
	Form    map[string][]string
	Timeout time.Duration
}

type Host interface {
	JSON(ctx context.Context, request Request) (map[string]any, error)
	Text(ctx context.Context, request Request) (string, error)
	Bytes(ctx context.Context, request Request) ([]byte, error)
	BaseURL(source string) string
	MediaPlaylist(ctx context.Context, address, referer string) (playlist, finalURL string, err error)
}
