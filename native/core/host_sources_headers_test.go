package core

import (
	"context"
	"net/http"
	"testing"

	"duanjuapp/native/provider"
)

// 回归：Host.Text 原先只传 Address/Referer，自定义站源的 UA/请求头会被静默
// 丢弃（maccms 族全走 Text）。带自定义头时必须改走 duanjuDo。
func TestDownloaderHostTextForwardsHeaders(t *testing.T) {
	var seenAgent, seenToken, seenReferer string
	transport := func(request *http.Request) (*http.Response, error) {
		seenAgent = request.Header.Get("User-Agent")
		seenToken = request.Header.Get("X-Token")
		seenReferer = request.Header.Get("Referer")
		return rankingHTTPResponse(request, http.StatusOK, `{"code":1}`), nil
	}
	d := rankingTestDownloader(t, transport)
	host := d.host()
	text, err := host.Text(context.Background(), provider.Request{
		Source:  "custom-test",
		Address: "https://cms.test/api.php/provide/vod/?ac=list",
		Headers: map[string]string{
			"User-Agent": "UA-Custom",
			"X-Token":    "abc",
		},
	})
	if err != nil {
		t.Fatalf("带请求头的 Text 请求失败：%v", err)
	}
	if text != `{"code":1}` {
		t.Fatalf("Text 返回内容错误：%q", text)
	}
	if seenAgent != "UA-Custom" || seenToken != "abc" {
		t.Fatalf("自定义头未透传：UA=%q X-Token=%q", seenAgent, seenToken)
	}
	if seenReferer != "https://cms.test/api.php/provide/vod/?ac=list" {
		t.Fatalf("Referer 应回退为请求地址：%q", seenReferer)
	}
}

func TestDownloaderHostTextWithoutHeadersKeepsLegacyPath(t *testing.T) {
	transport := func(request *http.Request) (*http.Response, error) {
		return rankingHTTPResponse(request, http.StatusOK, "legacy"), nil
	}
	d := rankingTestDownloader(t, transport)
	text, err := d.host().Text(context.Background(), provider.Request{
		Address: "https://cms.test/api.php/provide/vod/?ac=list",
		Referer: "https://cms.test/",
	})
	if err != nil || text != "legacy" {
		t.Fatalf("无自定义头时不应改变既有链路：text=%q err=%v", text, err)
	}
}
