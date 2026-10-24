package core

// 红果播放签名测试（2026-10-22）：网关强校验后非评论请求必须带
// X-Argus/X-Ladon；验证签名头完整性、device_id/aid/body 接线、
// 确定性，以及旧 Gorgon 签名（回退路径）未被破坏。

import (
	"bytes"
	"encoding/base64"
	"net/http"
	"strings"
	"testing"
	"time"
)

func TestHongguoPlayerSignSetsAllHeaders(t *testing.T) {
	body := []byte(`{"series_id":"700001"}`)
	request, err := http.NewRequest(
		http.MethodPost,
		"https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_detail/v1/?aid=8662&device_id=123456789012345678&iid=87654321",
		bytes.NewReader(body),
	)
	if err != nil {
		t.Fatal(err)
	}
	signHongguoPlayerRequest(request, body, time.Unix(1792000000, 0))
	for _, name := range []string{"X-Gorgon", "X-Khronos", "X-SS-Req-Ticket", "X-SS-STUB", "X-Argus", "X-Ladon"} {
		if request.Header.Get(name) == "" {
			t.Fatalf("签名头缺失：%s", name)
		}
	}
	for _, name := range []string{"X-Argus", "X-Ladon"} {
		if _, err := base64.StdEncoding.DecodeString(request.Header.Get(name)); err != nil {
			t.Fatalf("%s 不是合法 base64：%v", name, err)
		}
	}
}

func TestHongguoPlayerArgusTracksDeviceAndBody(t *testing.T) {
	var nonce hongguoPlayerNonce
	for index := range nonce {
		nonce[index] = byte(index)
	}
	stamp := uint32(1792000000)
	query := "aid=8662&device_id=111"
	body := []byte(`{"series_id":"700001"}`)
	base := hongguoPlayerArgus(query, body, stamp, "111111111111111111", nonce)
	if base == "" {
		t.Fatal("X-Argus 为空")
	}
	if again := hongguoPlayerArgus(query, body, stamp, "111111111111111111", nonce); base != again {
		t.Fatal("X-Argus 不是确定性的")
	}
	if other := hongguoPlayerArgus(query, body, stamp, "222222222222222222", nonce); base == other {
		t.Fatal("X-Argus 未随 device_id 变化（字段 5 接线失效）")
	}
	if empty := hongguoPlayerArgus(query, nil, stamp, "111111111111111111", nonce); base == empty {
		t.Fatal("X-Argus 未随 body 变化（body hash 接线失效）")
	}
}

func TestHongguoPlayerLadonTracksAid(t *testing.T) {
	prefix := []byte{1, 2, 3, 4}
	base := hongguoPlayerLadon("8662", 1792000000, prefix)
	if base == "" {
		t.Fatal("X-Ladon 为空")
	}
	if again := hongguoPlayerLadon("8662", 1792000000, prefix); base != again {
		t.Fatal("X-Ladon 不是确定性的")
	}
	if other := hongguoPlayerLadon("8663", 1792000000, prefix); base == other {
		t.Fatal("X-Ladon 未随 aid 变化")
	}
}

// 旧 Gorgon 签名保留为回退路径：仍能完整设置 Gorgon 系头，且不带
// X-Argus/X-Ladon（与播放签名形成可区分的两条路径）。
func TestHongguoLegacySignStillSetsGorgonFamily(t *testing.T) {
	request, err := http.NewRequest(
		http.MethodPost,
		"https://api5-normal-sinfonlineb.fqnovel.com/novel/player/video_detail/v1/?aid=8662&device_id=123456789012345678",
		strings.NewReader(`{"series_id":"700001"}`),
	)
	if err != nil {
		t.Fatal(err)
	}
	signHongguoRequest(request, []byte(`{"series_id":"700001"}`), time.Unix(1792000000, 0))
	for _, name := range []string{"X-Gorgon", "X-Khronos", "X-SS-Req-Ticket", "X-SS-STUB"} {
		if request.Header.Get(name) == "" {
			t.Fatalf("旧签名头缺失：%s", name)
		}
	}
	if request.Header.Get("X-Argus") != "" || request.Header.Get("X-Ladon") != "" {
		t.Fatal("旧签名不应设置 X-Argus/X-Ladon")
	}
}
