package core

import (
	"context"
	"strings"
	"testing"
)

// Huangguo family 的源，站源健康检测/媒体解析走 GetHuangguoChapters。
// 此前该入口漏了 case，非法 ID 也会先撞 "unsupported provider source"。
// 用各自详情函数的无网络早退作探针：报 unsupported 说明分发仍漏接，
// 报各自的「ID 无效」说明已进自己的 provider。
func TestGetHuangguoChaptersFamilySourcesRecognized(t *testing.T) {
	cases := []struct {
		source    string
		invalidID string
		wantError string
	}{
		{sourceHanxiaoquan, "not-a-number", "韩小圈视频 ID 无效"},
		{sourceJinguoduanju, "not-a-number", "禁果短剧剧集 ID 无效"},
		// 笔盒只拒绝特殊字符，普通字符串是合法 ID 会走网络；用含 / 的触发早退。
		{sourceBeabox, "bad/id", "笔盒视频 ID 无效"},
	}
	for _, tc := range cases {
		_, _, err := (&Downloader{}).GetHuangguoChapters(
			context.Background(),
			tc.source,
			tc.invalidID,
		)
		if err == nil {
			t.Errorf("[%s] expected invalid-ID error", tc.source)
			continue
		}
		if strings.Contains(err.Error(), "unsupported provider source") {
			t.Errorf("[%s] must dispatch to its own provider, got: %v", tc.source, err)
			continue
		}
		if !strings.Contains(err.Error(), tc.wantError) {
			t.Errorf("[%s] expected '%s', got: %v", tc.source, tc.wantError, err)
		}
	}
}
