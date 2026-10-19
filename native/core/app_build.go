package core

import (
	"duanjuapp/native/provider"
	"errors"
)

var buildAllSources = "false"

var errNativeBuildSource = errors.New("当前版本不包含此站源")

func init() {
	provider.Configure(provider.Config{AllSources: buildAllSources == "true"})
}

func nativeSourceAvailable(source string) bool {
	syncBuildVariant()
	if source == sourceDouban {
		// 豆瓣是榜单专用源（不注册 provider，无目录/详情/播放），任何变体均可用。
		return true
	}
	return provider.Available(source)
}

func syncBuildVariant() {
	if provider.AllSourcesEnabled() != (buildAllSources == "true") {
		provider.Configure(provider.Config{AllSources: buildAllSources == "true"})
	}
}

func nativeDramaAvailable(drama nativeDrama) bool {
	source, _, valid := splitProviderDramaID(drama.ID)
	if !valid && nativeSourceAvailable(drama.Source) && !provider.KnownSource(drama.Source) {
		// 榜单专用源（豆瓣）不注册 provider，条目 ID 反解必然失败；
		// 封面等条目级只读操作按显式 Source 采信（同 nativeNormalize 语义）。
		return true
	}
	return valid && nativeSourceAvailable(source) &&
		(drama.Source == "" || canonicalProviderSource(drama.Source) == source)
}

func nativeChapterAvailable(drama nativeDrama, chapter Chapter) bool {
	if !nativeDramaAvailable(drama) {
		return false
	}
	source, _, _ := splitProviderDramaID(drama.ID)
	if chapter.Source != "" && canonicalProviderSource(chapter.Source) != source {
		return false
	}
	if chapterSource, _, valid := splitProviderDramaID(chapter.ID); valid && chapterSource != source {
		return false
	}
	return true
}

func nativeDownloadAvailable(job nativeDownloadJob) bool {
	return nativeChapterAvailable(job.Drama, job.Chapter)
}

func nativeAuthorizeInput(input nativeInput) error {
	switch input.Action {
	case "recommendations", "cachedRecommendations", "suggestions", "danmaku":
		if !nativeSourceAvailable(sourceHongguo) {
			return errNativeBuildSource
		}
	case "rankings":
		board, found := findRankingBoard(input.Board)
		if !found || !nativeSourceAvailable(board.Source) {
			return errNativeBuildSource
		}
	case "catalog", "cached", "categories", "sourceStatus", "sourceJob", "cancelSourceJob":
		if !nativeSourceAvailable(input.Source) {
			return errNativeBuildSource
		}
		if input.Action == "sourceJob" && input.Drama.ID != "" &&
			(!nativeDramaAvailable(input.Drama) || sourceFromDramaID(input.Drama.ID) != canonicalProviderSource(input.Source)) {
			return errNativeBuildSource
		}
	case "cover", "prepareCover", "detail", "metadata", "resolve", "preload", "prepareHandoff", "enqueueDownloads", "localPlayback":
		if !nativeDramaAvailable(input.Drama) {
			return errNativeBuildSource
		}
		if (input.Action == "resolve" || input.Action == "preload" || input.Action == "prepareHandoff") && !nativeChapterAvailable(input.Drama, input.Chapter) {
			return errNativeBuildSource
		}
	}
	return nil
}
