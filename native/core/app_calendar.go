package core

import (
	"context"
	"fmt"
)

// nativeHomeCalendar 输出站点追剧周表（App 内的「本周追剧」）：按天分组，
// 每天一组条目；站点没给星期标签时本地按日期推。
func (engine *nativeEngine) nativeHomeCalendar(ctx context.Context, input nativeInput) (map[string]any, error) {
	days, err := cachedDongpiandiCalendar(ctx, input.Force)
	if err != nil {
		return nil, err
	}
	out := make([]map[string]any, 0, len(days))
	for _, day := range days {
		items := make([]nativeDrama, 0, len(day.Items))
		for _, drama := range day.Items {
			normalized := nativeNormalize(drama)
			if normalized.Title == "" || normalized.ID == "" {
				continue
			}
			items = append(items, normalized)
		}
		if len(items) == 0 {
			continue
		}
		out = append(out, map[string]any{
			"date":  day.Date,
			"label": day.Label,
			"items": items,
		})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("本周还没有可追的更新")
	}
	return map[string]any{"days": out}, nil
}
