//go:build live

package core

import (
	"context"
	"net/http"
	"testing"
	"time"
)

func TestHuangdouLiveVipPlayAPI(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	d := &Downloader{
		cfg:           defaultConfig(),
		client:        &http.Client{Timeout: 30 * time.Second},
		providerHosts: map[string]string{},
		limiter:       newRequestLimiter(2, 0),
	}
	client := newHuangdouAPIClient(d)
	for _, seq := range []string{"1", "3"} {
		var decoded any
		err := client.call(ctx, "/drama/play", map[string]any{"id": "6a8c618e817f7dacc5972d84", "seq": seq}, &decoded)
		if err != nil {
			t.Logf("play seq=%s FAIL: %v", seq, err)
			continue
		}
		t.Logf("play seq=%s decoded=%#v", seq, decoded)
	}
}
