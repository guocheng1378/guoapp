package core

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

// 可重建缓存（剧库/榜单/直播清单/封面）跟着系统缓存目录走，用户数据目录保持干净。
func TestNativeCacheDirectoryHoldsRebuildableCaches(t *testing.T) {
	dataDir, cacheDir := t.TempDir(), t.TempDir()
	engine, err := newNativeEngine(dataDir, cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	if got := engine.cacheDir(); got != filepath.Clean(cacheDir) {
		t.Fatalf("engine cache dir = %q", got)
	}
	if got := engine.downloader.cfg.cachePath(); got != filepath.Clean(cacheDir) {
		t.Fatalf("downloader cache path = %q", got)
	}
	if want := filepath.Join(filepath.Clean(cacheDir), "covers-v1"); engine.covers.directory != want {
		t.Fatalf("covers dir = %q, want %q", engine.covers.directory, want)
	}

	if err := engine.saveCatalogCache(sourceHongguo, &nativeCatalogResult{
		Items: []nativeDrama{{ID: "hongguo:1", Title: "缓存剧"}}, Page: 1, HasMore: true,
	}); err != nil {
		t.Fatal(err)
	}
	flushCatalogDiskForTest(t, engine)
	if _, err := os.Stat(filepath.Join(cacheDir, "catalogs.json")); err != nil {
		t.Fatal("catalogs.json was not written into the cache directory", err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "catalogs.json")); !os.IsNotExist(err) {
		t.Fatalf("catalogs.json leaked into the data directory (err = %v)", err)
	}

	downloads := engine.downloader
	downloads.rankings.mu.Lock()
	downloads.rankings.pages["douban-realtime:1"] = rankingPage{
		BoardID: "douban-realtime", Page: 1, FetchedAt: time.Now(), Items: []rankingItem{},
	}
	downloads.rankings.lastWrite = time.Time{}
	downloads.flushRankingCacheLocked()
	downloads.rankings.mu.Unlock()
	if _, err := os.Stat(filepath.Join(cacheDir, "rankings.json")); err != nil {
		t.Fatal("rankings.json was not written into the cache directory", err)
	}
	if want := filepath.Join(filepath.Clean(cacheDir), "live_cache.json"); downloads.liveFileName() != want {
		t.Fatalf("live cache path = %q, want %q", downloads.liveFileName(), want)
	}

	// 同一组目录重开引擎：剧库从缓存目录读回来，不需要重新联网。
	restarted, err := newNativeEngine(dataDir, cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	items := restarted.nativeCached(sourceHongguo).Items
	if len(items) != 1 || items[0].Title != "缓存剧" {
		t.Fatalf("cache directory was not read back on restart: %v", items)
	}
}

// 老版本把缓存落在数据目录：升级后一次性搬到缓存目录，用户不会丢一次缓存；
// 下载、追剧、设置这些用户数据必须原地不动。
func TestNativeMoveLegacyCacheMigratesOldArtifacts(t *testing.T) {
	dataDir, cacheDir := t.TempDir(), t.TempDir()
	if err := os.MkdirAll(filepath.Join(dataDir, "covers-v1"), 0700); err != nil {
		t.Fatal(err)
	}
	legacy := []byte(`{"version":3,"catalogs":{"hongguo":[{"id":"hongguo:7","title":"旧缓存","source":"hongguo"}]},"states":{}}`)
	if err := os.WriteFile(filepath.Join(dataDir, "catalogs.json"), legacy, 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "covers-v1", "poster.jpg"), []byte("cover"), 0600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dataDir, "sources.json"), []byte(`{"version":1,"sources":{}}`), 0600); err != nil {
		t.Fatal(err)
	}

	engine, err := newNativeEngine(dataDir, cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "catalogs.json")); err != nil {
		t.Fatal("legacy catalogs.json was not migrated", err)
	}
	if _, err := os.Stat(filepath.Join(cacheDir, "covers-v1", "poster.jpg")); err != nil {
		t.Fatal("legacy cover cache was not migrated", err)
	}
	if _, err := os.Stat(filepath.Join(dataDir, "catalogs.json")); !os.IsNotExist(err) {
		t.Fatal("legacy catalogs.json was copied instead of moved")
	}
	if _, err := os.Stat(filepath.Join(dataDir, "sources.json")); err != nil {
		t.Fatal("user data was moved out of the data directory", err)
	}
	items := engine.nativeCached(sourceHongguo).Items
	if len(items) != 1 || items[0].Title != "旧缓存" {
		t.Fatalf("migrated cache was not picked up: %v", items)
	}
}

// 缓存目录必须是绝对路径；不传或传空则沿用数据目录（测试与旧调用点）。
func TestNativeCacheDirectoryValidation(t *testing.T) {
	dataDir := t.TempDir()
	if _, err := newNativeEngine(dataDir, "relative/cache"); err == nil {
		t.Fatal("relative cache directory was accepted")
	}
	engine, err := newNativeEngine(dataDir)
	if err != nil {
		t.Fatal(err)
	}
	if engine.cacheDir() != dataDir || engine.downloader.cfg.cachePath() != dataDir {
		t.Fatalf("fallback cache dir = %q / %q", engine.cacheDir(), engine.downloader.cfg.cachePath())
	}
	engine, err = newNativeEngine(dataDir, "")
	if err != nil {
		t.Fatal(err)
	}
	if engine.cacheDir() != dataDir {
		t.Fatalf("empty cache directory did not fall back: %q", engine.cacheDir())
	}
}
