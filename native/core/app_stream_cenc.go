package core

import (
	"context"
	"encoding/binary"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// cencRangeOnce 单次按字节区间读取加密媒体，带站点的鉴权头与 Range。
// 返回的 bool 表示这次失败是否值得重新解析地址（签名过期/直链失效）。
func (stream *nativeStreamServer) cencRangeOnce(ctx context.Context, session *nativeStreamSession, address string, start, end int64) (*http.Response, int64, bool, error) {
	request, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, 0, false, err
	}
	request.Header.Set("User-Agent", hongguoWebMediaUserAgent(address))
	request.Header.Set("Referer", session.referer)
	request.Header.Set("Range", "bytes="+strconv.FormatInt(start, 10)+"-"+strconv.FormatInt(end, 10))
	response, err := stream.nativeRequest(request)
	if err != nil {
		return nil, 0, false, err
	}
	_, size, found := strings.Cut(response.Header.Get("Content-Range"), "/")
	total, parseErr := strconv.ParseInt(size, 10, 64)
	if response.StatusCode != http.StatusPartialContent || !found || parseErr != nil {
		renewable := response.StatusCode == http.StatusForbidden ||
			response.StatusCode == http.StatusNotFound || response.StatusCode == http.StatusGone
		_, _ = io.Copy(io.Discard, io.LimitReader(response.Body, 64<<10))
		_ = response.Body.Close()
		return nil, 0, renewable, fmt.Errorf("视频服务器不支持按位置读取（HTTP %d）", response.StatusCode)
	}
	return response, total, false, nil
}

// cencRange 读取加密媒体区间。红果直链带短时效签名，播放中途过期会 403；
// 与普通转发路径一样，先同址退避重试（CDN 随机 404），仍失败且可续期时
// 走后台重签热换地址后重试，否则解密路径会在签名过期后永久卡死。
func (stream *nativeStreamServer) cencRange(ctx context.Context, session *nativeStreamSession, id, address string, start, end int64) (*http.Response, int64, error) {
	response, total, renewable, err := stream.cencRangeOnce(ctx, session, address, start, end)
	for retry := 0; retry < 3 && err != nil && !renewable; retry++ {
		select {
		case <-ctx.Done():
			return nil, 0, ctx.Err()
		case <-time.After(time.Duration(150*(retry+1)) * time.Millisecond):
		}
		response, total, renewable, err = stream.cencRangeOnce(ctx, session, address, start, end)
	}
	if err != nil && renewable && id != "" && session.refresher != nil {
		results := session.nativeRenewAssetAsync(ctx, id, address)
		select {
		case renewed := <-results:
			if renewed.ok {
				response, total, _, err = stream.cencRangeOnce(ctx, session, renewed.address, start, end)
			}
		case <-time.After(nativeRenewWait):
		}
	}
	if err != nil {
		return nil, 0, err
	}
	return response, total, nil
}

func (stream *nativeStreamServer) cencBytes(ctx context.Context, session *nativeStreamSession, address string, start, end int64) ([]byte, int64, error) {
	response, total, err := stream.cencRange(ctx, session, "", address, start, end)
	if err != nil {
		return nil, 0, err
	}
	defer response.Body.Close()
	data, err := io.ReadAll(io.LimitReader(response.Body, end-start+1))
	return data, total, err
}

