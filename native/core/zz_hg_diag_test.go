package core

import (
	"context"
	"encoding/json"
	"net/http"
	"testing"
)

func TestZZHongguoAppSearchProbe(t *testing.T) {
	d := &Downloader{cfg: Config{dataDir: t.TempDir(), Retries: 1}, limiter: newRequestLimiter(3, 0), providerHosts: map[string]string{}, client: &http.Client{}}
	paths := []struct {
		path    string
		payload any
	}{
		{"/novel/search/suggest/v1/", map[string]any{"query": "一生共生", "count": 10}},
		{"/novel/search/general/v1/", map[string]any{"query": "一生共生，嫡女翻盘", "count": 20}},
		{"/novel/search/single/v1/", map[string]any{"query": "一生共生", "offset": 0, "count": 20}},
		{"/search/general/v1/", map[string]any{"query": "一生共生", "offset": 0, "count": 20}},
		{"/novel/search/v1/", map[string]any{"query": "一生共生", "offset": 0, "count": 20}},
		{"/novel/search/", map[string]any{"query": "一生共生", "offset": 0, "count": 20}},
		{"/search/", map[string]any{"keyword": "一生共生", "offset": 0, "count": 20}},
	}
	for _, probe := range paths {
		result, err := d.hongguoAppRequest(context.Background(), "POST", probe.path, nil, probe.payload)
		if err != nil {
			t.Logf("%s -> ERR %v", probe.path, err)
			continue
		}
		encoded, _ := json.Marshal(result)
		if len(encoded) > 600 {
			encoded = encoded[:600]
		}
		t.Logf("%s -> %s", probe.path, encoded)
	}
}
