package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"
)

// providerHostsStoreFile 运行时学到的优选域名落盘文件名（位于引擎 dataDir）。
// 远程下发的 sourceConfig.providerHosts 与运行时探测结果共用同一张表：
// 启动时先读盘播种，远程配置随后到达会整表替换（远程仍是权威），
// 学到的域名再写回盘上，避免重启后又要从内置域名重新试错。
const providerHostsStoreFile = "provider-hosts.json"

var providerHostsStoreState struct {
	sync.Mutex
	directory string
	lastRaw   string
}

// seedProviderHostsFromDisk 读取上次运行落盘的优选域名，合并进包级播种表。
// 只补包级表尚不存在的键：远程配置或本次运行已写入的值优先。
// 落盘内容按 sanitizeProviderHosts 同一口径复验，防手改文件注入非法源站或地址。
func seedProviderHostsFromDisk(directory string) {
	directory = strings.TrimSpace(directory)
	if directory == "" {
		return
	}
	providerHostsStoreState.Lock()
	providerHostsStoreState.directory = directory
	providerHostsStoreState.Unlock()
	raw, err := os.ReadFile(filepath.Join(directory, providerHostsStoreFile))
	if err != nil || len(raw) == 0 {
		return
	}
	var stored map[string]string
	if err := json.Unmarshal(raw, &stored); err != nil || len(stored) == 0 {
		return
	}
	table := make(map[string]any, len(stored))
	for source, host := range stored {
		table[source] = host
	}
	hosts, ok := sanitizeProviderHosts(table)
	if !ok || len(hosts) == 0 {
		return
	}
	providerHostsHotMu.Lock()
	if providerHostsHot == nil {
		providerHostsHot = make(map[string]string, len(hosts))
	}
	for source, host := range hosts {
		if providerHostsHot[source] == "" {
			providerHostsHot[source] = host
		}
	}
	providerHostsHotMu.Unlock()
}

// rememberProviderHost 记录某源实测可用的域名：同时写引擎运行时表、包级播种表
// 并落盘。只写引擎表的话，引擎重建（切用户/重载）或进程重启就会丢失学习结果，
// 又退回内置域名重新试错。
func (d *Downloader) rememberProviderHost(source, host string) {
	source = canonicalProviderSource(strings.TrimSpace(source))
	host = strings.TrimRight(strings.TrimSpace(host), "/")
	if source == "" || host == "" || !validSourceBaseURL(host) {
		return
	}
	d.providerMu.Lock()
	if d.providerHosts == nil {
		d.providerHosts = map[string]string{}
	}
	changed := d.providerHosts[source] != host
	d.providerHosts[source] = host
	d.providerMu.Unlock()
	providerHostsHotMu.Lock()
	if providerHostsHot == nil {
		providerHostsHot = map[string]string{}
	}
	providerHostsHot[source] = host
	snapshot := cloneProviderHosts(providerHostsHot)
	providerHostsHotMu.Unlock()
	if changed {
		persistProviderHosts(snapshot)
	}
}

// persistProviderHosts 原子落盘优选域名表（临时文件 + rename）。
// 内容与上次成功写入相同时跳过，避免同一域名重复写盘。
func persistProviderHosts(hosts map[string]string) {
	providerHostsStoreState.Lock()
	defer providerHostsStoreState.Unlock()
	directory := providerHostsStoreState.directory
	if directory == "" {
		return
	}
	payload, err := json.Marshal(hosts)
	if err != nil {
		return
	}
	text := string(payload)
	if text == providerHostsStoreState.lastRaw {
		return
	}
	path := filepath.Join(directory, providerHostsStoreFile)
	temp := path + ".tmp"
	if err := os.WriteFile(temp, payload, 0600); err != nil {
		return
	}
	if err := os.Rename(temp, path); err != nil {
		_ = os.Remove(temp)
		return
	}
	providerHostsStoreState.lastRaw = text
}
