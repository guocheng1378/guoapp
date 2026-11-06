package core

import (
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
)

// manifestCacheBytes 返回会话内缓存的真实字节总量，用于核对账目一致。
func manifestCacheBytes(session *nativeStreamSession) int {
	session.manifestMu.Lock()
	defer session.manifestMu.Unlock()
	total := 0
	for _, entry := range session.manifests {
		total += len(entry.rewritten)
	}
	return total
}

func TestNativeManifestValidator(t *testing.T) {
	header := http.Header{}
	if got := nativeManifestValidator(header); got != "" {
		t.Fatalf("没有任何校验符时应返回空串，得到 %q", got)
	}
	header.Set("Last-Modified", " Tue, 01 Jan 2030 00:00:00 GMT ")
	if got, want := nativeManifestValidator(header), "modified:Tue, 01 Jan 2030 00:00:00 GMT"; got != want {
		t.Fatalf("Last-Modified 校验符 %q，期望 %q", got, want)
	}
	header.Set("ETag", ` "abc123" `)
	if got, want := nativeManifestValidator(header), `etag:"abc123"`; got != want {
		t.Fatalf("ETag 应优先且去空白 %q，期望 %q", got, want)
	}
}

func TestNativeManifestCacheHitAndMiss(t *testing.T) {
	session := &nativeStreamSession{}
	const base = "https://origin.test/live/index.m3u8"
	const rewritten = "#EXTM3U\n#EXTINF:4.0,\nhttp://127.0.0.1:1/token/seg.ts\n"
	session.nativeStoreManifest(base, "etag:v1", rewritten)
	if got, hit := session.nativeCachedManifest(base, "etag:v1"); !hit || got != rewritten {
		t.Fatalf("同一校验符应命中并原样回放，hit=%v body=%q", hit, got)
	}
	if _, hit := session.nativeCachedManifest(base, "etag:v2"); hit {
		t.Fatal("校验符变化后不应命中")
	}
	if _, hit := session.nativeCachedManifest("https://origin.test/live/other.m3u8", "etag:v1"); hit {
		t.Fatal("不同清单地址不应共享缓存")
	}
	if _, hit := session.nativeCachedManifest(base, ""); hit {
		t.Fatal("上游没有校验符时不应命中")
	}
}

func TestNativeManifestCacheSkipsUnstableUpstream(t *testing.T) {
	session := &nativeStreamSession{}
	// 没有 ETag / Last-Modified 的直播清单不缓存。
	session.nativeStoreManifest("https://origin.test/live/index.m3u8", "", "#EXTM3U\n")
	if len(session.manifests) != 0 {
		t.Fatalf("无校验符不应写入缓存，实际 %d 条", len(session.manifests))
	}
	// 空地址、空正文同样不写。
	session.nativeStoreManifest("", "etag:v1", "#EXTM3U\n")
	session.nativeStoreManifest("https://origin.test/live/index.m3u8", "etag:v1", "")
	if len(session.manifests) != 0 || session.manifestBytes != 0 {
		t.Fatalf("空地址/空正文不应写入缓存，实际 %d 条 %d 字节", len(session.manifests), session.manifestBytes)
	}
	// 超过单份上限的清单不写（重新解析比占内存便宜）。
	oversize := strings.Repeat("#", nativeManifestCacheEntryMax+1)
	session.nativeStoreManifest("https://origin.test/live/huge.m3u8", "etag:v1", oversize)
	if len(session.manifests) != 0 {
		t.Fatal("超大清单不应进缓存")
	}
}

func TestNativeManifestCacheOverwriteKeepsAccounting(t *testing.T) {
	session := &nativeStreamSession{}
	const base = "https://origin.test/live/index.m3u8"
	first := strings.Repeat("a", 100)
	second := strings.Repeat("b", 40)
	session.nativeStoreManifest(base, "etag:v1", first)
	session.nativeStoreManifest(base, "etag:v2", second)
	if got, hit := session.nativeCachedManifest(base, "etag:v2"); !hit || got != second {
		t.Fatalf("覆盖后应命中新内容，hit=%v body=%q", hit, got)
	}
	if _, hit := session.nativeCachedManifest(base, "etag:v1"); hit {
		t.Fatal("覆盖后旧校验符不应命中")
	}
	if len(session.manifests) != 1 {
		t.Fatalf("同地址覆盖不应新增条目，实际 %d 条", len(session.manifests))
	}
	if session.manifestBytes != len(second) {
		t.Fatalf("字节账目 %d，期望 %d", session.manifestBytes, len(second))
	}
	if got := manifestCacheBytes(session); got != session.manifestBytes {
		t.Fatalf("账目与条目实际字节不一致：%d vs %d", session.manifestBytes, got)
	}
}

