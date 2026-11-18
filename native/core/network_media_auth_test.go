package core

import (
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"testing"

	"duanjuapp/native/provider"
)

func TestMediaCredentialsApplyArbitraryHeader(t *testing.T) {
	base := &providerMediaCredentials{userAgent: "UA", referer: "https://site.example/"}
	withAuth := base.withHeader("X-Token", "abc123")
	if _, ok := base.headers["X-Token"]; ok {
		t.Fatal("withHeader must not mutate the original credentials")
	}
	request, _ := http.NewRequest(http.MethodGet, "https://cdn.example/seg.ts", nil)
	if err := withAuth.apply(request); err != nil {
		t.Fatalf("apply: %v", err)
	}
	if request.Header.Get("X-Token") != "abc123" {
		t.Fatalf("X-Token = %q", request.Header.Get("X-Token"))
	}
	if request.Header.Get("User-Agent") != "UA" || request.Header.Get("Referer") != "https://site.example/" {
		t.Fatalf("base headers lost: %+v", request.Header)
	}
	injected := base.withHeader("X-Bad", "v\r\nInjected: 1")
	request2, _ := http.NewRequest(http.MethodGet, "https://cdn.example/seg.ts", nil)
	_ = injected.apply(request2)
	if request2.Header.Get("Injected") != "" {
		t.Fatal("CRLF header injection not blocked")
	}
}

func TestModuleAuthorizesMediaPath(t *testing.T) {
	root := t.TempDir()
	script := `module.exports={
		categories:function(){return [];},
		mediaAuthorization:function(address, referer){return {header:"X-Token", value:"t-"+address};},
		rejectMediaAuthorization:function(address, value){}
	};`
	writeReloadTestModule(t, root, "authmod", "Auth", `,"hosts":["cdn.auth.test"],"mediaAuthPaths":["/seg/"]`, script)
	manifest, err := readJSModuleManifest(root, "authmod")
	if err != nil {
		t.Fatalf("manifest: %v", err)
	}
	scriptData, err := os.ReadFile(filepath.Join(root, "authmod", manifest.mainFile()))
	if err != nil {
		t.Fatalf("script: %v", err)
	}
	runtime, err := newJSModuleRuntime(&Downloader{client: http.DefaultClient}, manifest, string(scriptData))
	if err != nil {
		t.Fatalf("runtime: %v", err)
	}
	p := &jsModuleProvider{manifest: manifest, runtime: runtime}

	for _, tc := range []struct {
		address string
		want    bool
	}{
		{"https://cdn.auth.test/seg/1.ts?sig=xyz", true},
		{"https://cdn.auth.test/other/1.ts", false},
		{"https://other.test/seg/1.ts", false},
	} {
		parsed, _ := url.Parse(tc.address)
		if got := p.AuthorizesMedia(parsed); got != tc.want {
			t.Fatalf("AuthorizesMedia(%s) = %v, want %v", tc.address, got, tc.want)
		}
	}
}

func TestMediaRequestInjectsModuleAuthorization(t *testing.T) {
	var seenToken string
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seenToken = r.Header.Get("X-Token")
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	}))
	defer upstream.Close()
	parsed, _ := url.Parse(upstream.URL)
	host := parsed.Hostname()

	root := t.TempDir()
	script := `module.exports={
		categories:function(){return [];},
		mediaAuthorization:function(address, referer){return {header:"X-Token", value:"signed"};}
	};`
	extra := `,"hosts":["` + host + `"],"capabilities":["mediaAuth"],"mediaAuthPaths":["/seg/"]`
	writeReloadTestModule(t, root, "authinject", "AuthInject", extra, script)
	engine := testModuleEngine(t)
	engine.directory = root
	if err := reloadJSModule(engine.downloader, root, "authinject"); err != nil {
		t.Fatalf("reload: %v", err)
	}
	defer provider.Unregister("authinject")

	request, _ := http.NewRequest(http.MethodGet, upstream.URL+"/seg/1.ts", nil)
	request.Header.Set("Referer", "https://site.example/")
	response, err := engine.downloader.doMediaRequestWithClient(request, http.DefaultClient)
	if err != nil {
		t.Fatalf("media request: %v", err)
	}
	response.Body.Close()
	if seenToken != "signed" {
		t.Fatalf("module authorization header not injected: %q", seenToken)
	}
}
