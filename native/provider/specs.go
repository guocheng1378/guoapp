package provider

const (
	SourceHongguo    = "hongguo"
	SourceHuangdou   = "huangdou"
	SourceHuangju    = "huangju"
	SourceHuangguoAI = "huangguoai"
	SourceCloudFront = "cloudfront"
	SourceYeguo      = "yeguo"
	// 黑桃（heitaodj.com）：上游 04c431c 新增的网页短剧源，归入黄果类。
	SourceHeitao = "heitao"

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
	SourceDongpiandi       = "dongpiandi"

	// 云追视频（yunzhui）：影视聚合源，带日榜/总榜。游客身份 + AES-256-CBC
	// 响应解密 + MD5 签名；域名池多域名轮转。仅真果鉴变体（RequiresAllSources）。
	SourceYunzhui = "yunzhui"

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

	// 上游（Xanerix/guoapp）移植的内置站源：韩小圈（视频类）、禁果短剧（黄果类）、
	// 笔盒（成人类）。前两者有上游 Go provider 可移植；笔盒上游亦无 provider，仅作
	// 菜单占位（加载会走「暂不支持」分支）。
	SourceHanxiaoquan = "hanxiaoquan"
	SourceJinguoduanju = "jinguoduanju"
	SourceBeabox      = "beabox"
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
		// 2026-11-18：Base 从死域 huangguoai.com 改为活域 www.agdkczeyx.cc。
		// JS 模块的 edgeCall() 经 host.preferredSite()→duanjuBaseURL() 读 spec.Base
		// 作为播放握手域名；旧主站已超时，导致「有目录、点播握手超时」。
		spec:    Spec{ID: SourceHuangguoAI, Name: "黄果 AI", Base: "https://www.agdkczeyx.cc", Kind: "web", Category: CategoryShortDrama, Family: FamilyHuangguo, Browser: true, RequiresAllSources: true},
		aliases: []string{"huangguo", "huangguoai", "huangguoai.com", "huangguoai.io"},
		// 2026-11-08 真网探活：huangguoai.com 主站超时；huangguoai.io、
		// *.agdkczeyx.cc、*.lbvrhyir.cc 的 /api/edge/request 可用。
		// 后缀登记让 provider.ForHost 能识别镜像域，否则镜像候选链不展开。
		hosts: []string{"huangguoai.com", "huangguoai.io", ".ediayikma.cc", ".agdkczeyx.cc", ".lbvrhyir.cc", ".xxbgwypx.cc", ".jxqgmx5ga.cc"},
	},
	{
		spec:    Spec{ID: SourceHeitao, Name: "黑桃", Base: "https://heitaodj.com", Kind: "web", Category: CategoryShortDrama, Family: FamilyHuangguo, Browser: true, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"heitao", "heitaodj.com", "www.heitaodj.com"},
		hosts:   []string{"heitaodj.com", "www.heitaodj.com"},
	},
	// 上游（Xanerix/guoapp）移植：韩小圈（韩剧/韩综，视频类，jennyhow.com）。
	{
		spec:    Spec{ID: SourceHanxiaoquan, Name: "韩小圈", Base: "https://www.jennyhow.com", Kind: "web", Category: CategoryVideo, Family: FamilyHuangguo, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"hanxiaoquan", "韩小圈", "jennyhow.com", "www.jennyhow.com"},
		hosts:   []string{"jennyhow.com", "www.jennyhow.com"},
	},
	// 上游（Xanerix/guoapp）移植：禁果短剧（黄果类短剧，jinguoduanju.app）。
	{
		spec:    Spec{ID: SourceJinguoduanju, Name: "禁果短剧", Base: "https://jinguoduanju.app", Kind: "web", Category: CategoryShortDrama, Family: FamilyHuangguo, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"jinguoduanju", "禁果短剧", "jinguoduanju.app", "jgdj.app"},
		hosts:   []string{"jinguoduanju.app", "www.jinguoduanju.app", "play.jinguoduanju.app", "jgdj.app", "www.jgdj.app"},
	},
	// 笔盒（成人类）。上游无 Go provider；本仓库按线上逆向接入：
	// 发布网关 beabox.cc/bihe198.com/beabox.live 内嵌 __ENC_DOMAINS（secureKey XOR）
	// 给出当前 bh*.top 真实域；API 走 /api/vod/* 且响应为 AES-128-CBC 密文。
	{
		spec:    Spec{ID: SourceBeabox, Name: "笔盒", Base: "https://beabox.cc", Kind: "web", Category: CategoryAdult, Family: FamilyHuangguo, Browser: true, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"beabox", "笔盒", "beabox.cc", "www.beabox.cc", "beabox.live", "bihe198.com", "beabox.net", "www.beabox.net"},
		hosts:   []string{"beabox.cc", "www.beabox.cc", "beabox.live", "bihe198.com", "beabox.net", "www.beabox.net"},
	},
	{
		spec:    Spec{ID: SourceCloudFront, Name: "黄果旧版", Base: "https://d2pypzndaqisk.cloudfront.net", Kind: "api", Category: CategoryVideo, Family: FamilyHuangguo, RequiresAllSources: true},
		aliases: []string{"cloudfront"},
	},
	{
		// 2026-11-14 真网实测：www.yeguodj.com 无 DNS 解析、*.vgbyziuz.cc
		// 全线超时，analyze.buxefaex.cc / delta.ygrwdsgt.cc 仍存活。默认
		// 入口改为存活线路，运行时自发现（provider_yeguo_client.go）不再
		// 从死域名起步。
		spec:    Spec{ID: SourceYeguo, Name: "野果", Base: "https://analyze.buxefaex.cc", Kind: "api", Category: CategoryShortDrama, Family: FamilyHuangguo, Browser: true, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yeguo", "ygdj7.com", "www.ygdj7.com", "attract.vgbyziuz.cc", "as.vgbyziuz.cc", "anyway.vgbyziuz.cc", "analyze.buxefaex.cc", "delta.ygrwdsgt.cc", "yeguodj.com", "www.yeguodj.com", "ocdjlxow.cc", "www.ocdjlxow.cc", "awlaxemk.cc", "vuenadqi.cc"},
		hosts:   []string{"ygdj7.com", "www.ygdj7.com", "attract.vgbyziuz.cc", "analyze.buxefaex.cc", "delta.ygrwdsgt.cc", "yeguodj.com", "www.yeguodj.com", ".buxefaex.cc", ".fzchosdi.cc", ".awlaxemk.cc", ".vuenadqi.cc", ".vgbyziuz.cc", ".ygrwdsgt.cc", "ocdjlxow.cc", "www.ocdjlxow.cc", ".ocdjlxow.cc"},
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
		spec:    Spec{ID: SourceDongpiandi, Name: "真果·鉴", Base: "https://dongpiandi.ai", Kind: "api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"dongpiandi", "真果·鉴", "dongpiandi.ai"},
		hosts:   []string{"dongpiandi.ai", "www.dongpiandi.ai"},
	},
	{
		spec:    Spec{ID: SourceYunzhui, Name: "云追", Base: "https://u.gslock.com/", Kind: "api", Category: CategoryVideo, Family: FamilyDuanju, Searcher: true, Paged: true, RequiresAllSources: true},
		aliases: []string{"yunzhui", "云追", "u.gslock.com"},
		hosts:   []string{"u.gslock.com", "u.alvzz.com", "u.irltk.com", "u.yyxdmn.com", "dyup.ruxiangsuisu.cn", "chw.ycblhs.com"},
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
