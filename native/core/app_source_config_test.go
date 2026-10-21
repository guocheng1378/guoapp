package core

import "testing"

// resetSourceConfigForTest 记录进入时的热更值，测试结束后恢复，
// 避免污染同包其它测试的内置兜底状态。
func resetSourceConfigForTest(t *testing.T) {
	t.Helper()
	prevMirrors := huangguoAIMirrorList()
	prevDongpiandi := dongpiandiBaseURL()
	t.Cleanup(func() {
		setHuangguoAIMirrors(prevMirrors)
		setDongpiandiBaseURL(prevDongpiandi)
	})
}

// TestApplySourceConfigRemoteUpdate 远程下发的镜像表与 dongpiandi 根地址生效，
// 且镜像候选与缓存 PageURL 解析真正消费热更后的值；旧缓存（内置域名）仍可解析。
func TestApplySourceConfigRemoteUpdate(t *testing.T) {
	resetSourceConfigForTest(t)
	value, err := applySourceConfig(map[string]any{
		"huangguoAIMirrors": []any{"https://mirror-a.example.com/", "https://mirror-b.example.com", "https://mirror-a.example.com"},
		"dongpiandiBaseURL": "https://dpi.example.com/",
	})
	if err != nil {
		t.Fatalf("applySourceConfig: %v", err)
	}
	result, ok := value.(map[string]any)
	if !ok || result["applied"] != true {
		t.Fatalf("applied 期望 true，实际 %v", value)
	}
	mirrors := huangguoAIMirrorList()
	if len(mirrors) != 2 || mirrors[0] != "https://mirror-a.example.com" || mirrors[1] != "https://mirror-b.example.com" {
		t.Fatalf("镜像表未按预期热更（应去重+去尾斜杠）：%v", mirrors)
	}
	if got := dongpiandiBaseURL(); got != "https://dpi.example.com" {
		t.Fatalf("dongpiandi 根地址未热更：%s", got)
	}
	// 镜像候选消费热更后的镜像表。
	candidates := providerURLCandidates("https://huangguoai.com/d/abc123")
	if len(candidates) < 2 || candidates[0] != "https://mirror-a.example.com/d/abc123" {
		t.Fatalf("镜像候选未消费热更镜像表：%v", candidates)
	}
	// 新域名下发的 PageURL 可解析出剧集 ID。
	if id := dongpiandiDetailIDFromPageURL("https://dpi.example.com/player/ep42"); id != "ep42" {
		t.Fatalf("新域名 PageURL 解析失败：%q", id)
	}
	// 旧缓存（内置域名 PageURL）在热更后仍可解析。
	if id := dongpiandiDetailIDFromPageURL("https://dongpiandi.ai/player/legacy7"); id != "legacy7" {
		t.Fatalf("旧缓存（内置域名）解析失败：%q", id)
	}
}

// TestApplySourceConfigRejectsInvalid 非法配置整段丢弃（applied=false 且报原因），
// 不污染当前生效值。
func TestApplySourceConfigRejectsInvalid(t *testing.T) {
	resetSourceConfigForTest(t)
	setHuangguoAIMirrors([]string{"https://keep.example.com"})
	setDongpiandiBaseURL("https://keep-dpi.example.com")
	cases := []map[string]any{
		{"huangguoAIMirrors": []any{"ftp://bad.example.com"}},
		{"huangguoAIMirrors": []any{}},
		{"huangguoAIMirrors": []any{"https://ok.example.com", "not-a-url"}},
		{
			"huangguoAIMirrors": []any{
				"https://a1.example.com", "https://a2.example.com", "https://a3.example.com",
				"https://a4.example.com", "https://a5.example.com", "https://a6.example.com",
				"https://a7.example.com", "https://a8.example.com", "https://a9.example.com",
			},
		},
		{"huangguoAIMirrors": "https://text.example.com"},
		{"dongpiandiBaseURL": "ftp://bad.example.com"},
		{"dongpiandiBaseURL": 42},
		{"dongpiandiBaseURL": "   "},
		{"unknown": "value"},
		{},
	}
	for i, config := range cases {
		value, err := applySourceConfig(config)
		if err != nil {
			t.Fatalf("用例 %d: err = %v", i, err)
		}
		result, ok := value.(map[string]any)
		if !ok || result["applied"] != false {
			t.Fatalf("用例 %d: applied 期望 false，实际 %v", i, value)
		}
	}
	if mirrors := huangguoAIMirrorList(); len(mirrors) != 1 || mirrors[0] != "https://keep.example.com" {
		t.Fatalf("非法段不应污染镜像表：%v", mirrors)
	}
	if got := dongpiandiBaseURL(); got != "https://keep-dpi.example.com" {
		t.Fatalf("非法段不应污染 dongpiandi 根地址：%s", got)
	}
}

// TestSourceConfigFallbackDefaults 未配置时走内置兜底；未知域名的缓存页不解析。
func TestSourceConfigFallbackDefaults(t *testing.T) {
	resetSourceConfigForTest(t)
	setDongpiandiBaseURL("")
	if got := dongpiandiBaseURL(); got != dongpiandiBaseURLDefault {
		t.Fatalf("空热更值应回退内置：%s", got)
	}
	if id := dongpiandiDetailIDFromPageURL(dongpiandiBaseURLDefault + "/player/abc9"); id != "abc9" {
		t.Fatalf("内置域名 PageURL 解析失败：%q", id)
	}
	if id := dongpiandiDetailIDFromPageURL("https://other.example.com/player/abc9"); id != "" {
		t.Fatalf("未知域名 PageURL 不应解析出 ID：%q", id)
	}
}
