package core

import (
	"context"
	"encoding/json"
	"net/http"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
)

// TestHongguoHelperDeviceRegistersIndependently 验证主/辅设备各自注册、号不同，
// 且辅助设备轮换不影响主设备（feed 双列并发预取依赖这条独立性）。
func TestHongguoHelperDeviceRegistersIndependently(t *testing.T) {
	var registrations atomic.Int32
	d := rankingTestDownloaderRaw(t, func(request *http.Request) (*http.Response, error) {
		if strings.Contains(request.URL.Host, "snssdk.com") {
			n := int(registrations.Add(1))
			id := strconv.Itoa(5000 + n)
			return rankingHTTPResponse(request, 200, hongguoDeviceRegistrationBody(id, id+"9")), nil
		}
		return rankingHTTPResponse(request, 200, `{"code":0,"data":{}}`), nil
	})
	ctx := context.Background()
	if err := d.ensureHongguoDevice(ctx, false, ""); err != nil {
		t.Fatalf("primary register: %v", err)
	}
	if err := d.ensureHongguoDevice(ctx, true, ""); err != nil {
		t.Fatalf("helper register: %v", err)
	}
	if registrations.Load() != 2 {
		t.Fatalf("registrations=%d want 2", registrations.Load())
	}
	client := d.hongguoClient()
	primaryID, _, primaryOK := client.device(false)
	helperID, _, helperOK := client.device(true)
	if !primaryOK || !helperOK {
		t.Fatal("both devices should be registered")
	}
	if primaryID == helperID {
		t.Fatalf("primary and helper share device id %s", primaryID)
	}
	// 辅助设备轮换：只换辅助号，主设备保持不变。
	if err := d.ensureHongguoDevice(ctx, true, helperID); err != nil {
		t.Fatalf("helper rotate: %v", err)
	}
	if registrations.Load() != 3 {
		t.Fatalf("registrations=%d want 3", registrations.Load())
	}
	if again, _, _ := client.device(false); again != primaryID {
		t.Fatalf("helper rotation changed primary: %s -> %s", primaryID, again)
	}
	if next, _, _ := client.device(true); next == helperID {
		t.Fatal("helper device did not rotate")
	}
}

// TestHongguoFeedRecommendationsContinueDoubleColCell 验证信息流推荐：
// 首次走 bookmall tab（免签）+ 双列单元格，续页走 cell/change 且主/辅设备
// 并发预取相邻单元格；最终累计去重得到完整的四部剧。
func TestHongguoFeedRecommendationsContinueDoubleColCell(t *testing.T) {
	const cellID = "6952850996422770718"
	card := func(id string) any {
		return map[string]any{"group_id_type": 9, "video_data": []any{map[string]any{"series_id": id, "title": "合成推荐 " + id}}}
	}
	changes := map[string]map[string]any{
		"6":  {"has_more": true, "next_offset": 12, "cell_view": map[string]any{"cell_data": []any{card("9002")}}},
		"12": {"has_more": true, "next_offset": 18, "cell_view": map[string]any{"cell_data": []any{card("9003")}}},
		"18": {"has_more": true, "next_offset": 24, "cell_view": map[string]any{"cell_data": []any{card("9003")}}},
		"24": {"has_more": false, "next_offset": 30, "cell_view": map[string]any{"cell_data": []any{card("9004")}}},
	}
	var mu sync.Mutex
	var cellOffsets []string
	tabCalls := 0
	transport := func(request *http.Request) (*http.Response, error) {
		query := request.URL.Query()
		var data map[string]any
		switch request.URL.Path {
		case hongguoBookmallTabPath:
			tabCalls++
			if query.Get("tab_type") != "8" {
				t.Errorf("bookmall tab tab_type=%q want 8", query.Get("tab_type"))
			}
			data = map[string]any{"tab_item": []any{map[string]any{"tab_type": 8, "session_id": "fixture-feed", "cell_data": []any{
				map[string]any{"cell_id": cellID, "show_type": 506, "next_offset": 6, "cell_data": []any{card("9001")}},
			}}}}
		case hongguoBookmallCellChangePath:
			if query.Get("cell_id") != cellID || query.Get("session_id") != "fixture-feed" || query.Get("show_type") != "506" ||
				query.Get("change_type") != "0" || query.Get("client_req_type") != "2" {
				t.Errorf("cell change lost params: %v", query)
			}
			mu.Lock()
			cellOffsets = append(cellOffsets, query.Get("offset"))
			mu.Unlock()
			data = changes[query.Get("offset")]
		default:
			t.Errorf("unexpected path %s", request.URL.Path)
		}
		body, _ := json.Marshal(map[string]any{"code": 0, "data": data})
		return sourceFixtureResponse(request, http.StatusOK, string(body)), nil
	}
	engine := sourceFixtureEngine(t, transport)
	ctx := context.Background()
	first, err := engine.nativeRecommendations(ctx, nativeInput{Category: "find_drama"})
	if err != nil || len(first.Items) != 1 || !first.HasMore || first.Items[0].Title != "合成推荐 9001" {
		t.Fatalf("first feed page: err=%v items=%v more=%v", err, first.Items, first.HasMore)
	}
	if tabCalls != 1 {
		t.Fatalf("bookmall tab calls=%d want 1", tabCalls)
	}

	mu.Lock()
	before := len(cellOffsets)
	mu.Unlock()
	if _, err := engine.nativeRecommendations(ctx, nativeInput{Category: "find_drama", Command: "more"}); err != nil {
		t.Fatalf("first more: %v", err)
	}
	mu.Lock()
	firstBatch := append([]string{}, cellOffsets[before:]...)
	mu.Unlock()
	if !sameOffsetSet(firstBatch, []string{"6", "12"}) {
		t.Fatalf("double-column prefetch on first more = %v want {6 12}", firstBatch)
	}

	mu.Lock()
	before = len(cellOffsets)
	mu.Unlock()
	last, err := engine.nativeRecommendations(ctx, nativeInput{Category: "find_drama", Command: "more"})
	if err != nil {
		t.Fatalf("second more: %v", err)
	}
	mu.Lock()
	secondBatch := append([]string{}, cellOffsets[before:]...)
	mu.Unlock()
	if !sameOffsetSet(secondBatch, []string{"18", "24"}) {
		t.Fatalf("double-column prefetch on second more = %v want {18 24}", secondBatch)
	}
	if len(last.Items) != 4 || last.HasMore || last.Items[2].Title != "合成推荐 9003" || last.Items[3].Title != "合成推荐 9004" {
		t.Fatalf("final feed state: items=%v more=%v", last.Items, last.HasMore)
	}
}

func sameOffsetSet(got, want []string) bool {
	if len(got) != len(want) {
		return false
	}
	seen := map[string]int{}
	for _, value := range got {
		seen[value]++
	}
	for _, value := range want {
		seen[value]--
		if seen[value] < 0 {
			return false
		}
	}
	for _, count := range seen {
		if count != 0 {
			return false
		}
	}
	return true
}
