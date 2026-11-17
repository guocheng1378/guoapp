package core

import (
	"context"

	"duanjuapp/native/provider"
)

func (d *Downloader) fetchProviderRankingPage(ctx context.Context, board rankingBoard, page int, ranker provider.Ranker) (rankingPage, error) {
	items, err := ranker.RankingPage(ctx, d.host(), board.path, page)
	if err != nil {
		return rankingPage{}, err
	}
	result := rankingPage{Items: make([]rankingItem, 0, len(items)), HasMore: len(items) >= 20}
	for index, drama := range items {
		result.Items = append(result.Items, rankingItem{
			Rank:   (page-1)*20 + index + 1,
			Drama:  rankingDramaWithoutImages(drama),
			Metric: drama.Heat,
		})
	}
	return result, nil
}
