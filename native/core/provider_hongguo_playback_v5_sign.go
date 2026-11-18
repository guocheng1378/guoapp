package core

// 红果播放 V5 签名：X-Medusa 与 signPlaybackV5 的入口。
// 与 provider_hongguo_playback_v5.go 同批从上游 bundled/hongguo 模块移植。

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"math/bits"
	"net/url"
	"strconv"
	"strings"
	"sync"
)

const (
	// hongguoPlaybackPath 是上游 2.0.1 起的取流接口（旧接口
	// /novel/player/video_model/v1/ 已停用，只会返回空包）。
	hongguoPlaybackPath = "/novel/player/multi_video_model/player/v1"
	// hongguoPlaybackBaseURL 是播放专用域名（注意是 sinfonlinea，不是
	// 目录接口用的 sinfonlineb）。
	hongguoPlaybackBaseURL = "https://api5-normal-sinfonlinea.fqnovel.com"
	// hongguoPlaybackUserAgent 必须与 V5 签名的设备参数一致（PGT-AN10/12）。
	hongguoPlaybackUserAgent = "com.phoenix.read/73932 (Linux; U; Android 12; zh_CN_#Hans; PGT-AN10; Build/V417IR;tt-ok/3.12.13.20)"
)

func hongguoCryptoRandRead(buf []byte) (int, error) { return rand.Read(buf) }

func md5Sum(data []byte) []byte {
	sum := md5.Sum(data)
	return sum[:]
}

type hongguoV5ProcessState struct {
	nonce   string
	started int64
}

var (
	hongguoV5ProcessMu sync.Mutex
	hongguoV5Process   *hongguoV5ProcessState
)

func hongguoV5ProcessOnce(nowMs int64) *hongguoV5ProcessState {
	hongguoV5ProcessMu.Lock()
	defer hongguoV5ProcessMu.Unlock()
	if hongguoV5Process == nil {
		hongguoV5Process = &hongguoV5ProcessState{
			nonce:   hongguoV5Base64URL(hongguoV5RandomBytes(18)),
			started: nowMs,
		}
	}
	return hongguoV5Process
}

func hongguoV5U32LE(data []byte) uint32 {
	return binary.LittleEndian.Uint32(data)
}

// hongguoV5Medusa 复刻 playbackV5Medusa。
func hongguoV5Medusa(queryHash, f13 []byte, ts uint32, who map[string]string, nowMs int64) string {
	process := hongguoV5ProcessOnce(nowMs)
	flags := make([]byte, 8)
	deviceInfo := hongguoV5Proto([][2]any{
		{1, 1}, {2, 2}, {3, "8662"}, {4, who["device_id"]}, {5, process.nonce},
		{6, "!noperm!"}, {12, "Asia/Shanghai,8"}, {13, "zh_CN"}, {22, who["os_version"]},
		{25, int(process.started)}, {30, who["device_type"]}, {31, who["device_brand"]},
		{32, who["device_type"]}, {34, who["device_brand"]},
	})
	env := hongguoV5Proto([][2]any{
		{6, "v04.10.03.04-bugfix"}, {8, who["channel"]}, {12, deviceInfo}, {14, who["version_name"]},
	})
	message := hongguoV5Proto([][2]any{
		{1, hongguoV5Magic()}, {2, 5}, {3, int(hongguoV5U32LE(hongguoV5RandomBytes(4)))}, {4, "8662"},
		{5, who["device_id"]}, {6, "646637794"}, {7, who["version_name"]}, {8, "v04.10.03-ml-android"},
		{9, 0x040a0300}, {10, flags}, {12, int(ts)}, {13, f13}, {14, queryHash[:min(6, len(queryHash))]},
		{15, hongguoV5Proto([][2]any{{1, 1}, {2, 1}, {3, 1}, {5, 1}})}, {17, int(ts)}, {20, "none"},
		{21, 377}, {23, env},
		{24, `{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}`},
	})
	nonce := hongguoV5U32LE(hongguoV5RandomBytes(4))
	signKey := hongguoV5SignKey()
	hashInput := append(append([]byte{}, signKey...), hongguoV5Le32(nonce)...)
	hashInput = append(hashInput, signKey...)
	hash := hongguoSM3(hashInput)
	high := (nonce >> 16) & 255
	seedValue := ^(((high << 11) | (nonce >> 24)) ^ (high >> 5) ^ high)
	seed := hongguoV5Le32(seedValue)
	transformed := append(append([]byte{}, flags...), hongguoV5Xmxor(message, hash[:])...)
	for left, right := 0, len(transformed)-1; left < right; left, right = left+1, right-1 {
		transformed[left], transformed[right] = transformed[right], transformed[left]
	}
	for index := 0; index < len(transformed); index++ {
		transformed[index] ^= seed[byte(^index)&3]
	}
	check := uint32(0x18000001) | ((uint32(queryHash[0]) & 63) << 14) | ((uint32(f13[0]) & 63) << 8)
	packed := make([]byte, 0, 1+4+4+len(transformed)+2)
	packed = append(packed, 0xca)
	packed = append(packed, hongguoV5RandomBytes(4)...)
	packed = append(packed, hongguoV5Le32(check)...)
	packed = append(packed, transformed...)
	packed = append(packed, byte((nonce>>16)&255), byte((nonce>>24)&255))
	encrypted, err := hongguoV5Carrier(md5Sum(signKey[:16]), md5Sum(signKey[16:32]), packed, ts)
	if err != nil {
		return ""
	}
	prefix := append(hongguoV5Le32(5), hongguoV5Magic()...)
	stamp := hongguoV5Le32(ts)
	for index := 0; index < len(prefix); index++ {
		prefix[index] ^= stamp[index&3]
	}
	out := append(prefix, byte(nonce&255), byte((nonce>>8)&255), 0, 1)
	return base64.StdEncoding.EncodeToString(append(out, encrypted...))
}