func TestNativeManifestCacheEvictsByEntryCap(t *testing.T) {
	session := &nativeStreamSession{}
	body := strings.Repeat("x", 32)
	stored := nativeManifestCacheEntries + 6
	for i := 0; i < stored; i++ {
		session.nativeStoreManifest(fmt.Sprintf("https://origin.test/live/index-%02d.m3u8", i), "etag:v1", body)
	}
	session.manifestMu.Lock()
	count := len(session.manifests)
	session.manifestMu.Unlock()
	if count != nativeManifestCacheEntries {
		t.Fatalf("条目数应压到上限 %d，实际 %d", nativeManifestCacheEntries, count)
	}
	// 最后写入的一批一定在。
	if _, hit := session.nativeCachedManifest(fmt.Sprintf("https://origin.test/live/index-%02d.m3u8", stored-1), "etag:v1"); !hit {
		t.Fatal("最新写入的清单不应被逐出")
	}
	// 最早写入的一定已被逐出。
	if _, hit := session.nativeCachedManifest("https://origin.test/live/index-00.m3u8", "etag:v1"); hit {
		t.Fatal("最早的清单应被逐出")
	}
	if got := manifestCacheBytes(session); got != session.manifestBytes {
		t.Fatalf("逐出后账目不一致：%d vs %d", session.manifestBytes, got)
	}
}

func TestNativeManifestCacheEvictsByByteBudget(t *testing.T) {
	session := &nativeStreamSession{}
	// 每条 200KB：单条在上限内，但 11 条会越过 2MB 总预算。
	size := 200 << 10
	body := strings.Repeat("y", size)
	limit := nativeManifestCacheTotalMax/size + 1
	for i := 0; i < limit; i++ {
		session.nativeStoreManifest(fmt.Sprintf("https://origin.test/live/big-%02d.m3u8", i), "etag:v1", body)
	}
	if session.manifestBytes > nativeManifestCacheTotalMax {
		t.Fatalf("总字节 %d 越过预算 %d", session.manifestBytes, nativeManifestCacheTotalMax)
	}
	if got := manifestCacheBytes(session); got != session.manifestBytes {
		t.Fatalf("逐出后账目不一致：%d vs %d", session.manifestBytes, got)
	}
	if _, hit := session.nativeCachedManifest(fmt.Sprintf("https://origin.test/live/big-%02d.m3u8", limit-1), "etag:v1"); !hit {
		t.Fatal("触发逐出的新条目本身必须留下")
	}
}

// 端到端：同一会话内重复拉同一份清单时，校验符未变就直接回放改写结果
// （上游内容变了也不重解析），校验符变化才重新解析。
func TestNativeStreamReusesRewrittenManifest(t *testing.T) {
	var mu sync.Mutex
	hits := 0
	manifestA := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg-a.ts\n#EXT-X-ENDLIST\n"
	manifestB := "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg-b.ts\n#EXT-X-ENDLIST\n"
	upstream := httptest.NewServer(http.HandlerFunc(func(writer http.ResponseWriter, request *http.Request) {
		mu.Lock()
		hits++
		current := hits
		mu.Unlock()
		writer.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		switch current {
		case 1:
			writer.Header().Set("ETag", `"v1"`)
			_, _ = io.WriteString(writer, manifestA)
		case 2:
			// 校验符没变：客户端只信校验符，应回放第一次的改写结果。
			writer.Header().Set("ETag", `"v1"`)
			_, _ = io.WriteString(writer, manifestB)
		default:
			writer.Header().Set("ETag", `"v2"`)
			_, _ = io.WriteString(writer, manifestB)
		}
	}))
	defer upstream.Close()
	stream, _ := newRenewTestStream(t)
	address, token, err := stream.nativeOpen(providerMedia{URL: upstream.URL + "/live/index.m3u8"})
	if err != nil {
		t.Fatal(err)
	}
	defer stream.nativeRelease(token)

	status, first := readRenewBody(t, address)
	if status != http.StatusOK || !strings.Contains(first, "#EXTM3U") || !strings.Contains(first, "#EXT-X-ENDLIST") {
		t.Fatalf("首次请求应返回改写后的清单，得到 %d %q", status, first)
	}
	if strings.Contains(first, "seg-a.ts") {
		t.Fatalf("分片地址应已改写成本机代理，得到 %q", first)
	}
	status, second := readRenewBody(t, address)
	if status != http.StatusOK {
		t.Fatalf("第二次请求状态 %d", status)
	}
	// 上游第二次给的内容与第一次不同，但校验符相同：只有走缓存才会逐字节相等。
	if second != first {
		t.Fatalf("校验符未变时应回放缓存，得到 %q，期望 %q", second, first)
	}
	status, third := readRenewBody(t, address)
	if status != http.StatusOK {
		t.Fatalf("第三次请求状态 %d", status)
	}
	if third == first {
		t.Fatalf("校验符变化后应重新改写，仍是旧内容 %q", third)
	}
	mu.Lock()
	total := hits
	mu.Unlock()
	if total != 3 {
		t.Fatalf("清单应回源三次（缓存不跳过回源），实际 %d 次", total)
	}
}
