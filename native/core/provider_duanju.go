package core

import (
	"duanjuapp/native/provider"
	"net/url"
	"strings"
)

const (
	sourceYaguo            = provider.SourceYaguo
	sourceMaoguo           = provider.SourceMaoguo
	sourceFanguo           = provider.SourceFanguo
	sourceHeguo            = provider.SourceHeguo
	sourceXingguo          = provider.SourceXingguo
	sourceHuaguo           = provider.SourceHuaguo
	sourceWangguo          = provider.SourceWangguo
	sourceFaguo            = provider.SourceFaguo
	sourceWuguo            = provider.SourceWuguo
	sourceYingshigongchang = provider.SourceYingshigongchang
	sourceShandian         = provider.SourceShandian
	sourceHongniu          = provider.SourceHongniu
	source360zy            = provider.Source360ZY
	sourceModu             = provider.SourceModu
	sourceDytt             = provider.SourceDytt
	sourceNiuniu           = provider.SourceNiuniuZY
	sourceWsyzy            = provider.SourceWsyzy
	sourceSorani           = provider.SourceSorani
	sourceDongpiandi       = provider.SourceDongpiandi

	duanjuMaxBodyBytes = provider.MaxBodyBytes
	duanjuUserAgent    = provider.UserAgent
)

var (
	yaguoBaseURL   = "https://app.whjzjx.cn"
	yaguoLoginURL  = "https://u.shytkjgs.com/user/v1/account/login"
	maoguoBaseURL  = "https://api-store.qmplaylet.com"
	maoguoReadURL  = "https://api-read.qmplaylet.com"
	fanguoBaseURL  = "https://xifan-api-cn.youlishipin.com"
	heguoBaseURL   = "https://www.kuaikaw.cn"
	xingguoBaseURL = "http://read.api.duodutek.com"
	huaguoBaseURL  = "https://www.zywest263.com"
	wangguoBaseURL = "https://www.duanju2.com"
	faguoBaseURL   = "https://www.xzyx168.com"
	wuguoBaseURL   = "https://www.duanju55.com"

	yingshigongchangBaseURL = "http://cj.lziapi.com"
	shandianBaseURL         = "http://sdzyapi.com"
	hongniuBaseURL          = "https://www.hongniuzy2.com"
	source360zyBaseURL      = "https://360zy.com"
	moduBaseURL             = "https://caiji.moduapi.cc"
	dyttBaseURL             = "http://caiji.dyttzyapi.com"
	niuniuzyBaseURL         = "http://api.niuniuzy.me"
	wsyzyBaseURL            = "https://api.wsyzy.net"
	soraniBaseURL           = "https://www.sorani.net"
)

type duanjuSourceSpec = provider.Spec

func duanjuPlainText(raw string) string {
	return provider.PlainText(raw)
}

func isDuanjuProviderSource(source string) bool {
	return provider.DuanjuSource(source)
}

func duanjuSourceSpecFor(source string) (duanjuSourceSpec, bool) {
	return provider.SpecOf(source)
}

func duanjuSourceName(source string) string {
	if spec, found := provider.SpecOf(source); found && spec.Name != "" {
		return spec.Name
	}
	return canonicalProviderSource(source)
}

func (d *Downloader) duanjuBaseURL(source string) string {
	spec, found := duanjuSourceSpecFor(source)
	if !found {
		return ""
	}
	if configured := d.providerHosts[canonicalProviderSource(source)]; configured != "" {
		return strings.TrimRight(configured, "/")
	}
	return strings.TrimRight(spec.Base, "/")
}

func duanjuSourceForHost(host string) string {
	return provider.ForHost(host)
}

func validDuanjuCategory(source, category string) bool {
	if category == "" {
		return true
	}
	if len(category) > 128 || strings.ContainsAny(category, "|/\\\x00\r\n") {
		return false
	}
	switch canonicalProviderSource(source) {
	case sourceHeguo, sourceXingguo, sourceYaguo, sourceMaoguo:
		return webProviderNumericID.MatchString(strings.SplitN(category, "-", 2)[0])
	case sourceFanguo:
		return true
	default:
		return true
	}
}

type duanjuCategory struct {
	ID   string
	Name string
}

var duanjuStaticCategories = map[string][]duanjuCategory{
	sourceYaguo: {
		{ID: "1", Name: "剧场"},
		{ID: "9", Name: "榜单"},
	},
	sourceMaoguo: {
		{ID: "0", Name: "推荐"},
	},
	sourceFanguo: {
		{ID: "都市", Name: "都市"},
		{ID: "甜宠", Name: "甜宠"},
		{ID: "逆袭", Name: "逆袭"},
		{ID: "战神", Name: "战神"},
		{ID: "古装", Name: "古装"},
		{ID: "穿越", Name: "穿越"},
		{ID: "萌宝", Name: "萌宝"},
	},
	sourceXingguo: {
		{ID: "1287", Name: "推荐一"},
		{ID: "1288", Name: "推荐二"},
		{ID: "1289", Name: "推荐三"},
		{ID: "1290", Name: "推荐四"},
		{ID: "1291", Name: "推荐五"},
	},
	sourceHeguo: {
		{ID: "462", Name: "甜宠"},
		{ID: "1102", Name: "古装仙侠"},
		{ID: "1145", Name: "现代言情"},
		{ID: "1170", Name: "青春"},
		{ID: "585", Name: "豪门恩怨"},
		{ID: "417-464", Name: "逆袭"},
		{ID: "439-465", Name: "重生"},
		{ID: "1159", Name: "系统"},
		{ID: "1147", Name: "总裁"},
		{ID: "943", Name: "职场商战"},
	},
	sourceHuaguo: {
		{ID: "27", Name: "短剧"},
	},
}

func duanjuQueryEscape(value string) string { return url.QueryEscape(strings.TrimSpace(value)) }

func duanjuAbsolute(base, reference string) string {
	return provider.Absolute(base, reference)
}