func hongguoV5QueryValue(query, name string) string {
	values, err := url.ParseQuery(query)
	if err != nil {
		return ""
	}
	return values.Get(name)
}

// signHongguoPlaybackV5 复刻 signPlaybackV5：挑一个让 IV 低 4 位为 12 的
// _rticket，再生成 X-Khronos / X-Helios / X-Medusa（可选 X-SS-STUB）。
func signHongguoPlaybackV5(base string, values url.Values, body []byte, nowMs int64) (string, map[string]string, error) {
	ts := uint32(nowMs / 1000)
	hasBody := body != nil
	bodyMd5 := make([]byte, 16)
	if hasBody {
		bodyMd5 = md5Sum(body)
	}
	for offset := 0; offset < 1024; offset++ {
		params := url.Values{}
		for key, list := range values {
			params[key] = append([]string{}, list...)
		}
		params.Set("_rticket", strconv.FormatInt(nowMs+int64(offset), 10))
		query := params.Encode()
		queryHashSum := hongguoSM3([]byte(query))
		queryHash := queryHashSum[:]
		if hongguoV5IV(queryHash, bodyMd5, ts)&15 != 12 {
			continue
		}
		who := map[string]string{}
		for _, name := range []string{"device_id", "version_name", "os_version", "device_type", "channel"} {
			value := hongguoV5QueryValue(query, name)
			if value == "" {
				return "", nil, errors.New("播放签名缺少设备字段：" + name)
			}
			who[name] = value
		}
		who["device_brand"] = hongguoV5QueryValue(query, "device_brand")
		if who["device_brand"] == "" {
			who["device_brand"] = "HONOR"
		}
		f13, err := hongguoV5Hash(queryHash, bodyMd5, ts)
		if err != nil {
			return "", nil, err
		}
		headers := map[string]string{
			"X-Khronos": strconv.FormatUint(uint64(ts), 10),
			"X-Helios":  hongguoV5Helios(ts),
			"X-Medusa":  hongguoV5Medusa(queryHash, f13, ts, who, nowMs),
		}
		if hasBody {
			headers["X-SS-STUB"] = strings.ToUpper(hexEncode(bodyMd5))
			headers["Content-Type"] = "application/json; charset=utf-8"
		}
		return base + "?" + query, headers, nil
	}
	return "", nil, errors.New("无法在 1024 次 ticket 尝试内生成 V5 播放签名")
}

func hexEncode(data []byte) string {
	const table = "0123456789abcdef"
	out := make([]byte, len(data)*2)
	for index, value := range data {
		out[index*2] = table[value>>4]
		out[index*2+1] = table[value&15]
	}
	return string(out)
}

// hongguoPlaybackV5Query 复刻 playbackQuery：播放请求专用设备参数。
func hongguoPlaybackV5Query(deviceID, installID string) url.Values {
	values := url.Values{}
	values.Set("aid", "8662")
	values.Set("app_name", "novelread")
	values.Set("version_code", "74332")
	values.Set("version_name", "7.4.3.32")
	values.Set("channel", "vivo_8662_64")
	values.Set("device_platform", "android")
	values.Set("device_type", "PGT-AN10")
	values.Set("os_version", "12")
	values.Set("update_version_code", "74332")
	values.Set("iid", installID)
	values.Set("cdid", hongguoV5UUIDLike())
	values.Set("device_id", deviceID)
	return values
}

// hongguoV5UUIDLike 生成 8-4-4-4-12 形态的随机串。
func hongguoV5UUIDLike() string {
	data := hongguoV5RandomBytes(16)
	data[6] = (data[6] & 0x0f) | 0x40
	data[8] = (data[8] & 0x3f) | 0x80
	hexed := hexEncode(data)
	return hexed[0:8] + "-" + hexed[8:12] + "-" + hexed[12:16] + "-" + hexed[16:20] + "-" + hexed[20:32]
}

var _ = bits.RotateLeft8
