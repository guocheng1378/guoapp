package core

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/dop251/goja"
)

// The upstream hongguo source module initialises several constants through
// host.hexDecode at load time, so the module can only be evaluated once the
// host primitives exist. This asserts every documented export is reachable.
func TestHongguoJSModuleLoads(t *testing.T) {
	module := &hongguoJSModule{vm: goja.New(), caches: map[string]any{}}
	if err := module.vm.Set("host", module.hostObject()); err != nil {
		t.Fatalf("set host: %v", err)
	}
	wrapped := "(function(){var module={exports:{}};(function(module,exports){\n" +
		hongguoJSModuleSource +
		"\n})(module,module.exports);return module.exports;})()"
	value, err := module.vm.RunString(wrapped)
	if err != nil {
		t.Fatalf("evaluate module: %v", err)
	}
	exports := value.ToObject(module.vm)
	for _, name := range []string{"categories", "catalogPage", "detail", "resolveMedia", "search", "suggestions"} {
		if exports.Get(name) == nil {
			t.Fatalf("missing export %q", name)
		}
	}
	t.Logf("module loaded, exports=%v", exports.Keys())
}

// host.exclusive runs a JS callback that itself calls cacheGet/cacheSet; if
// both used the same non-reentrant mutex the runtime would deadlock and the
// player would spin forever on "preparing episode".
func TestHongguoJSHostExclusiveCacheNoDeadlock(t *testing.T) {
	module := &hongguoJSModule{vm: goja.New(), caches: map[string]any{}}
	if err := module.vm.Set("host", module.hostObject()); err != nil {
		t.Fatalf("set host: %v", err)
	}
	done := make(chan error, 1)
	go func() {
		_, err := module.vm.RunString(`
			var seen = null;
			host.exclusive(function () {
				host.cacheSet("probe", 42);
				seen = host.cacheGet("probe");
				host.cacheSet("probe2", seen + 1);
			});
			if (seen !== 42) { throw new Error("cache lost inside exclusive: " + seen); }
			if (host.cacheGet("probe2") !== 43) { throw new Error("cache not persisted"); }
		`)
		done <- err
	}()
	select {
	case err := <-done:
		if err != nil {
			t.Fatalf("exclusive+cache: %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("deadlock: host.exclusive with nested cache calls never returned")
	}
}

// Drives the real upstream module through resolveMedia with a mocked network.
// An empty payload must surface as a domain error ("未返回…"), never as
// "xxx is not a function" - that would mean a host primitive has the wrong
// shape (JS calls retries()/maxPages() as functions, fetchText with an object).
func TestHongguoJSResolveMediaMockHost(t *testing.T) {
	module := &hongguoJSModule{vm: goja.New(), caches: map[string]any{}}
	vm := module.vm
	host := module.hostObject()
	host["fetch"] = func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(map[string]any{"status": 200, "body": "{}", "headers": map[string]any{}})
	}
	host["fetchText"] = func(call goja.FunctionCall) goja.Value {
		return vm.ToValue(map[string]any{"status": 200, "body": "", "headers": map[string]any{}})
	}
	if err := vm.Set("host", host); err != nil {
		t.Fatalf("set host: %v", err)
	}
	wrapped := "(function(){var module={exports:{}};(function(module,exports){\n" +
		hongguoJSModuleSource +
		"\n})(module,module.exports);return module.exports;})()"
	value, err := vm.RunString(wrapped)
	if err != nil {
		t.Fatalf("load module: %v", err)
	}
	module.exports = value.ToObject(vm)
	_, resolveErr := module.resolveMedia(context.Background(), "hongguo:7000000000000000001", "7000000000000000002")
	if resolveErr == nil {
		t.Fatal("expected an error for an empty mocked payload")
	}
	if strings.Contains(resolveErr.Error(), "is not a function") {
		t.Fatalf("host primitive has wrong shape: %v", resolveErr)
	}
	t.Logf("domain error as expected: %v", resolveErr)
}

// Playback query construction must match the V5 signing expectations.
func TestHongguoJSPlaybackQueryShape(t *testing.T) {
	values := hongguoPlaybackV5Query("123456789012345678", "87654321")
	for key, want := range map[string]string{
		"aid": "8662", "app_name": "novelread", "version_code": "74332",
		"channel": "vivo_8662_64", "device_type": "PGT-AN10", "os_version": "12",
	} {
		if got := values.Get(key); got != want {
			t.Fatalf("%s = %q, want %q", key, got, want)
		}
	}
}
