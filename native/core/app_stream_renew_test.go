package core

import (
	"context"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"testing"
	"time"
)

func newRenewTestStream(t *testing.T) (*nativeStreamServer, *nativeEngine) {
	t.Helper()
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { stream.server.Close() })
	return stream, engine
}

func readRenewBody(t *testing.T, address string) (int, string) {
	t.Helper()
	response, err := http.Get(address)
	if err != nil {
		t.Fatal(err)
	}
	defer response.Body.Close()
	body, _ := io.ReadAll(io.LimitReader(response.Body, 1<<20))
	return response.StatusCode, string(body)
}

func TestNativeStreamRenewsExpiredMediaAddress(t *testing.T) {
	var mu sync.Mutex
	staleHits, freshHits, renewals := 0, 0, 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		defer mu.Unlock()
		switch r.URL.Path {
		case "/stale.mp4":
			staleHits++
			w.WriteHeader(http.StatusForbidden)
		case "/fresh.mp4":
			freshHits++
			io.WriteString(w, "fresh-media")
		}
	}))
	defer upstream.Close()
	stream, _ := newRenewTestStream(t)
	refresher := func(context.Context) (providerMedia, error) {
		mu.Lock()
		renewals++
		mu.Unlock()
		return providerMedia{URL: upstream.URL + "/fresh.mp4", Referer: "https://example.test/watch"}, nil
	}
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/stale.mp4", Referer: "https://example.test/watch"}, refresher)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.nativeRelease(token)
	status, body := readRenewBody(t, address)
	if status != http.StatusOK || body != "fresh-media" {
		t.Fatalf("renewed request returned %d %q", status, body)
	}
	mu.Lock()
	hits, renewCount := staleHits, renewals
	mu.Unlock()
	// 原地址尝试两次（首次失败重试一次）后触发重签。
	if hits != 2 || renewCount != 1 {
		t.Fatalf("unexpected attempts: stale=%d renewals=%d", hits, renewCount)
	}
	// 第二次请求直接使用热替换后的地址，不再触发重签。
	status, _ = readRenewBody(t, address)
	if status != http.StatusOK {
		t.Fatalf("second request returned %d", status)
	}
	mu.Lock()
	hits, freshCount, renewCount := staleHits, freshHits, renewals
	mu.Unlock()
	if hits != 2 || freshCount != 2 || renewCount != 1 {
		t.Fatalf("second request renewed again: stale=%d fresh=%d renewals=%d", hits, freshCount, renewCount)
	}
}

func TestNativeStreamRetriesRandomNotFound(t *testing.T) {
	var mu sync.Mutex
	flakyHits := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mu.Lock()
		flakyHits++
		hits := flakyHits
		mu.Unlock()
		if hits == 1 {
			w.WriteHeader(http.StatusNotFound)
			return
		}
		io.WriteString(w, "ok")
	}))
	defer upstream.Close()
	stream, _ := newRenewTestStream(t)
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/flaky.mp4"})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.nativeRelease(token)
	status, body := readRenewBody(t, address)
	if status != http.StatusOK || body != "ok" {
		t.Fatalf("retry after random 404 returned %d %q", status, body)
	}
	mu.Lock()
	hits := flakyHits
	mu.Unlock()
	if hits != 2 {
		t.Fatalf("expected one retry, hits=%d", hits)
	}
}

func TestNativeStreamRenewFailureKeepsUpstreamError(t *testing.T) {
	var mu sync.Mutex
	renewals := 0
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusForbidden)
	}))
	defer upstream.Close()
	stream, _ := newRenewTestStream(t)
	refresher := func(context.Context) (providerMedia, error) {
		mu.Lock()
		renewals++
		mu.Unlock()
		return providerMedia{}, errors.New("解析失败")
	}
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/stale.mp4"}, refresher)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.nativeRelease(token)
	status, _ := readRenewBody(t, address)
	if status != http.StatusForbidden {
		t.Fatalf("renew failure should keep upstream status, got %d", status)
	}
	// 冷却期内不重复请求解析接口。
	readRenewBody(t, address)
	mu.Lock()
	count := renewals
	mu.Unlock()
	if count != 1 {
		t.Fatalf("renewal cooldown ignored, renewals=%d", count)
	}
}

func TestNativePlaybackEvictionKeepsActiveSession(t *testing.T) {
	engine, err := newNativeEngine(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	stream, err := newNativeStreamServer(engine.downloader)
	if err != nil {
		t.Fatal(err)
	}
	defer stream.server.Close()
	open := func() (string, string) {
		choice := nativePlaybackChoices(providerMedia{URL: "https://media.test/episode.mp4"}, 0)
		plan, err := engine.nativeOpenPlayback(context.Background(), choice)
		if err != nil {
			t.Fatal(err)
		}
		return plan.URL, plan.Session
	}
	active, activeToken := open()
	for i := 0; i < 7; i++ {
		open()
	}
	// 播放器持续读取活跃会话：直接推进 lastUsed（真实请求受环境时序干
	// 扰，不可作为确定性断言依据），之后新建会话时不得把它挤出。
	stream.mu.Lock()
	if session := stream.sessions[activeToken]; session != nil {
		session.lastUsed = time.Now()
	}
	stream.mu.Unlock()
	if status, _ := readRenewBody(t, active); status == http.StatusGone {
		t.Fatal("active session gone before eviction")
	}
	open()
	if status, _ := readRenewBody(t, active); status == http.StatusGone {
		engine.mu.Lock()
		for token, pb := range engine.playbacks {
			t.Logf("playback %s.. stream=%s.. created=%v", token[:8], pb.streamSession[:8], pb.created.Format("15:04:05.000"))
		}
		engine.mu.Unlock()
		stream.mu.Lock()
		for id, s := range stream.sessions {
			s.mu.Lock()
			t.Logf("stream %s.. lastUsed=%v", id[:8], s.lastUsed.Format("15:04:05.000"))
			s.mu.Unlock()
		}
		stream.mu.Unlock()
		t.Fatal("active session was evicted while newer idle sessions existed")
	}
}
