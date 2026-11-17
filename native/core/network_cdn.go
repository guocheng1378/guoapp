package core

import (
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

type cdnRoute struct {
	address string
	expires time.Time
}

type cdnTransport struct {
	base       *http.Transport
	resolver   *dnsResolver
	mu         sync.Mutex
	transports map[string]*http.Transport
	preferred  map[string]cdnRoute
}

func newCDNTransport(base *http.Transport, resolver *dnsResolver) *cdnTransport {
	return &cdnTransport{base: base, resolver: resolver, transports: map[string]*http.Transport{}, preferred: map[string]cdnRoute{}}
}

func (transport *cdnTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	if request.URL.Scheme != "https" || (request.Method != http.MethodGet && request.Method != http.MethodHead) {
		// 非 GET/HEAD（红果设备注册、App 取流等 POST）同样可能被 DNS 污染到
		// 0.0.0.0/环回而 dial 失败。这类请求基础传输失败后，若判定为域名解析
		// 被劫持，也改用 DoH 解析出的公网地址重连（body 由 roundTripAddress
		// 通过 GetBody 重建）。没有可重建的 body 时不重试，避免发出空包被
		// 上游当成坏请求。正常网络零额外开销。
		response, err := transport.base.RoundTrip(request)
		if err == nil || !blockedHostLookup(request, err) {
			return response, err
		}
		return transport.roundTripResolved(request, nil, request.URL.Host, []string{""}, map[string]bool{}, err)
	}
	// 受保护 CDN 与封面请求：沿用「失败就换 DoH 解析出的地址」的强兜底；
	// 其余站源请求只在疑似 DNS 污染/连接被劫持时才重试，正常路径零额外开销。
	alwaysRetry := protectedCDNHost(request.URL.Hostname()) || request.Context().Value(nativeCoverNetworkKey{}) == true
	var proxyURL *url.URL
	var err error
	if transport.base.Proxy != nil {
		proxyURL, err = transport.base.Proxy(request)
		if err != nil {
			return nil, err
		}
	}
	routeKey := request.URL.Host
	if proxyURL != nil {
		routeKey += "|" + proxyURL.String()
	}
	transport.mu.Lock()
	preferred := transport.preferred[routeKey]
	transport.mu.Unlock()
	tried := map[string]bool{}
	var response *http.Response
	if preferred.address != "" && time.Now().Before(preferred.expires) {
		tried[preferred.address] = true
		response, err = transport.roundTripAddress(request, proxyURL, routeKey, preferred.address)
		if err == nil {
			return response, nil
		}
	} else {
		response, err = transport.base.RoundTrip(request)
		if err == nil {
			return response, nil
		}
	}
	if request.Context().Err() != nil {
		return nil, request.Context().Err()
	}
	if !alwaysRetry && !nativeDNSSuspect(err) {
		// 明显不是 DNS/劫持导致的失败（例如对端直接断开）：保持原有开销。
		return nil, err
	}
	return transport.roundTripResolved(request, proxyURL, routeKey, []string{dnsAlternateSubnet, ""}, tried, err)
}

// roundTripResolved 用 DoH 解析出的地址逐个重连。GET/HEAD 的强兜底与
// POST（红果设备注册/取流）的 DNS 污染兜底共用此逻辑；subnets 为空串表示
// 不使用 EDNS 客户端子网。routeKey 为空时是一次性重试，不写 preferred 缓存。
func (transport *cdnTransport) roundTripResolved(request *http.Request, proxyURL *url.URL, routeKey string, subnets []string, tried map[string]bool, lastErr error) (*http.Response, error) {
	for _, subnet := range subnets {
		entry, lookupErr := transport.resolver.lookupEntry(request.Context(), request.URL.Hostname(), subnet)
		if lookupErr != nil {
			if request.Context().Err() != nil {
				return nil, request.Context().Err()
			}
			continue
		}
		for _, address := range entry.addresses {
			if tried[address] || len(tried) >= 4 {
				continue
			}
			tried[address] = true
			response, err := transport.roundTripAddress(request, proxyURL, routeKey, address)
			if err == nil {
				if routeKey != "" {
					transport.mu.Lock()
					transport.preferred[routeKey] = cdnRoute{address: address, expires: entry.expires}
					transport.mu.Unlock()
				}
				return response, nil
			}
			if request.Context().Err() != nil {
				return nil, request.Context().Err()
			}
			lastErr = err
		}
	}
	return nil, fmt.Errorf("资源 %s 连接失败（已尝试备用 DNS 地址）: %w", request.URL.Hostname(), publicError(lastErr))
}

// nativeDNSSuspect 判断错误是否可能由 DNS 解析异常（含被去广告规则指向
// 0.0.0.0/环回地址）或连接被拒引起——这类失败值得改用 DoH 解析出的地址重试，
// 其它失败（对端断开、超时）保持原有开销。
func nativeDNSSuspect(err error) bool {
	if err == nil {
		return false
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return true
	}
	text := strings.ToLower(err.Error())
	for _, marker := range []string{
		"no such host",
		"server misbehaving",
		"connection refused",
		"network is unreachable",
		"no route to host",
		"cannot assign requested address",
	} {
		if strings.Contains(text, marker) {
			return true
		}
	}
	return false
}

func (transport *cdnTransport) roundTripAddress(request *http.Request, proxyURL *url.URL, routeKey, address string) (*http.Response, error) {
	pinned := transport.pinnedTransport(request.URL.Hostname(), proxyURL, routeKey, address)
	upstream := request.Clone(request.Context())
	upstream.Host = request.Host
	if upstream.Host == "" {
		upstream.Host = request.URL.Host
	}
	// POST body 在首次 base.RoundTrip 时已被读空，Clone 只是浅拷贝共享同一个
	// reader。用 GetBody 重建，否则重试会发出空包——红果设备注册/取流签名含
	// body hash，空包会被网关判无效。
	if request.Body != nil && request.Body != http.NoBody {
		if request.GetBody == nil {
			return nil, errors.New("请求体无法重建，跳过 DoH 重连")
		}
		body, bodyErr := request.GetBody()
		if bodyErr != nil {
			return nil, bodyErr
		}
		upstream.Body = body
	}
	upstream.URL.Host = address
	if port := request.URL.Port(); port != "" {
		upstream.URL.Host = net.JoinHostPort(address, port)
	}
	response, err := pinned.RoundTrip(upstream)
	if response != nil {
		response.Request = request
	}
	return response, err
}

// blockedHostLookup 判定基础传输失败是否由「域名被 DNS 劫持到
// 0.0.0.0/环回、或域名不存在」引起——这是红果设备注册在部分网络/电视盒上
// 失败的典型形态，值得改用 DoH 解析出的公网地址重连。对带 body 的请求要求
// 可重建（GetBody），否则重试只会发空包；对显式 IP/localhost 不重试。
func blockedHostLookup(request *http.Request, err error) bool {
	if err == nil {
		return false
	}
	host := request.URL.Hostname()
	if net.ParseIP(host) != nil || strings.EqualFold(host, "localhost") {
		return false
	}
	if request.Body != nil && request.Body != http.NoBody && request.GetBody == nil {
		return false
	}
	var dnsErr *net.DNSError
	if errors.As(err, &dnsErr) {
		return dnsErr.IsNotFound
	}
	var opErr *net.OpError
	if !errors.As(err, &opErr) || opErr.Op != "dial" {
		return false
	}
	address, ok := opErr.Addr.(*net.TCPAddr)
	return ok && (address.IP.IsUnspecified() || address.IP.IsLoopback())
}

func (transport *cdnTransport) pinnedTransport(host string, proxyURL *url.URL, routeKey, address string) *http.Transport {
	transport.mu.Lock()
	defer transport.mu.Unlock()
	key := routeKey + "|" + address
	if existing := transport.transports[key]; existing != nil {
		return existing
	}
	pinned := transport.base.Clone()
	if pinned.TLSClientConfig == nil {
		pinned.TLSClientConfig = &tls.Config{}
	}
	pinned.TLSClientConfig.ServerName = host
	pinned.Proxy = http.ProxyURL(proxyURL)
	if proxyURL != nil && proxyURL.Scheme == "https" {
		plainProxy := *proxyURL
		plainProxy.Scheme = "http"
		if plainProxy.Port() == "" {
			plainProxy.Host = net.JoinHostPort(proxyURL.Hostname(), "443")
		}
		pinned.Proxy = http.ProxyURL(&plainProxy)
		pinned.DialContext = transport.tlsProxyDialer(proxyURL.Hostname())
	}
	if len(transport.transports) >= 32 {
		for expiredKey, expiredTransport := range transport.transports {
			expiredTransport.CloseIdleConnections()
			delete(transport.transports, expiredKey)
			break
		}
	}
	transport.transports[key] = pinned
	return pinned
}

func (transport *cdnTransport) tlsProxyDialer(host string) func(context.Context, string, string) (net.Conn, error) {
	return func(ctx context.Context, network, address string) (net.Conn, error) {
		dial := transport.base.DialContext
		if dial == nil {
			dialer := &net.Dialer{Timeout: 10 * time.Second}
			dial = dialer.DialContext
		}
		connection, err := dial(ctx, network, address)
		if err != nil {
			return nil, err
		}
		config := &tls.Config{}
		if transport.base.TLSClientConfig != nil {
			config = transport.base.TLSClientConfig.Clone()
		}
		config.ServerName = host
		config.NextProtos = []string{"http/1.1"}
		secured := tls.Client(connection, config)
		if transport.base.TLSHandshakeTimeout > 0 {
			var cancel context.CancelFunc
			ctx, cancel = context.WithTimeout(ctx, transport.base.TLSHandshakeTimeout)
			defer cancel()
		}
		if err := secured.HandshakeContext(ctx); err != nil {
			connection.Close()
			return nil, err
		}
		return secured, nil
	}
}

func (transport *cdnTransport) CloseIdleConnections() {
	transport.base.CloseIdleConnections()
	transport.resolver.client.CloseIdleConnections()
	transport.mu.Lock()
	defer transport.mu.Unlock()
	for key, pinned := range transport.transports {
		pinned.CloseIdleConnections()
		delete(transport.transports, key)
	}
	transport.preferred = map[string]cdnRoute{}
}
