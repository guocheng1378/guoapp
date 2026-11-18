package core

import (
	"archive/zip"
	"context"
	"net/http"
	"os"
	"path/filepath"
	"testing"

	"duanjuapp/native/provider"
)

func writeZipWithEntry(path, name, content string) error {
	file, err := os.Create(path)
	if err != nil {
		return err
	}
	defer file.Close()
	writer := zip.NewWriter(file)
	entry, err := writer.Create(name)
	if err != nil {
		return err
	}
	if _, err := entry.Write([]byte(content)); err != nil {
		return err
	}
	return writer.Close()
}

const jsModuleDemoScript = `
module.exports = {
  categories: function (force) {
    return [{ id: "all", name: "全部" }];
  },
  catalogPage: function (page, category) {
    return { items: [{ id: "demo:" + page + ":" + category, title: "demo drama", source: "jsdemo" }], hasMore: true };
  },
  detail: function (sourceID) {
    return {
      drama: { id: sourceID, title: "demo drama", source: "jsdemo" },
      chapters: [{ id: "1", title: "ep 1", videoUrl: "video-1" }]
    };
  },
  search: function (page, query) {
    return { items: [{ id: "demo:search", title: query, source: "jsdemo" }], hasMore: false };
  },
  resolveMedia: function (task) {
    return { url: "https://media.example.test/play.mp4", referer: "https://site.example.test/" };
  }
};
`

func writeDemoJSModule(t *testing.T, root string) {
	t.Helper()
	dir := filepath.Join(root, "jsdemo")
	if err := os.MkdirAll(dir, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	manifest := `{"id":"jsdemo","name":"Demo Module","version":"1.0.0","hosts":["site.example.test"],"capabilities":["fetch"]}`
	if err := os.WriteFile(filepath.Join(dir, "module.json"), []byte(manifest), 0o600); err != nil {
		t.Fatalf("manifest: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "main.js"), []byte(jsModuleDemoScript), 0o600); err != nil {
		t.Fatalf("script: %v", err)
	}
}

func TestJSModuleRegistersAndServes(t *testing.T) {
	root := t.TempDir()
	writeDemoJSModule(t, root)
	d := &Downloader{client: &http.Client{}}

	defer provider.Unregister("jsdemo")
	ids, err := RegisterJSModules(d, root)
	if err != nil {
		t.Fatalf("register: %v", err)
	}
	if len(ids) != 1 || ids[0] != "jsdemo" {
		t.Fatalf("registered ids = %v", ids)
	}
	entry, found := provider.Get("jsdemo")
	if !found {
		t.Fatal("provider not registered")
	}
	if entry.Spec().Name != "Demo Module" {
		t.Fatalf("spec name = %q", entry.Spec().Name)
	}

	cataloguer, ok := entry.(provider.Cataloguer)
	if !ok {
		t.Fatal("module should implement Cataloguer")
	}
	ctx := context.Background()
	categories, err := cataloguer.Categories(ctx, nil)
	if err != nil || len(categories) != 1 || categories[0].Name != "全部" {
		t.Fatalf("categories = %v, %v", categories, err)
	}
	items, hasMore, err := cataloguer.CatalogPage(ctx, nil, 2, "hot", "")
	if err != nil || len(items) != 1 || !hasMore {
		t.Fatalf("catalogPage = %v %v %v", items, hasMore, err)
	}
	if items[0].Title != "demo drama" || items[0].Source != "jsdemo" {
		t.Fatalf("catalog item = %+v", items[0])
	}

	detailer, ok := entry.(provider.Detailer)
	if !ok {
		t.Fatal("module should implement Detailer")
	}
	drama, chapters, err := detailer.Detail(ctx, nil, "demo:1")
	if err != nil || drama.Title != "demo drama" || len(chapters) != 1 || chapters[0].VideoURL != "video-1" {
		t.Fatalf("detail = %+v %+v %v", drama, chapters, err)
	}

	searcher, ok := entry.(provider.Searcher)
	if !ok {
		t.Fatal("module should implement Searcher")
	}
	found2, err := searcher.Search(ctx, nil, "关键词")
	if err != nil || len(found2) != 1 || found2[0].Title != "关键词" {
		t.Fatalf("search = %+v %v", found2, err)
	}

	resolver, ok := entry.(provider.MediaResolver)
	if !ok {
		t.Fatal("module should implement MediaResolver")
	}
	media, err := resolver.ResolveMedia(ctx, nil, provider.Task{})
	if err != nil || media.URL != "https://media.example.test/play.mp4" {
		t.Fatalf("resolveMedia = %+v %v", media, err)
	}
}

func TestJSModuleZipInstallRejectsTraversal(t *testing.T) {
	root := t.TempDir()
	if err := os.MkdirAll(root, 0o700); err != nil {
		t.Fatalf("mkdir: %v", err)
	}
	jsModuleRootPath = root
	zipPath := filepath.Join(t.TempDir(), "evil.zip")
	if err := writeZipWithEntry(zipPath, "../escape.js", "pwned"); err != nil {
		t.Fatalf("zip: %v", err)
	}
	if _, err := InstallJSModuleZip(&Downloader{}, zipPath); err == nil {
		t.Fatal("zip slip should be rejected")
	}
}
