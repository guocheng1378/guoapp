package yunzhui

import (
	"context"
	"errors"
	"strconv"
	"strings"

	"duanjuapp/native/provider"
)

func (s *Source) RankingPage(ctx context.Context, host provider.Host, path string, page int) ([]provider.Drama, error) {
	if page < 1 {
		page = 1
	}
	parts := strings.Split(path, "|")
	if len(parts) < 3 || strings.TrimSpace(parts[0]) == "" {
		return nil, errors.New("yunzhui: bad ranking path")
	}
	form := map[string]string{
		"pn":      strconv.Itoa(page),
		"type_id": strings.TrimSpace(parts[0]),
		"sort":    strings.TrimSpace(parts[2]),
	}
	if area := strings.TrimSpace(parts[1]); area != "" {
		form["area"] = area
	}
	decoded, err := s.call(ctx, host, "/api/new_search/screen_v2", form, false)
	if err != nil {
		return nil, err
	}
	return s.dramas(decoded), nil
}
