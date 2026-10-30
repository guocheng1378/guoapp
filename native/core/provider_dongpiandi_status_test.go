package core

import (
	"fmt"
	"testing"
)

// 真值来自 2026-10-25 真网探针（/v1/catalog/{id}）：
//   - 故纵：update_status=unknown、completed=false、progress="更新至74集"
//   - 仙帝传承：completed=true、progress="更新至4集 / 共80集"（4 个批次覆盖全集 80 集）
//   - 颜不由心：completed=true、progress="全20集"
//   - 电影（女篮5号等）：completed=true、progress="高清"（画质词，非进度）
func TestDongpiandiReleaseStatus(t *testing.T) {
	cases := []struct {
		name      string
		status    string
		completed bool
		progress  string
		want      string
	}{
		{"连载短剧按进度文案判连载", "unknown", false, "更新至74集", "ongoing"},
		{"批次短剧以 update_status 为准", "completed", true, "更新至4集 / 共80集", "finished"},
		{"全N集判完结", "", true, "全20集", "finished"},
		{"电影画质词不判连载", "completed", true, "高清", "finished"},
		{"站点直接给 ongoing", "ongoing", false, "", "ongoing"},
		{"无状态无进度文案保持未知", "", false, "高清", "unknown"},
		{"已完结标记判完结", "", true, "", "finished"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := dongpiandiReleaseStatus(c.status, c.completed, c.progress); got != c.want {
				t.Fatalf("dongpiandiReleaseStatus(%q,%v,%q)=%q 期望 %q", c.status, c.completed, c.progress, got, c.want)
			}
		})
	}
}

// 嫁金钗真值（2026-10-25 原始 JSON）：31 条章节 = 17 正片（e-0001..e-0017，
// episode_track="main"）+ 3 陪看（part-*，「陪看1/2/3」）+ 11 彩蛋
// （special-easter-egg-*，「第N集彩蛋」），后 14 条 track 全是 "extras"；
// 站点 total/episode_count 都把这 14 条附加内容算成了集数。
func dongpiandiJiajinchaiEpisodes() []dongpiandiEpisode {
	eps := make([]dongpiandiEpisode, 0, 31)
	for i := 1; i <= 17; i++ {
		eps = append(eps, dongpiandiEpisode{Key: fmt.Sprintf("e-%04d", i), Title: fmt.Sprintf("第%d集", i), EpisodeTrack: "main"})
	}
	for i := 1; i <= 3; i++ {
		eps = append(eps, dongpiandiEpisode{Key: "part-4167fa27", Title: fmt.Sprintf("陪看%d", i), EpisodeTrack: "extras"})
	}
	for i := 1; i <= 11; i++ {
		eps = append(eps, dongpiandiEpisode{Key: "special-easter-egg-episode-0001", Title: fmt.Sprintf("第%d集彩蛋", i), EpisodeTrack: "extras"})
	}
	return eps
}

func TestDongpiandiExtraEpisodeCount(t *testing.T) {
	if got := dongpiandiExtraEpisodeCount(dongpiandiJiajinchaiEpisodes()); got != 14 {
		t.Fatalf("彩蛋+陪看=%d 期望 14", got)
	}
	plain := []dongpiandiEpisode{
		{Key: "e-0001", Title: "第1集", EpisodeTrack: "main"},
		{Key: "range-0001-0020", Title: "第1-20集", EpisodeTrack: "main"},
		{Key: "main", Title: "正片", EpisodeTrack: "main"},
	}
	if got := dongpiandiExtraEpisodeCount(plain); got != 0 {
		t.Fatalf("正片被误判为附加=%d", got)
	}
}

