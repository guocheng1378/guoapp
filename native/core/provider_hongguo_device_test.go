package core

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// 红果网关按 device_id 分桶：坏桶对签名请求一律回 HTTP 200 空包。设备
// 注册 + 换号机制（provider_hongguo_device.go）保证签名请求尽量使用
// 已登记设备号，空包时换号兜底。本文件覆盖注册触发、跳过、换号与暂停。

func hongguoDeviceRegistrationBody(deviceID, installID string) string {
	return `{"device_id_str":"` + deviceID + `","install_id_str":"` + installID + `"}`
}

func TestHongguoAppRequestRegistersDeviceBeforeSigning(t *testing.T) {
	var registrations, plays atomic.Int32
	var playedDevice string
	var playsMu sync.Mutex
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			registrations.Add(1)
			return rankingHTTPResponse(request, 200, hongguoDeviceRegistrationBody("7311111111111111101", "7311111111111111102")), nil
		}
		plays.Add(1)
		playsMu.Lock()
		playedDevice = request.URL.Query().Get("device_id")
		playsMu.Unlock()
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	result, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"})
	if err != nil {
		t.Fatalf("signed request should succeed: %v", err)
	}
	if registrations.Load() != 1 {
		t.Fatalf("registrations=%d want 1", registrations.Load())
	}
	if plays.Load() != 1 {
		t.Fatalf("plays=%d want 1", plays.Load())
	}
	playsMu.Lock()
	got := playedDevice
	playsMu.Unlock()
	if got != "7311111111111111101" {
		t.Fatalf("played device_id=%q want registered one", got)
	}
	if nestedMap(result, "data") == nil {
		t.Fatalf("unexpected payload: %v", result)
	}
	client := d.hongguoClient()
	client.mu.Lock()
	registered := client.state.Registered
	client.mu.Unlock()
	if !registered {
		t.Fatal("state should be marked registered")
	}
}

func TestHongguoEnsureDeviceSkipsWhenRegistered(t *testing.T) {
	var registrations atomic.Int32
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			registrations.Add(1)
			return rankingHTTPResponse(request, 200, hongguoDeviceRegistrationBody("7322222222222222201", "7322222222222222202")), nil
		}
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	if err := d.ensureHongguoDevice(context.Background(), ""); err != nil {
		t.Fatalf("first register failed: %v", err)
	}
	// 已注册：常规检查（rejected=""）不再注册。
	if err := d.ensureHongguoDevice(context.Background(), ""); err != nil {
		t.Fatalf("skip check failed: %v", err)
	}
	// 换号场景中 rejected 与当前号不同（别的调用已换过号）：跳过。
	if err := d.ensureHongguoDevice(context.Background(), "999"); err != nil {
		t.Fatalf("stale rejected check failed: %v", err)
	}
	if registrations.Load() != 1 {
		t.Fatalf("registrations=%d want 1", registrations.Load())
	}
}

func TestHongguoAppRequestRotatesDeviceOnEmptyPacket(t *testing.T) {
	var registrations, plays atomic.Int32
	var playedDevices []string
	var playsMu sync.Mutex
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			registrations.Add(1)
			if registrations.Load() == 1 {
				return rankingHTTPResponse(request, 200, hongguoDeviceRegistrationBody("7333333333333333301", "7333333333333333302")), nil
			}
			return rankingHTTPResponse(request, 200, hongguoDeviceRegistrationBody("7333333333333333303", "7333333333333333304")), nil
		}
		plays.Add(1)
		playsMu.Lock()
		playedDevices = append(playedDevices, request.URL.Query().Get("device_id"))
		playsMu.Unlock()
		if plays.Load() == 1 {
			return rankingHTTPResponse(request, 200, ""), nil
		}
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"}); err != nil {
		t.Fatalf("rotation should recover: %v", err)
	}
	if registrations.Load() != 2 {
		t.Fatalf("registrations=%d want 2", registrations.Load())
	}
	if plays.Load() != 2 {
		t.Fatalf("plays=%d want 2", plays.Load())
	}
	playsMu.Lock()
	defer playsMu.Unlock()
	if playedDevices[0] != "7333333333333333301" {
		t.Fatalf("first play device=%q want old registered one", playedDevices[0])
	}
	if playedDevices[1] != "7333333333333333303" {
		t.Fatalf("second play device=%q want rotated one", playedDevices[1])
	}
}

func TestHongguoRegisterFailurePausesRetries(t *testing.T) {
	var registrations, plays atomic.Int32
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			registrations.Add(1)
			return rankingHTTPResponse(request, 500, ""), nil
		}
		plays.Add(1)
		return rankingHTTPResponse(request, 200, ""), nil
	})
	_, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_model/v1/", nil, map[string]string{"video_id": "1"})
	if err == nil || !strings.Contains(err.Error(), "未返回有效数据") {
		t.Fatalf("want empty-packet error, got %v", err)
	}
	if registrations.Load() != 1 {
		t.Fatalf("registrations=%d want 1 (empty packets must not retry registration while paused)", registrations.Load())
	}
	if plays.Load() < 3 {
		t.Fatalf("plays=%d want >=3", plays.Load())
	}
	// 第二个请求在暂停期内：不再打注册接口，直接用随机号继续请求。
	if _, err := d.hongguoAppRequest(context.Background(), http.MethodPost, "/novel/player/video_detail/v1/", nil, map[string]string{"video_id": "1"}); err == nil {
		t.Fatal("second request should still hit empty packets in tests")
	}
	if registrations.Load() != 1 {
		t.Fatalf("registrations=%d want 1 (pause window must suppress registration)", registrations.Load())
	}
}

func TestHongguoCatalogStateRegisteredPersistsThroughClone(t *testing.T) {
	state := hongguoCatalogState{Version: 1, DeviceID: "7344444444444444401", InstallID: "7344444444444444402", Registered: true, Feeds: map[string]hongguoCatalogCursor{}}
	cloned := cloneHongguoCatalogState(&state)
	if !cloned.Registered {
		t.Fatal("clone should keep Registered")
	}
	encoded, err := json.Marshal(cloned)
	if err != nil {
		t.Fatalf("marshal: %v", err)
	}
	if !strings.Contains(string(encoded), `"registered":true`) {
		t.Fatalf("snapshot should persist registered flag: %s", encoded)
	}
	var decoded hongguoCatalogState
	if err := json.Unmarshal(encoded, &decoded); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	if !decoded.Registered {
		t.Fatal("round trip should keep Registered")
	}
	// 旧缓存（无 registered 字段）零值恢复为 false，不影响 Version 校验。
	var legacy hongguoCatalogState
	if err := json.Unmarshal([]byte(`{"version":1,"deviceId":"1","installId":"2","feeds":{}}`), &legacy); err != nil {
		t.Fatalf("legacy unmarshal: %v", err)
	}
	if legacy.Registered {
		t.Fatal("legacy state without flag should default to false")
	}
	if legacy.Version != 1 {
		t.Fatalf("legacy version=%d", legacy.Version)
	}
}
