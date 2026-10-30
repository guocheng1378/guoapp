package core

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// resetProviderHostsState 清空包级覆盖表与落盘节流状态，避免用例间互相污染。
func resetProviderHostsState(t *testing.T) {
	t.Helper()
	clear := func() {
		providerHostsHotMu.Lock()
		providerHostsHot = nil
		providerHostsHotMu.Unlock()
		providerHostsStoreState.Lock()
		providerHostsStoreState.directory = ""
		providerHostsStoreState.lastRaw = ""
		providerHostsStoreState.Unlock()
	}
	clear()
	t.Cleanup(clear)
}

func TestRememberProviderHostPersistsAndSeeds(t *testing.T) {
	resetProviderHostsState(t)
	dir := t.TempDir()
	seedProviderHostsFromDisk(dir)

	d := &Downloader{providerHosts: map[string]string{}}
	d.rememberProviderHost(sourceHuangdou, "https://learned.example.com/")

	raw, err := os.ReadFile(filepath.Join(dir, providerHostsStoreFile))
	if err != nil {
		t.Fatalf("落盘文件缺失: %v", err)
	}
	var stored map[string]string
	if err := json.Unmarshal(raw, &stored); err != nil {
		t.Fatalf("落盘内容不是合法 JSON: %v", err)
	}
	if stored[sourceHuangdou] != "https://learned.example.com" {
		t.Fatalf("落盘值不符: %#v", stored)
	}
	if got := d.providerHosts[sourceHuangdou]; got != "https://learned.example.com" {
		t.Fatalf("运行时表未写入: %q", got)
	}

	// 模拟引擎重建/进程重启：清空内存态后应能从盘上恢复。
	providerHostsHotMu.Lock()
	providerHostsHot = nil
	providerHostsHotMu.Unlock()
	seedProviderHostsFromDisk(dir)
	if got := providerHostsSeed()[sourceHuangdou]; got != "https://learned.example.com" {
		t.Fatalf("重启后未恢复学到域名: %q", got)
	}
}

func TestSeedProviderHostsDoesNotOverrideExisting(t *testing.T) {
	resetProviderHostsState(t)
	dir := t.TempDir()
	payload := `{"` + sourceHuangdou + `":"https://disk.example.com"}`
	if err := os.WriteFile(filepath.Join(dir, providerHostsStoreFile), []byte(payload), 0600); err != nil {
		t.Fatalf("写测试落盘文件失败: %v", err)
	}
	providerHostsHotMu.Lock()
	providerHostsHot = map[string]string{sourceHuangdou: "https://remote.example.com"}
	providerHostsHotMu.Unlock()

	seedProviderHostsFromDisk(dir)
	if got := providerHostsSeed()[sourceHuangdou]; got != "https://remote.example.com" {
		t.Fatalf("读盘不应覆盖已生效的远程配置: %q", got)
	}
}

func TestSeedProviderHostsRejectsInvalidEntries(t *testing.T) {
	resetProviderHostsState(t)
	dir := t.TempDir()
	// 未注册源与非法地址：整表拒收，与远程下发同一口径（防手改文件注入）。
	payload := `{"not-a-source":"https://a.example.com","` + sourceHuangdou + `":"ftp://b.example.com"}`
	if err := os.WriteFile(filepath.Join(dir, providerHostsStoreFile), []byte(payload), 0600); err != nil {
		t.Fatalf("写测试落盘文件失败: %v", err)
	}

	seedProviderHostsFromDisk(dir)
	if got := providerHostsSeed(); len(got) != 0 {
		t.Fatalf("非法条目应整表拒收: %#v", got)
	}
}

func TestHuangdouProbeCandidatesSkipsTriedHost(t *testing.T) {
	original := huangdouAPIMirrors
	huangdouAPIMirrors = []string{"a.example.com", "b.example.com"}
	t.Cleanup(func() { huangdouAPIMirrors = original })

	candidates := huangdouProbeCandidates("https://a.example.com/")
	if len(candidates) != 1 || candidates[0] != "b.example.com" {
		t.Fatalf("已试域名应从扩散池排除: %#v", candidates)
	}
	// 池外域名（远程下发的自定义域）不参与去重，全池都要扩散。
	if all := huangdouProbeCandidates("https://other.example.com"); len(all) != 2 {
		t.Fatalf("池外域名不应缩减扩散池: %#v", all)
	}
	if all := huangdouProbeCandidates(""); len(all) != 2 {
		t.Fatalf("空优选域应保留全池: %#v", all)
	}
}

func TestProviderBaseURLHonorsProviderHosts(t *testing.T) {
	d := &Downloader{providerHosts: map[string]string{
		sourceHongguo:    "https://hongguo.example.com/",
		sourceHuangdou:   "https://huangdou.example.com",
		sourceHuangguoAI: "https://ai.example.com",
	}}
	cases := map[string]string{
		sourceHongguo:    "https://hongguo.example.com",
		sourceHuangdou:   "https://huangdou.example.com",
		sourceHuangguoAI: "https://ai.example.com",
	}
	for source, want := range cases {
		if got := d.providerBaseURL(source); got != want {
			t.Fatalf("%s 未采用热更覆盖: got %q want %q", source, got, want)
		}
	}
	// 无覆盖的源仍回落内置常量。
	if got := d.providerBaseURL(sourceYeguo); got != yeguoBaseURL {
		t.Fatalf("无覆盖源应回落内置地址: got %q want %q", got, yeguoBaseURL)
	}
}
