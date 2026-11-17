package core

import (
	"context"
	"crypto/tls"
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCDNKeyEOFUsesVerifiedDNSAndKeepsMediaIdentity(t *testing.T) {
	var direct, lookups atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Host != "tp.tuafjz.cn" || request.TLS.ServerName != "tp.tuafjz.cn" || request.URL.RequestURI() != "/videos/synthetic/crypt.key?signature=a%2Fb" || request.Header.Get("Referer") != "https://huangguoai.com/watch/synthetic/" {
			t.Error("DNS recovery changed SNI, host, signature or referer", request.Host, request.URL, request.TLS.ServerName)
		}
		_, _ = writer.Write([]byte("0123456789abcdef"))
	}))
	defer server.Close()
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	base.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address == "tp.tuafjz.cn:443" {
			direct.Add(1)
			return nil, io.EOF
		}
		if address != "93.184.216.34:443" {
			t.Error("unexpected DNS destination", address)
			return nil, io.EOF
		}
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	resolver := newDNSResolver(base)
	resolver.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		lookups.Add(1)
		if request.URL.Query().Get("name") != "tp.tuafjz.cn" {
			t.Error("unexpected DNS query")
		}
		return sourceFixtureResponse(request, 200, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"}]}`), nil
	})
	transport := newCDNTransport(base, resolver)
	defer transport.CloseIdleConnections()
	d := &Downloader{client: &http.Client{Transport: transport}}
	for index := 0; index < 2; index++ {
		request, _ := http.NewRequest(http.MethodGet, "https://tp.tuafjz.cn/videos/synthetic/crypt.key?signature=a%2Fb", nil)
		request.Header.Set("Referer", "https://huangguoai.com/watch/synthetic/")
		response, err := d.doMediaRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || string(body) != "0123456789abcdef" || response.Request.URL.Host != "tp.tuafjz.cn" {
			t.Fatal("media key did not recover", err)
		}
	}
	if direct.Load() != 1 || lookups.Load() != 1 {
		t.Fatal("working CDN route was not reused", direct.Load(), lookups.Load())
	}
	for _, addresses := range [][]string{{"127.0.0.1"}, {"198.18.0.1"}, {"93.184.216.34", "10.0.0.1"}} {
		if validateCDNAddresses(addresses) == nil {
			t.Fatal("unsafe DNS answer was accepted", addresses)
		}
	}
}

func TestCoverDNSRecoveryAcceptsNewImageHosts(t *testing.T) {
	var direct, lookups atomic.Int32
	server := httptest.NewTLSServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		if request.Host != "new-cover.example.test" || request.TLS.ServerName != "new-cover.example.test" || request.URL.RequestURI() != "/poster/synthetic.img?signature=a%2Fb" || request.Header.Get("Referer") != "https://huangguoai.com/watch/synthetic/" {
			t.Error("DNS recovery changed SNI, host, signature or referer", request.Host, request.URL, request.TLS.ServerName)
		}
		_, _ = writer.Write([]byte("0123456789abcdef"))
	}))
	defer server.Close()
	base := http.DefaultTransport.(*http.Transport).Clone()
	base.Proxy = nil
	base.TLSClientConfig = &tls.Config{InsecureSkipVerify: true}
	base.DialContext = func(ctx context.Context, network, address string) (net.Conn, error) {
		if address == "new-cover.example.test:443" {
			direct.Add(1)
			return nil, io.EOF
		}
		if address != "93.184.216.34:443" {
			t.Error("unexpected DNS destination", address)
			return nil, io.EOF
		}
		return (&net.Dialer{}).DialContext(ctx, network, server.Listener.Addr().String())
	}
	resolver := newDNSResolver(base)
	resolver.client.Transport = sourceFixtureTransport(func(request *http.Request) (*http.Response, error) {
		lookups.Add(1)
		if request.URL.Query().Get("name") != "new-cover.example.test" {
			t.Error("unexpected DNS query")
		}
		return sourceFixtureResponse(request, 200, `{"Status":0,"Answer":[{"type":1,"TTL":120,"data":"93.184.216.34"}]}`), nil
	})
	transport := newCDNTransport(base, resolver)
	defer transport.CloseIdleConnections()
	d := &Downloader{client: &http.Client{Transport: transport}}
	for index := 0; index < 2; index++ {
		request, _ := http.NewRequestWithContext(context.WithValue(context.Background(), nativeCoverNetworkKey{}, true), http.MethodGet, "https://new-cover.example.test/poster/synthetic.img?signature=a%2Fb", nil)
		request.Header.Set("Referer", "https://huangguoai.com/watch/synthetic/")
		response, err := d.doMediaRequest(request)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		response.Body.Close()
		if err != nil || string(body) != "0123456789abcdef" || response.Request.URL.Host != "new-cover.example.test" {
			t.Fatal("media key did not recover", err)
		}
	}
	if direct.Load() != 1 || lookups.Load() != 1 {
		t.Fatal("working CDN route was not reused", direct.Load(), lookups.Load())
	}
	for _, addresses := range [][]string{{"127.0.0.1"}, {"198.18.0.1"}, {"93.184.216.34", "10.0.0.1"}} {
		if validateCDNAddresses(addresses) == nil {
			t.Fatal("unsafe DNS answer was accepted", addresses)
		}
	}
}

