package core

import (
	"net"
	"testing"
)

func TestNativeLANShareableAddress(t *testing.T) {
	cases := []struct {
		name string
		ip   string
		want bool
	}{
		{"IPv4 private shareable", "192.168.2.141", true},
		{"IPv4 link-local shareable", "169.254.1.2", true},
		{"IPv6 ULA shareable", "fd00::1", true},
		{"IPv6 global shareable", "2001:db8::1", true},
		{"IPv6 link-local not shareable", "fe80::dfe6:2724:9f0b:c201", false},
	}
	for _, row := range cases {
		ip := net.ParseIP(row.ip)
		if ip == nil {
			t.Fatalf("%s: 解析测试 IP 失败: %s", row.name, row.ip)
		}
		if got := nativeLANShareableAddress(ip); got != row.want {
			t.Errorf("%s: nativeLANShareableAddress(%s) = %v, want %v", row.name, row.ip, got, row.want)
		}
	}
}
