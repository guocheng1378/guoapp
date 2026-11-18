package core

import "testing"

// 站点 kind → Dart Drama.contentKind 的映射：Dart 只认小写的 'short'/'long'，
// 站点值是 short_drama/series/...，必须映射；未知值留空走 Dart 信号链。
func TestDongpiandiContentKind(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"short_drama", "short"},
		{"SHORT_DRAMA", "short"},
		{" short_drama ", "short"},
		{"series", "long"},
		{"movie", "long"},
		{"anime", "long"},
		{"variety", "long"},
		{"documentary", ""},
		{"", ""},
	}
	for _, tc := range cases {
		if got := dongpiandiContentKind(tc.in); got != tc.want {
			t.Errorf("dongpiandiContentKind(%q) = %q, want %q", tc.in, got, tc.want)
		}
	}
}
