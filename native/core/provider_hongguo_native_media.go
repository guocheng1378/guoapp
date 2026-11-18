package core

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"sort"
	"strconv"
	"strings"
	"time"
)

// resolveHongguoAppMedia 取流。主设备失败后换辅助设备再试一次——与上游
// appMedia 的 [false, true] 轮换一致：红果网关按 device_id 分桶，主设备
// 落进坏桶时表现为连续空包，换独立设备号往往能立刻取到流。
func (downloader *Downloader) resolveHongguoAppMedia(ctx context.Context, videoID string) (providerMedia, error) {
	media, err := downloader.resolveHongguoAppMediaDevice(ctx, videoID, false)
	if err == nil || !hongguoNumericID.MatchString(videoID) {
		return media, err
	}
	if helperMedia, helperErr := downloader.resolveHongguoAppMediaDevice(ctx, videoID, true); helperErr == nil {
		return helperMedia, nil
	}
	return media, err
}

func (downloader *Downloader) resolveHongguoAppMediaDevice(ctx context.Context, videoID string, helper bool) (providerMedia, error) {
	if !hongguoNumericID.MatchString(videoID) {
		return providerMedia{}, errors.New("红果视频 ID 无效")
	}
	if helper {
		ctx = context.WithValue(ctx, hongguoHelperDeviceKey{}, true)
	}
	// 上游 2.0.1 起取流接口换成 multi_video_model，请求体也从
	// video_id/content_type 改成 mixed_video_id_map + dr_scene；
	// 旧的 video_model/v1/ 只会返回 HTTP 200 空包。
	payload := map[string]any{
		"biz_param": map[string]any{
			"detail_page_version": 0, "device_level": 3,
			"disable_digg_stat": false, "disable_video_relate_book": false,
			"need_all_video_definition": true, "need_mp4_align": false,
			"use_os_player": false, "use_server_dns": false, "video_platform": 1024,
		},
		"mixed_video_id_map": map[string]any{"1004": []any{videoID}},
		"dr_scene":           "player",
	}
	result, err := downloader.hongguoAppRequest(ctx, http.MethodPost, hongguoPlaybackPath, nil, payload)
	if err != nil {
		return providerMedia{}, err
	}
	// 响应形态：data["1004"][videoId]（多视频映射），或 data[videoId]。
	entries := nestedMap(result, "data")
	data := entries
	if bucket, ok := entries["1004"].(map[string]any); ok {
		data = bucket
	}
	if row, ok := data[videoID].(map[string]any); ok {
		data = row
	}
	if len(data) == 0 {
		return providerMedia{}, errors.New("红果 App 未返回所请求的分集播放信息")
	}
	model, err := hongguoVideoModel(data)
	if err != nil {
		return providerMedia{}, err
	}
	return selectHongguoAppMedia(model)
}

// hongguoVideoModel 从 play-info 的 data 里取出 video_model，兼容三种形态：
// 直接的对象、base64 编码的 JSON 串、以及没有 video_model 包裹时把
// video_list / 时长直接放在顶层。站点偶发改包时靠后两者兜底。
func hongguoVideoModel(data map[string]any) (map[string]any, error) {
	model, _ := data["video_model"].(map[string]any)
	if encoded, ok := data["video_model"].(string); ok && encoded != "" {
		if decoded, err := decodeHongguoBase64(encoded); err == nil && len(decoded) > 0 {
			encoded = string(decoded)
		}
		decoder := json.NewDecoder(strings.NewReader(encoded))
		decoder.UseNumber()
		if err := decoder.Decode(&model); err != nil {
			return nil, errors.New("红果 App 播放信息格式异常")
		}
	}
	if len(model) == 0 {
		if rows := anyList(data["video_list"]); len(rows) > 0 {
			model = map[string]any{
				"video_list":     data["video_list"],
				"video_duration": data["video_duration"],
				"duration":       data["duration"],
			}
		}
	}
	return model, nil
}

func selectHongguoAppMedia(model map[string]any) (providerMedia, error) {
	variants := anyList(model["video_list"])
	if rows, ok := model["video_list"].(map[string]any); ok && len(variants) == 0 {
		keys := make([]string, 0, len(rows))
		for key := range rows {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		for _, key := range keys {
			variants = append(variants, rows[key])
		}
	}
	duration, _ := strconv.ParseFloat(mapString(model, "video_duration", "duration"), 64)
	var keyErr error
	type scoredMedia struct {
		media providerMedia
		score int
	}
	var choices []scoredMedia
	for _, row := range variants {
		variant, _ := row.(map[string]any)
		meta := nestedMap(variant, "video_meta")
		codec := strings.ToLower(mapString(meta, "codec_type"))
		if codec == "bytevc2" || strings.Contains(strings.ToLower(mapString(variant, "gear_des_key")), "bytevc2") {
			continue
		}
		addresses := hongguoMediaAddresses(variant)
		if len(addresses) == 0 {
			continue
		}
		media := providerMedia{Referer: "https://novel.snssdk.com/", Duration: time.Duration(duration * float64(time.Second))}
		encryption := nestedMap(variant, "encrypt_info")
		spade := mapString(encryption, "spade_a")
		if spade != "" || encryption["encrypt"] == true || mapString(encryption, "encryption_method") == "cenc-aes-ctr" {
			var err error
			media.CENCKey, err = hongguoContentKey(spade)
			if err != nil {
				keyErr = err
				continue
			}
		}
		height, _ := strconv.Atoi(mapString(meta, "vheight"))
		if definition, err := strconv.Atoi(hongguoQualityNumber.FindString(mapString(meta, "definition"))); err == nil && definition > 0 {
			height = definition
		} else if width, _ := strconv.Atoi(mapString(meta, "vwidth")); width > 0 && (height == 0 || width < height) {
			height = width
		}
		media.Quality = height
		quality := height * 10
		if codec == "h264" || codec == "avc1" {
			quality++
		}
		for _, address := range addresses {
			media.URL = address
			choices = append(choices, scoredMedia{media: media, score: quality})
		}
	}
	if len(choices) > 0 {
		sort.SliceStable(choices, func(i, j int) bool { return choices[i].score > choices[j].score })
		selected := choices[0].media
		for _, choice := range choices {
			selected.Variants = append(selected.Variants, choice.media)
		}
		return selected, nil
	}
	if keyErr != nil {
		return providerMedia{}, fmt.Errorf("红果 App 媒体密钥不可用: %w", keyErr)
	}
	return providerMedia{}, errors.New("红果 App 未返回兼容的媒体，已跳过不支持的编码")
}

func hongguoMediaAddresses(info map[string]any) []string {
	var addresses []string
	seen := map[string]bool{}
	var add func(any)
	add = func(value any) {
		switch value := value.(type) {
		case string:
			address := strings.TrimSpace(value)
			if len(address) > 8192 {
				return
			}
			if !isProviderHTTPMediaURL(address) {
				decoded, err := decodeHongguoBase64(address)
				if err != nil {
					return
				}
				address = strings.TrimSpace(string(decoded))
			}
			if isProviderHTTPMediaURL(address) && !seen[address] {
				seen[address] = true
				addresses = append(addresses, address)
			}
		case []any:
			for _, item := range value {
				add(item)
			}
		}
	}
	for _, key := range []string{"main_url", "backup_url", "backup_url_1", "backup_url_2", "backup_urls", "url_list"} {
		add(info[key])
	}
	return addresses
}
