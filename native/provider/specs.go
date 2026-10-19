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

	// 成人源（CategoryAdult，maccms 采集站，Dart 侧 isRestricted 默认关闭）。
	// 2026-10-19 探针剔除 7 个死源：maodou/naixx/shayu/jingpin（后端无响应）、
	// lajiao/xiangjiao（整站超时）、xibao（TLS 证书无效）。
	SourceZY155   = "zy155"
	SourceYutu    = "yutu"
	SourceFanhao  = "fanhao"
	SourceLsbzy   = "lsbzy"
	SourceHsck    = "hsck"
	SourceDanaizi = "danaizi"
	SourceJkun    = "jkun"
	SourceLebo    = "lebo"
	SourceSenlin  = "senlin"
	SourceDoudou  = "doudou"
	SourceDidi    = "didi"
	SourceHeiliao = "heiliao"
	SourceTaohua  = "taohua"
	SourceSouav   = "souav"
	SourceCkzy    = "ckzy"
	SourceAosika  = "aosika"
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
	// ---- 成人源（CategoryAdult，均为 maccms_api 采集站；受限名单见 models.dart）----
	{
		spec:    Spec{ID: SourceZY155, Name: "155", Base: "https://155api.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"zy155", "155", "155api.com", "155zy2.com"},
		hosts:   []string{"155api.com", "155zy2.com"},
	},
	{
		spec:    Spec{ID: SourceYutu, Name: "玉兔", Base: "https://apiyutu.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yutu", "apiyutu.com"},
		hosts:   []string{"apiyutu.com"},
	},
	{
		spec:    Spec{ID: SourceFanhao, Name: "番号", Base: "http://fhapi9.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"fanhao", "fhapi9.com"},
		hosts:   []string{"fhapi9.com"},
	},
	{
		spec:    Spec{ID: SourceLsbzy, Name: "老色逼", Base: "https://apilsbzy1.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"lsbzy", "apilsbzy1.com"},
		hosts:   []string{"apilsbzy1.com"},
	},
	{
		spec:    Spec{ID: SourceHsck, Name: "黄色仓库", Base: "https://hsckzy.xyz", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"hsck", "hsckzy.xyz"},
		hosts:   []string{"hsckzy.xyz"},
	},
	{
		spec:    Spec{ID: SourceDanaizi, Name: "大奶子", Base: "https://apidanaizi.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"danaizi", "apidanaizi.com"},
		hosts:   []string{"apidanaizi.com"},
	},
	{
		spec:    Spec{ID: SourceJkun, Name: "jkun", Base: "https://jkunzyapi.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"jkun", "jkunzyapi.com"},
		hosts:   []string{"jkunzyapi.com"},
	},
	{
		spec:    Spec{ID: SourceLebo, Name: "乐播", Base: "https://lbapi9.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"lebo", "lbapi9.com"},
		hosts:   []string{"lbapi9.com"},
	},
	{
		spec:    Spec{ID: SourceSenlin, Name: "森林", Base: "https://beiyong.slapibf.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"senlin", "slapibf.com", "beiyong.slapibf.com"},
		hosts:   []string{"beiyong.slapibf.com", "slapibf.com"},
	},
	{
		spec:    Spec{ID: SourceDoudou, Name: "豆豆", Base: "https://api.douapi.cc", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"doudou", "doudouzy.com", "api.douapi.cc"},
		hosts:   []string{"api.douapi.cc", "doudouzy.com"},
	},
	{
		spec:    Spec{ID: SourceDidi, Name: "滴滴", Base: "https://api.ddapi.cc", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"didi", "didizy.com", "api.ddapi.cc"},
		hosts:   []string{"api.ddapi.cc", "didizy.com"},
	},
	{
		spec:    Spec{ID: SourceHeiliao, Name: "黑料", Base: "https://www.heiliaozyapi.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"heiliao", "heiliaozy.cc", "heiliaozyapi.com"},
		hosts:   []string{"www.heiliaozyapi.com", "heiliaozyapi.com", "heiliaozy.cc"},
	},
	{
		spec:    Spec{ID: SourceTaohua, Name: "桃花", Base: "https://thzy1.me", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"taohua", "thzy1.me", "thzy8.me"},
		hosts:   []string{"thzy1.me", "thzy8.me"},
	},
	{
		spec:    Spec{ID: SourceSouav, Name: "souav", Base: "https://api.souavzyw.net", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"souav", "souavzyw.com", "api.souavzyw.net"},
		hosts:   []string{"api.souavzyw.net", "souavzyw.com"},
	},
	{
		spec:    Spec{ID: SourceCkzy, Name: "CK", Base: "https://ckzy.me", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Paged: true, RequiresAllSources: true},
		aliases: []string{"ckzy", "ckzy.me"},
		hosts:   []string{"ckzy.me"},
	},
	{
		spec:    Spec{ID: SourceAosika, Name: "奥斯卡", Base: "https://aosikazy.com", Kind: "maccms_api", Category: CategoryAdult, Family: FamilyDuanju, Paged: true, RequiresAllSources: true},
		aliases: []string{"aosika", "aosikazy.com"},
		hosts:   []string{"aosikazy.com"},
	},
}
