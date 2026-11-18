package core

import "testing"

// 详情合并必须保留目录页已带、详情源未必回吐的筛选/排序字段。
// 历史同型事故：Area/Year/Score 只在 provider.Drama 加、漏了透传链，
// Dart 永远读空；这里覆盖 Go 内部 merge 把已有值覆盖成空的路径。
func TestMergeNativeDramaKeepsFilterAndSortFields(t *testing.T) {
	previous := nativeDrama{
		MetadataSchema: nativeDramaMetadataSchema,
		ID:             "hongguo:1",
		Source:         sourceHongguo,
		Area:           "内地",
		Year:           "2026",
		Score:          "9.1",
		Duration:       2712,
	}
	// 详情源没给这四个字段（常见：详情接口字段比目录页少）。
	fresh := nativeDrama{
		MetadataSchema: nativeDramaMetadataSchema,
		ID:             "hongguo:1",
		Source:         sourceHongguo,
		Title:          "新标题",
	}
	merged := mergeNativeDrama(previous, fresh)
	if merged.Area != previous.Area {
		t.Errorf("Area lost: got %q want %q", merged.Area, previous.Area)
	}
	if merged.Year != previous.Year {
		t.Errorf("Year lost: got %q want %q", merged.Year, previous.Year)
	}
	if merged.Score != previous.Score {
		t.Errorf("Score lost: got %q want %q", merged.Score, previous.Score)
	}
	if merged.Duration != previous.Duration {
		t.Errorf("Duration lost: got %v want %v", merged.Duration, previous.Duration)
	}
	if merged.Title != fresh.Title {
		t.Errorf("fresh title should win: got %q", merged.Title)
	}
}

// 详情源给了新值时以新值为准，不被旧值覆盖。
func TestMergeNativeDramaPrefersFreshFilterFields(t *testing.T) {
	previous := nativeDrama{
		MetadataSchema: nativeDramaMetadataSchema,
		ID:             "hongguo:1",
		Area:           "内地",
		Year:           "2025",
		Score:          "8.0",
		Duration:       100,
	}
	fresh := nativeDrama{
		MetadataSchema: nativeDramaMetadataSchema,
		ID:             "hongguo:1",
		Area:           "韩国",
		Year:           "2026",
		Score:          "9.5",
		Duration:       3600,
	}
	merged := mergeNativeDrama(previous, fresh)
	if merged.Area != "韩国" || merged.Year != "2026" ||
		merged.Score != "9.5" || merged.Duration != 3600 {
		t.Errorf("fresh fields should win, got %+v", merged)
	}
}