// episode_track 是站点自己的类型字段，优先于 key/title 的字面量猜测。
func TestDongpiandiEpisodeIsExtraTrack(t *testing.T) {
	cases := []struct {
		name string
		ep   dongpiandiEpisode
		want bool
	}{
		{"track=extras 判附加", dongpiandiEpisode{Key: "part-4167fa27", Title: "陪看1", EpisodeTrack: "extras"}, true},
		{"track=main 判正片", dongpiandiEpisode{Key: "e-0001", Title: "第1集", EpisodeTrack: "main"}, false},
		{"track 缺失按 key 兜底", dongpiandiEpisode{Key: "special-easter-egg-episode-0001", Title: "第1集彩蛋"}, true},
		{"track 未知按 key 兜底", dongpiandiEpisode{Key: "e-0002", Title: "第2集", EpisodeTrack: "whatever"}, false},
		{"track=extras 即使 key 像正片也判附加", dongpiandiEpisode{Key: "e-0003", Title: "第3集", EpisodeTrack: "extras"}, true},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := dongpiandiEpisodeIsExtra(c.ep); got != c.want {
				t.Fatalf("dongpiandiEpisodeIsExtra(%+v)=%v 期望 %v", c.ep, got, c.want)
			}
		})
	}
}

func TestDongpiandiTrimExtras(t *testing.T) {
	cases := []struct {
		name     string
		total    int
		episodes []dongpiandiEpisode
		want     int
	}{
		{"全集含彩蛋要扣掉", 31, dongpiandiJiajinchaiEpisodes(), 17},
		{"批次型不扣", 80, []dongpiandiEpisode{
			{Key: "range-0001-0020"}, {Key: "range-0021-0040"},
			{Key: "range-0041-0060"}, {Key: "range-0061-0080"},
		}, 80},
		{"无附加内容原样返回", 24, []dongpiandiEpisode{{Key: "e-0001"}, {Key: "e-0002"}}, 24},
		{"分页未取全时不扣", 100, dongpiandiJiajinchaiEpisodes(), 100},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := dongpiandiTrimExtras(c.total, c.episodes); got != c.want {
				t.Fatalf("dongpiandiTrimExtras(%d)=%d 期望 %d", c.total, got, c.want)
			}
		})
	}
}

func TestDongpiandiDisplayEpisodes(t *testing.T) {
	cases := []struct {
		name    string
		batch   int
		total   int
		epCount int
		status  string
		want    int
	}{
		{"批次型取全集而非批次数", 80, 80, 4, "finished", 80},
		{"单集型连载中取已更新集数", 0, 80, 74, "ongoing", 74},
		{"单集型完结取全集", 0, 20, 20, "finished", 20},
		{"单集型连载且无 total", 0, 74, 74, "ongoing", 74},
		{"状态未知沿用全集", 0, 80, 74, "unknown", 80},
		{"已更新集数为零回落全集", 0, 80, 0, "ongoing", 80},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := dongpiandiDisplayEpisodes(c.batch, c.total, c.epCount, c.status); got != c.want {
				t.Fatalf("dongpiandiDisplayEpisodes(%d,%d,%d,%q)=%d 期望 %d", c.batch, c.total, c.epCount, c.status, got, c.want)
			}
		})
	}
}

// 卡片集数必须扣掉彩蛋/陪看（用户 2026-10-26：「集数还是不对，算上了彩蛋的，
// 但网站的集数却正确」）。真值来自真网 /v1/browse/catalog：
//   - 嫁金钗 series：playback_groups=[35 35 35]，remarks「更新至19集」，
//     详情 35 条 = 19 正片 + 16 附加 → 卡片必须写 19
//   - 绯闻计划 short_drama：groups=[87]，remarks「更新至6集」（6 个批次打包
//     87 集）→ 卡片必须写 87，否则「共6集」漏掉 81 集正片
func TestDongpiandiCardEpisodes(t *testing.T) {
	cases := []struct {
		name          string
		kind          string
		groupEpisodes int
		remark        string
		want          int
	}{
		{"剧集彩蛋撑大时以文案正片数为准", "series", 35, "更新至19集", 19},
		{"短剧批次以播放组全集为准", "short_drama", 87, "更新至6集", 87},
		{"短剧小批次也按全集", "short_drama", 4, "更新至1集", 4},
		{"短剧彩蛋撑大仍取正片数", "short_drama", 8, "更新至6集", 6},
		{"短剧播放组不全时以文案为准", "short_drama", 1, "更新至70集", 70},
		{"文案与播放组一致时保留播放组", "anime", 30, "更新至30集", 30},
		{"全N集文案", "series", 24, "全24集", 24},
		{"文案是日期不覆盖集数", "variety", 18, "2023-10-16", 18},
		{"无播放组时用文案", "series", 0, "更新至19集", 19},
		{"无文案时用播放组", "series", 35, "", 35},
		{"文案含共N集时仍取更新进度", "series", 35, "更新至19集 / 共35集", 19},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if got := dongpiandiCardEpisodes(c.kind, c.groupEpisodes, c.remark); got != c.want {
				t.Fatalf("dongpiandiCardEpisodes(%q,%d,%q)=%d 期望 %d", c.kind, c.groupEpisodes, c.remark, got, c.want)
			}
		})
	}
}