func dialToUnspecifiedForTest() error {
	return &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.IPv4zero, Port: 443}, Err: errors.New("connect: invalid argument")}
}

func TestBlockedHostLookup(t *testing.T) {
	request, _ := http.NewRequest(http.MethodPost, "https://log.snssdk.com/service/2/device_register/", strings.NewReader("body"))
	if !blockedHostLookup(request, dialToUnspecifiedForTest()) {
		t.Fatal("dial 到 0.0.0.0 应判为域名被劫持")
	}
	if !blockedHostLookup(request, &net.OpError{Op: "dial", Net: "tcp", Addr: &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 443}, Err: errors.New("refused")}) {
		t.Fatal("dial 到环回应判为域名被劫持")
	}
	if blockedHostLookup(request, errors.New("EOF")) {
		t.Fatal("普通错误不应触发重连")
	}
	ipRequest, _ := http.NewRequest(http.MethodGet, "https://1.2.3.4/x", nil)
	if blockedHostLookup(ipRequest, dialToUnspecifiedForTest()) {
		t.Fatal("显式 IP 不应触发重连")
	}
	noGetBody, _ := http.NewRequest(http.MethodPost, "https://log.snssdk.com/x", nil)
	noGetBody.Body = io.NopCloser(strings.NewReader("x"))
	noGetBody.GetBody = nil
	if blockedHostLookup(noGetBody, dialToUnspecifiedForTest()) {
		t.Fatal("带不可重建 body 的 POST 不应重连，否则会发空包")
	}
}

// TestCDNTransportPostRetriesWithBody 端到端复现红果设备注册 POST：系统 DNS
// 把域名解析到 0.0.0.0（首次 dial 失败），cdnTransport 走 DoH 重连到正确地址，
// 并且必须用 GetBody 重建原 body（签名含 body hash，空包会被判无效）。
func TestCDNTransportPostRetriesWithBody(t *testing.T) {
	const payload = `{"magic_tag":"ss_app_log","header":{}}`
	var received []string
	var mu sync.Mutex
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		mu.Lock()
		received = append(received, string(raw))
		mu.Unlock()
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"device_id_str":"123456","install_id_str":"654321"}`))
	}))
	defer server.Close()
	serverHost, serverPort, _ := net.SplitHostPort(strings.TrimPrefix(server.URL, "https://"))

	var dialCount int
	var dialMu sync.Mutex
	base := &http.Transport{
		TLSClientConfig: &tls.Config{InsecureSkipVerify: true},
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dialMu.Lock()
			dialCount++
			n := dialCount
			dialMu.Unlock()
			if n == 1 {
				return nil, dialToUnspecifiedForTest()
			}
			return (&net.Dialer{}).DialContext(ctx, network, addr)
		},
	}
	resolver := &dnsResolver{client: &http.Client{}, cache: map[string]dnsCacheEntry{}, inFlight: map[string]chan struct{}{}}
	resolver.cache["log.snssdk.com|"] = dnsCacheEntry{
		addresses: []string{serverHost + ":" + serverPort},
		expires:   time.Now().Add(time.Minute),
	}
	transport := newCDNTransport(base, resolver)

	request, err := http.NewRequest(http.MethodPost, "https://log.snssdk.com/service/2/device_register/", strings.NewReader(payload))
	if err != nil {
		t.Fatal(err)
	}
	response, err := transport.RoundTrip(request)
	if err != nil {
		t.Fatalf("域名被污染时应经 DoH 重连成功: %v", err)
	}
	response.Body.Close()
	mu.Lock()
	defer mu.Unlock()
	if len(received) != 1 {
		t.Fatalf("期望重连 1 次到达服务器，实际 %d", len(received))
	}
	if received[0] != payload {
		t.Fatalf("重连必须用 GetBody 重建原 body，得到 %q", received[0])
	}
}
