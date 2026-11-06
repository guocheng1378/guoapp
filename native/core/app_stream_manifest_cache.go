package core

import (
	"net/http"
	"strings"
)

// 清单改写的复用缓存。
//
// 改写一遍清单要做两趟逐行解析（广告剔除 + 地址重写），长清单动辄上千行；
// 播放器在同一集里会反复拉同一份清单（主清单探路、EXT-X-MEDIA 分组、
// 重载等），上游校验符没变时输出必然逐字节相同，直接回放即可。
//
// 为什么不跨会话复用：改写会向 session.assets 注册每个分片/密钥资产
// （nativeAsset），URL 里带 token，回放缓存必须跳过那次注册，跨会话就
// 变成「清单指向别的会话的资产」。故缓存挂在会话上，与资产同生共死。
const (
	// nativeManifestCacheEntries 是单会话最多缓存的清单份数。
	nativeManifestCacheEntries = 24
	// nativeManifestCacheEntryMax 是单份清单的缓存上限：更大的清单
	// （正常播放列表几十 KB）逐条进内存性价比低，直接不缓存。
	nativeManifestCacheEntryMax = 256 << 10
	// nativeManifestCacheTotalMax 是单会话清单缓存的总字节预算。
	nativeManifestCacheTotalMax = 2 << 20
)

// nativeManifestCache 是一份清单的改写结果与产出它的上游校验符。
// seq 是最近一次使用序号，逐出时挑最久没用的那条。
type nativeManifestCache struct {
	validator string
	rewritten string
	seq       int64
}

// nativeNextManifestSeq 递增会话内的使用序号（调用方已持有 manifestMu）。
func (session *nativeStreamSession) nativeNextManifestSeq() int64 {
	session.manifestSeq++
	return session.manifestSeq
}

// nativeManifestValidator 取上游的校验符：ETag 优先，其次 Last-Modified。
// 两者都没有说明上游不承诺内容稳定（直播清单常见），不参与缓存。
func nativeManifestValidator(header http.Header) string {
	if etag := strings.TrimSpace(header.Get("ETag")); etag != "" {
		return "etag:" + etag
	}
	if modified := strings.TrimSpace(header.Get("Last-Modified")); modified != "" {
		return "modified:" + modified
	}
	return ""
}

// nativeCachedManifest 命中则返回可原样回放的改写结果。
func (session *nativeStreamSession) nativeCachedManifest(base, validator string) (string, bool) {
	if validator == "" || base == "" {
		return "", false
	}
	session.manifestMu.Lock()
	defer session.manifestMu.Unlock()
	entry, found := session.manifests[base]
	if !found || entry.validator != validator {
		return "", false
	}
	// 命中即刷新使用序号，逐出按「最久没用」挑。
	entry.seq = session.nativeNextManifestSeq()
	session.manifests[base] = entry
	return entry.rewritten, true
}

// nativeStoreManifest 记下一份改写结果，按条数与总字节双预算逐出。
func (session *nativeStreamSession) nativeStoreManifest(base, validator, rewritten string) {
	if validator == "" || base == "" {
		return
	}
	size := len(rewritten)
	if size == 0 || size > nativeManifestCacheEntryMax {
		return
	}
	session.manifestMu.Lock()
	defer session.manifestMu.Unlock()
	if session.manifests == nil {
		session.manifests = map[string]nativeManifestCache{}
	}
	if previous, found := session.manifests[base]; found {
		session.manifestBytes -= len(previous.rewritten)
	}
	for len(session.manifests) >= nativeManifestCacheEntries ||
		session.manifestBytes+size > nativeManifestCacheTotalMax {
		victimKey := ""
		victimSeq := int64(0)
		for key, entry := range session.manifests {
			if key == base {
				continue
			}
			if victimKey == "" || entry.seq < victimSeq {
				victimKey, victimSeq = key, entry.seq
			}
		}
		if victimKey == "" {
			// 只剩正要覆盖的这一条：预算已无从腾挪，照写（条目数上限
			// 在上一轮覆盖时已成立，不会无限增长）。
			break
		}
		session.manifestBytes -= len(session.manifests[victimKey].rewritten)
		delete(session.manifests, victimKey)
	}
	session.manifests[base] = nativeManifestCache{validator: validator, rewritten: rewritten, seq: session.nativeNextManifestSeq()}
	session.manifestBytes += size
}
