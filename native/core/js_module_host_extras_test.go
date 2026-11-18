package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// 上游 14 个官方模块用到的 host 原语必须全部存在，否则模块加载/调用时报
// "host.xxx is not a function"。这个测试用一个 mock 脚本逐一调用，锁定签名。
func TestUpstreamModuleHostPrimitivesAvailable(t *testing.T) {
	d := &Downloader{client: nil}
	manifest := JSModuleManifest{ID: "probe", Name: "探针", Version: "1.0.0", API: 1}
	// newJSModuleRuntime 不发网络，只用 goja 建运行时并挂 host。
	runtime, err := newJSModuleRuntime(d, manifest, `
		module.exports = {
			probe: function () {
				var out = {};
				out.preserve = host.preserveIntegers('{"id":9007199254740993}');
				out.lower = 'ABC'.toLowerCase();
				out.log = host.log('probe');
				out.preferred = host.preferredSite();
				host.saveState('probe', 'saved-value');
				out.state = host.loadState('probe');
				out.roundtrip = JSON.parse(host.preserveIntegers('{"small":123,"big":9007199254740993}'));
				return out;
			}
		};
	`)
	if err != nil {
		t.Fatalf("runtime load: %v", err)
	}
	// 指向一个临时目录，让 saveState/loadState 能落盘。
	root := t.TempDir()
	oldRoot := jsModuleRootPath
	jsModuleRootPath = root
	defer func() { jsModuleRootPath = oldRoot }()

	var result struct {
		Preserve  string         `json:"preserve"`
		Lower     string         `json:"lower"`
		Log       any            `json:"log"`
		Preferred string         `json:"preferred"`
		State     string         `json:"state"`
		Roundtrip map[string]any `json:"roundtrip"`
	}
	if err := runtime.call(nil, nil, "probe", &result); err != nil {
		t.Fatalf("probe call: %v", err)
	}
	if !strings.Contains(result.Preserve, `"9007199254740993"`) {
		t.Fatalf("preserveIntegers did not quote big int: %s", result.Preserve)
	}
	if result.Lower != "abc" {
		t.Fatalf("toLowerCase broken: %s", result.Lower)
	}
	if result.State != "saved-value" {
		t.Fatalf("state round trip failed: %q", result.State)
	}
	// 小数保持数字类型，大整数变字符串（goja 精度保护）。
	if _, ok := result.Roundtrip["small"].(float64); !ok {
		t.Fatalf("small int should stay number: %T", result.Roundtrip["small"])
	}
	if got, ok := result.Roundtrip["big"].(string); !ok || got != "9007199254740993" {
		t.Fatalf("big int should be string: %v (%T)", result.Roundtrip["big"], result.Roundtrip["big"])
	}
	// 状态确实落盘到模块目录。
	statePath := filepath.Join(root, "probe", "state", "probe.json")
	if raw, err := os.ReadFile(statePath); err != nil || string(raw) != "saved-value" {
		t.Fatalf("state not persisted: %q %v", raw, err)
	}
}

// prepareWebMedia / fetchPlaylist 需要 downloader，单独测签名存在（不真发请求）。
func TestUpstreamModuleMediaPrimitivesExist(t *testing.T) {
	d := &Downloader{client: nil}
	manifest := JSModuleManifest{ID: "probe2", Name: "探针2", Version: "1.0.0", API: 1}
	runtime, err := newJSModuleRuntime(d, manifest, `
		module.exports = {
			probe: function () {
				return {
					hasPrepare: typeof host.prepareWebMedia,
					hasPlaylist: typeof host.fetchPlaylist
				};
			}
		};
	`)
	if err != nil {
		t.Fatalf("runtime load: %v", err)
	}
	var result map[string]any
	if err := runtime.call(nil, nil, "probe", &result); err != nil {
		t.Fatalf("probe call: %v", err)
	}
	encoded, _ := json.Marshal(result)
	if !strings.Contains(string(encoded), `"hasPrepare":"function"`) ||
		!strings.Contains(string(encoded), `"hasPlaylist":"function"`) {
		t.Fatalf("media primitives missing: %s", encoded)
	}
}