// cencLayout 定位并解析 fMP4 的 moov 段，构造解密布局（会话内缓存）。
func (stream *nativeStreamServer) cencLayout(ctx context.Context, session *nativeStreamSession, address string) (*cencLayout, error) {
	session.cencMu.Lock()
	defer session.cencMu.Unlock()
	if session.cenc != nil {
		return session.cenc, nil
	}
	const window = 1 << 20
	position, origin := int64(0), int64(0)
	data, total, err := stream.cencBytes(ctx, session, address, 0, window-1)
	if err != nil {
		return nil, err
	}
	for range 64 {
		if position+16 > origin+int64(len(data)) {
			if position+16 > total {
				break
			}
			origin = position
			if data, _, err = stream.cencBytes(ctx, session, address, origin, origin+window-1); err != nil {
				return nil, err
			}
		}
		if position+16 > origin+int64(len(data)) {
			break
		}
		head := data[position-origin:]
		size := int64(binary.BigEndian.Uint32(head))
		if size == 1 {
			size = int64(binary.BigEndian.Uint64(head[8:]))
		} else if size == 0 {
			size = total - position
		}
		if size < 8 || size > total-position {
			break
		}
		if string(head[4:8]) != "moov" {
			position += size
			continue
		}
		if size > 64<<20 {
			break
		}
		if position+size > origin+int64(len(data)) {
			origin = position
			if data, _, err = stream.cencBytes(ctx, session, address, position, position+size-1); err != nil {
				return nil, err
			}
		}
		if position+size > origin+int64(len(data)) {
			break
		}
		moov := append([]byte{}, data[position-origin:position-origin+size]...)
		layout, err := newCENCLayout(moov, position, total, session.cencKey)
		if err != nil {
			return nil, err
		}
		session.cenc = layout
		return layout, nil
	}
	return nil, errCENCLayout
}

// cencRequestRange 解析播放器的 Range 头，返回解密后要写回的区间。
func cencRequestRange(header string, total int64) (int64, int64, bool) {
	if header == "" {
		return 0, total - 1, true
	}
	value, found := strings.CutPrefix(header, "bytes=")
	first, last, dashed := strings.Cut(value, "-")
	if !found || !dashed || strings.Contains(value, ",") {
		return 0, 0, false
	}
	if first == "" {
		suffix, err := strconv.ParseInt(last, 10, 64)
		if err != nil || suffix <= 0 {
			return 0, 0, false
		}
		return max(0, total-suffix), total - 1, true
	}
	start, err := strconv.ParseInt(first, 10, 64)
	if err != nil || start < 0 || start >= total {
		return 0, 0, false
	}
	end := total - 1
	if last != "" {
		if end, err = strconv.ParseInt(last, 10, 64); err != nil || end < start {
			return 0, 0, false
		}
		end = min(end, total-1)
	}
	return start, end, true
}

// nativeServeDecrypted 边读加密字节边 AES-CTR 解密，输出明文 mp4 给播放器。
// 这样 mpv 不需要任何 CENC/DRM 支持，从根上避免花屏。
func (stream *nativeStreamServer) nativeServeDecrypted(ctx context.Context, writer http.ResponseWriter, request *http.Request, session *nativeStreamSession, id string, asset nativeStreamAsset) {
	layout, err := stream.cencLayout(ctx, session, asset.address)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadGateway)
		return
	}
	start, end, valid := cencRequestRange(request.Header.Get("Range"), layout.total)
	writer.Header().Set("Accept-Ranges", "bytes")
	if !valid {
		writer.Header().Set("Content-Range", "bytes */"+strconv.FormatInt(layout.total, 10))
		writer.WriteHeader(http.StatusRequestedRangeNotSatisfiable)
		return
	}
	status := http.StatusOK
	if request.Header.Get("Range") != "" {
		status = http.StatusPartialContent
	}
	respond := func() {
		writer.Header().Set("Content-Type", "video/mp4")
		writer.Header().Set("Content-Length", strconv.FormatInt(end-start+1, 10))
		if status == http.StatusPartialContent {
			writer.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, layout.total))
		}
		writer.WriteHeader(status)
	}
	if request.Method == http.MethodHead {
		respond()
		return
	}
	response, _, err := stream.cencRange(ctx, session, id, asset.address, start, end)
	if err != nil {
		http.Error(writer, "读取媒体失败，请重试", http.StatusBadGateway)
		return
	}
	defer response.Body.Close()
	respond()
	buffer := make([]byte, 64<<10)
	for offset := start; offset <= end; {
		size, err := io.ReadFull(response.Body, buffer[:min(int64(len(buffer)), end-offset+1)])
		if size > 0 {
			layout.apply(offset, buffer[:size])
			if _, writeErr := writer.Write(buffer[:size]); writeErr != nil {
				return
			}
			offset += int64(size)
		}
		if err != nil {
			return
		}
	}
}
