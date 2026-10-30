package core

import "testing"

// TestProviderMediaRefererUsesActualHost 验证兜底 Referer 取「本次实际命中的 host」。
//
// 站源配置里的 base 只是默认入口：优选域名与两跳回退都会让真实请求落到另一个
// host 上，沿用 base 当 Referer 会被防盗链判成跨站引用。兜底路径必须跟着实际
// 命中的域走；自带 Referer 的站源（maccms 族）不受影响。
func TestProviderMediaRefererUsesActualHost(t *testing.T) {
	if got := providerMediaReferer("https://cdn.example.com/hls/index.m3u8", "https://source.example.com/"); got != "https://cdn.example.com/" {
		t.Fatalf("兜底 Referer 没有取实际命中的 host: %q", got)
	}
	if got := providerMediaReferer("http://mirror.example.com:8080/v/1.mp4", "https://source.example.com/"); got != "http://mirror.example.com:8080/" {
		t.Fatalf("兜底 Referer 丢了端口或协议: %q", got)
	}
	// 非 http(s) 地址（加密播放标识等）没法反查 host，退回配置 base。
	if got := providerMediaReferer("hongguo-cenc://abcdef", "https://source.example.com/"); got != "https://source.example.com/" {
		t.Fatalf("非 http 地址的兜底 Referer 不该被改写: %q", got)
	}
	if got := providerMediaReferer("", "https://source.example.com/"); got != "https://source.example.com/" {
		t.Fatalf("空地址的兜底 Referer 不该被改写: %q", got)
	}
}
