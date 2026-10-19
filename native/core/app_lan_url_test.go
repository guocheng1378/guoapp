package core

import (
	"net/url"
	"testing"
)

// 设备互联地址携带 IPv6 zone（Windows 中文网卡名，如「以太网」）时的 URL 转义。
// 背景：url.URL{Host}.String() 会把 zone 里的裸中文转义成 %E4%BB…，而
// url.Parse 的 encodeZone 规则拒绝 zone 里转义的非 ASCII 字节，两端矛盾，
// 正是线上「invalid URL escape "%E4"」报错的根因。修法=手工拼端点 +
// lanURLHost 只把分隔符 % 转成 %25，zone 内容保持裸 UTF-8。
func TestLANURLHostEscapesIPv6Zone(t *testing.T) {
	cases := []struct {
		name    string
		address string
		want    string
	}{
		{"plain IPv4 passthrough", "192.168.2.141:9511", "192.168.2.141:9511"},
		{"no percent", "[fe80::1]:9511", "[fe80::1]:9511"},
		{"ascii zone escaped stays", "[fe80::1%25eth0]:9511", "[fe80::1%25eth0]:9511"},
		{"chinese zone gets escaped", "[fe80::1%以太网]:9511", "[fe80::1%25以太网]:9511"},
		{"chinese zone idempotent", "[fe80::1%25以太网]:9511", "[fe80::1%25以太网]:9511"},
		{"space in zone gets escaped", "[fe80::1%本地连接 2]:9511", "[fe80::1%25本地连接%202]:9511"},
	}
	for _, item := range cases {
		if got := lanURLHost(item.address); got != item.want {
			t.Fatalf("%s: lanURLHost(%q) = %q, want %q", item.name, item.address, got, item.want)
		}
	}

	// 手工拼接的端点必须能通过完整 URL 解析，且 Hostname 还原裸 zone
	// （交给 net.Dial 的 zone 语义）。这正是此前报 invalid URL escape 的位置。
	for _, address := range []string{"[fe80::1%以太网]:9511", "[fe80::1%本地连接 2]:9511", "[fe80::1%25eth0]:9511"} {
		endpoint := "https://" + lanURLHost(address) + "/zgj/v1/hello"
		parsed, err := url.Parse(endpoint)
		if err != nil {
			t.Fatalf("url.Parse(%q): %v", endpoint, err)
		}
		if host := parsed.Hostname(); host != "fe80::1%以太网" && host != "fe80::1%本地连接 2" && host != "fe80::1%eth0" {
			t.Fatalf("hostname %q must keep zone", host)
		}
	}

	// 反例对照：旧实现（URL{}.String()）产出的串正是线上报错形态。
	broken := (&url.URL{Scheme: "https", Host: "[fe80::1%以太网]:9511", Path: "/zgj/v1/hello"}).String()
	if _, err := url.Parse(broken); err == nil {
		t.Fatalf("expected the legacy URL{} rendering to stay broken: %q", broken)
	}
}