// 卡片端到端：嫁金钗封面必须是「更新至19集」而不是「更新至35集」。
func TestDongpiandiCardDramaTrimsExtras(t *testing.T) {
	drama := dongpiandiDramaFromCard(dongpiandiCatalogCard{
		ID:             "av_5dhMc",
		Title:          "嫁金钗",
		ContentKind:    "series",
		Remark:         "更新至19集",
		PlaybackGroups: []dongpiandiPlaybackGroup{{ID: "a", EpisodeCount: 35}},
	})
	if drama.EpisodeCount != 19 || drama.TotalEpisode != 19 {
		t.Fatalf("封面集数应为 19（正片），得到 EpisodeCount=%d TotalEpisode=%d", drama.EpisodeCount, drama.TotalEpisode)
	}
	if drama.ReleaseStatus != "ongoing" {
		t.Fatalf("连载状态应为 ongoing，得到 %q", drama.ReleaseStatus)
	}
	// 批次型短剧不受影响。
	batch := dongpiandiDramaFromCard(dongpiandiCatalogCard{
		ID: "av_b", Title: "绯闻计划", ContentKind: "short_drama",
		Remark: "更新至6集", PlaybackGroups: []dongpiandiPlaybackGroup{{ID: "a", EpisodeCount: 87}},
	})
	if batch.EpisodeCount != 87 {
		t.Fatalf("批次短剧封面集数应为 87，得到 %d", batch.EpisodeCount)
	}
}

// 「同主演推荐」的第一级数据源：目录卡片的 Actors 必须映射进 Drama。
func TestDongpiandiCardActorsMapped(t *testing.T) {
	drama := dongpiandiDramaFromCard(dongpiandiCatalogCard{
		ID: "av_a", Title: "主演映射", ContentKind: "short_drama",
		Actors: []string{"陆之屿", "白桃"},
	})
	if len(drama.Actors) != 2 || drama.Actors[0] != "陆之屿" {
		t.Fatalf("card.Actors 应映射进 Drama.Actors: %v", drama.Actors)
	}
}

// 站点 total 已不含附加内容时不能扣过头（飞狗MOCO 真值：30 正片 + 1 彩蛋，
// total_episode_count=30，扣完会变成 29）。
func TestDongpiandiTrimExtrasKeepsMainCount(t *testing.T) {
	episodes := make([]dongpiandiEpisode, 0, 31)
	for i := 1; i <= 30; i++ {
		episodes = append(episodes, dongpiandiEpisode{
			Key: fmt.Sprintf("e-%04d", i), Title: fmt.Sprintf("第%d集", i), EpisodeTrack: "main",
		})
	}
	episodes = append(episodes, dongpiandiEpisode{Key: "special-easter-egg-x", Title: "第1集彩蛋", EpisodeTrack: "extras"})
	if got := dongpiandiTrimExtras(30, episodes); got != 30 {
		t.Fatalf("total 已不含附加内容时不应扣成 29，得到 %d", got)
	}
	// 同时验证真正含进 total 的场景仍然会扣。
	if got := dongpiandiTrimExtras(31, episodes); got != 30 {
		t.Fatalf("total=31（含彩蛋）应扣成 30，得到 %d", got)
	}
}
