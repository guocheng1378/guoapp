package provider

const (
	SourceHongguo    = "hongguo"
	SourceHuangdou   = "huangdou"
	SourceHuangju    = "huangju"
	SourceHuangguoAI = "huangguoai"
	SourceCloudFront = "cloudfront"
	SourceYeguo      = "yeguo"

	SourceYaguo            = "yaguo"
	SourceMaoguo           = "maoguo"
	SourceFanguo           = "fanguo"
	SourceHeguo            = "heguo"
	SourceXingguo          = "xingguo"
	SourceHuaguo           = "huaguo"
	SourceWangguo          = "wangguo"
	SourceFaguo            = "faguo"
	SourceWuguo            = "wuguo"
	SourceYingshigongchang = "yingshigongchang"
	Source360ZY            = "360zy"
	SourceModu             = "modu"
	SourceDytt             = "dytt"
	SourceShandian         = "shandian"
	SourceHongniu          = "hongniu"
	SourceNiuniuZY         = "niuniuzy"
	SourceWsyzy            = "wsyzy"
	SourceSorani           = "sorani"
	SourceDongpiandi       = "dongpiandi"
)

type sourceEntry struct {
	spec    Spec
	aliases []string
	hosts   []string
}

var sourceEntries = []sourceEntry{
	{
		spec:    Spec{ID: SourceHongguo, Name: "红果", Base: "https://hongguoduanju.com", Kind: "app", Category: CategoryShortDrama, Family: FamilyHuangguo},
		aliases: []string{"hongguo", "hongguoduanju.com"},
		hosts:   []string{"hongguoduanju.com", "www.hongguoduanju.com"},
	},
	{
		spec:    Spec{ID: SourceHuangdou, Name: "黄豆", Base: "https://seiopcc.icu", Kind: "api", Category: CategoryShortDrama, Family: FamilyHuangguo, RequiresAllSources: true},
		aliases: []string{"huangdou", "tideember.cc", "xqjurgek.top"},
		hosts:   []string{"tideember.cc", "xqjurgek.top"},
	},
	{
		spec:    Spec{ID: SourceHuangju, Name: "剧果", Base: "https://huangju.net", Kind: "api", Category: CategoryShortDrama, Family: FamilyHuangguo, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"huangju", "huangju.net", "api.huangju.net"},
		hosts:   []string{"huangju.net", "www.huangju.net", "api.huangju.net"},
	},
	{
		spec:    Spec{ID: SourceHuangguoAI, Name: "黄果 AI", Base: "https://huangguoai.com", Kind: "web", Category: CategoryShortDrama, Family: FamilyHuangguo, Browser: true, RequiresAllSources: true},
		aliases: []string{"huangguo", "huangguoai", "huangguoai.com"},
		hosts:   []string{"huangguoai.com", ".ediayikma.cc", ".agdkczeyx.cc"},
	},
	{
		spec:    Spec{ID: SourceCloudFront, Name: "黄果旧版", Base: "https://d2pypzndaqisk.cloudfront.net", Kind: "api", Category: CategoryVideo, Family: FamilyHuangguo, RequiresAllSources: true},
		aliases: []string{"cloudfront"},
	},
	{
		spec:    Spec{ID: SourceYeguo, Name: "野果", Base: "https://www.yeguodj.com", Kind: "api", Category: CategoryShortDrama, Family: FamilyHuangguo, Browser: true, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yeguo", "ygdj7.com", "www.ygdj7.com", "analyze.buxefaex.cc", "delta.ygrwdsgt.cc", "yeguodj.com", "www.yeguodj.com", "ocdjlxow.cc", "www.ocdjlxow.cc"},
		hosts:   []string{"ygdj7.com", "www.ygdj7.com", "analyze.buxefaex.cc", "delta.ygrwdsgt.cc", "yeguodj.com", "www.yeguodj.com", ".buxefaex.cc", ".fzchosdi.cc", "ocdjlxow.cc", "www.ocdjlxow.cc", ".ocdjlxow.cc"},
	},
	{
		spec:    Spec{ID: SourceYaguo, Name: "芽果", Base: "https://app.whjzjx.cn", Kind: "api", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yaguo", "xingya", "星芽", "app.whjzjx.cn"},
		hosts:   []string{"app.whjzjx.cn", "u.shytkjgs.com"},
	},
	{
		spec:    Spec{ID: SourceMaoguo, Name: "猫果", Base: "https://api-store.qmplaylet.com", Kind: "api", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, RequiresAllSources: true},
		aliases: []string{"maoguo", "qimao", "七猫", "api-store.qmplaylet.com"},
		hosts:   []string{"api-store.qmplaylet.com", "api-read.qmplaylet.com"},
	},
	{
		spec:    Spec{ID: SourceFanguo, Name: "饭果", Base: "https://xifan-api-cn.youlishipin.com", Kind: "api", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, RequiresAllSources: true},
		aliases: []string{"fanguo", "xifan", "西饭", "xifan-api-cn.youlishipin.com"},
		hosts:   []string{"xifan-api-cn.youlishipin.com"},
	},
	{
		spec:    Spec{ID: SourceHeguo, Name: "河果", Base: "https://www.kuaikaw.cn", Kind: "web", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, RequiresAllSources: true},
		aliases: []string{"heguo", "hema", "河马", "www.kuaikaw.cn", "kuaikaw.cn"},
		hosts:   []string{"www.kuaikaw.cn", "kuaikaw.cn"},
	},
	{
		spec:    Spec{ID: SourceXingguo, Name: "星果", Base: "http://read.api.duodutek.com", Kind: "api", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, RequiresAllSources: true},
		aliases: []string{"xingguo", "xingxing", "星星", "read.api.duodutek.com"},
		hosts:   []string{"read.api.duodutek.com"},
	},
	{
		spec:    Spec{ID: SourceHuaguo, Name: "花生", Base: "https://www.zywest263.com", Kind: "maccms", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"huaguo", "huasheng", "花生", "www.zywest263.com"},
		hosts:   []string{"www.zywest263.com", "zywest263.com"},
	},
	{
		spec:    Spec{ID: SourceWangguo, Name: "短剧网站", Base: "https://www.duanju2.com", Kind: "maccms", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"wangguo", "duanjuwangzhan", "短剧网站", "www.duanju2.com"},
		hosts:   []string{"www.duanju2.com", "duanju2.com"},
	},
	{
		spec:    Spec{ID: SourceFaguo, Name: "168 影院", Base: "https://www.xzyx168.com", Kind: "maccms", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"faguo", "168", "xzyx168", "www.xzyx168.com"},
		hosts:   []string{"www.xzyx168.com", "xzyx168.com"},
	},
	{
		spec:    Spec{ID: SourceWuguo, Name: "五五", Base: "https://www.duanju55.com", Kind: "maccms", Category: CategoryShortDrama, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"wuguo", "wuwu", "五五", "www.duanju55.com"},
		hosts:   []string{"www.duanju55.com", "duanju55.com"},
	},
	{
		spec:    Spec{ID: SourceYingshigongchang, Name: "影视工厂", Base: "http://cj.lziapi.com", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yingshigongchang", "影视工厂", "cj.lziapi.com"},
		hosts:   []string{"cj.lziapi.com"},
	},
	{
		spec:    Spec{ID: Source360ZY, Name: "360", Base: "https://360zy.com", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"360zy", "360", "360zy.com"},
		hosts:   []string{"360zy.com", "www.360zy.com"},
	},
	{
		spec:    Spec{ID: SourceModu, Name: "魔都", Base: "https://caiji.moduapi.cc", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"modu", "魔都", "moduapi.cc", "caiji.moduapi.cc"},
		hosts:   []string{"caiji.moduapi.cc", "moduapi.cc"},
	},
	{
		spec:    Spec{ID: SourceDytt, Name: "电影天堂", Base: "http://caiji.dyttzyapi.com", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"dytt", "电影天堂", "dyttzyapi.com", "caiji.dyttzyapi.com"},
		hosts:   []string{"caiji.dyttzyapi.com", "dyttzyapi.com"},
	},
	{
		spec:    Spec{ID: SourceShandian, Name: "闪电", Base: "http://sdzyapi.com", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Paged: true, RequiresAllSources: true},
		aliases: []string{"shandian", "闪电", "sdzyapi.com"},
		hosts:   []string{"sdzyapi.com"},
	},
	{
		spec:    Spec{ID: SourceHongniu, Name: "红牛", Base: "https://www.hongniuzy2.com", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"hongniu", "红牛", "hongniuzy2.com"},
		hosts:   []string{"www.hongniuzy2.com", "hongniuzy2.com"},
	},
	{
		spec:    Spec{ID: SourceNiuniuZY, Name: "牛牛", Base: "http://api.niuniuzy.me", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Paged: true, RequiresAllSources: true},
		aliases: []string{"niuniuzy", "niuniuzy.me", "api.niuniuzy.me"},
		hosts:   []string{"api.niuniuzy.me", "niuniuzy.me"},
	},
	{
		spec:    Spec{ID: SourceWsyzy, Name: "无水印", Base: "https://api.wsyzy.net", Kind: "maccms_api", Category: CategoryVideo, Family: FamilyDuanju, Paged: true, RequiresAllSources: true},
		aliases: []string{"wsyzy", "无水印", "wsyzy.net", "api.wsyzy.net"},
		hosts:   []string{"api.wsyzy.net", "wsyzy.net"},
	},
	{
		spec:    Spec{ID: SourceSorani, Name: "青空", Base: "https://www.sorani.net", Kind: "api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"sorani", "青空", "sorani.net", "www.sorani.net"},
		hosts:   []string{"www.sorani.net", "sorani.net"},
	},
	{
		spec:    Spec{ID: SourceDongpiandi, Name: "真果·鉴", Base: "https://dongpiandi.ai", Kind: "api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"dongpiandi", "真果·鉴", "dongpiandi.ai"},
		hosts:   []string{"dongpiandi.ai", "www.dongpiandi.ai"},
	},
}
