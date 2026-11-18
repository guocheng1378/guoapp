package core

import (
	"encoding/json"
	"testing"
)

// 红果 19 位 ID 超过 IEEE754 安全范围，goja Number 会静默改写。
// preserveIntegers 必须把它加引号，且不能动字符串内数字/小数/安全整数。
func TestHongguoPreserveIntegers(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{`{"id":7399988776655443322}`, `{"id":"7399988776655443322"}`},
		{`{"id":-7399988776655443322}`, `{"id":"-7399988776655443322"}`},
		{`{"id":9007199254740991}`, `{"id":9007199254740991}`},
		{`{"id":12345}`, `{"id":12345}`},
		{`{"id":"7399988776655443322"}`, `{"id":"7399988776655443322"}`},
		{`{"v":1.5}`, `{"v":1.5}`},
		{`{"v":1e20}`, `{"v":1e20}`},
		{`{"text":"id 7399988776655443322 ok","id":7399988776655443322}`,
			`{"text":"id 7399988776655443322 ok","id":"7399988776655443322"}`},
		{`{"text":"escaped \" 7399988776655443322","id":7399988776655443322}`,
			`{"text":"escaped \" 7399988776655443322","id":"7399988776655443322"}`},
	}
	for _, tc := range cases {
		if got := hongguoPreserveIntegers(tc.in); got != tc.want {
			t.Errorf("preserveIntegers(%s) = %s, want %s", tc.in, got, tc.want)
		}
	}
	// 加引号后必须是合法 JSON，且大整数以字符串保留。
	out := hongguoPreserveIntegers(`{"id":7399988776655443322}`)
	var parsed map[string]any
	if err := json.Unmarshal([]byte(out), &parsed); err != nil {
		t.Fatalf("preserved output is not valid JSON: %v", err)
	}
	if parsed["id"] != "7399988776655443322" {
		t.Fatalf("large integer not preserved as string: %v", parsed["id"])
	}
}
