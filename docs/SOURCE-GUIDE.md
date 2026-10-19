# 独立站源开发指南

> 适用版本 v0.2.94+101 及以后 · 配套阅读 [DEVELOPMENT.md](DEVELOPMENT.md)（Go 核心编译）· 本文所有代码均摘自现有源包的真实实现（`native/sources/fanguo`、`native/sources/maccmsapi`），可直接照抄改造。

---

## 目录

1. [体系总览](#1-体系总览)
2. [核心概念](#2-核心概念)
3. [五步接入一个新源（API 型）](#3-五步接入一个新源api-型)
4. [进阶模式](#4-进阶模式)
5. [接入机制：兜底适配与门控](#5-接入机制兜底适配与门控)
6. [验证与验收](#6-验证与验收)
7. [FAQ](#7-faq)

---

## 1. 体系总览

站源插件体系分三层：**契约层**定义"一个源要长什么样"，**源包层**每源一个目录各自实现，**接入层**负责把所有源包聚合进二进制。新增源只改源包层 + 一行聚合导入，契约层与核心调度不需要动。

```
guoapp/native/
├── provider/                  # ① 契约层：所有源共同遵守的接口与注册表
│   ├── provider.go            #    Spec 元数据 + 五大能力接口 + Media 结构
│   ├── host.go                #    Host 网络宿主接口（源实现不直接发 HTTP）
│   ├── models.go              #    Drama / Chapter / CatalogCategory / Task 数据模型
│   ├── registry.go            #    注册表：登记、别名、域名归属、门控查询
│   ├── specs.go               #    25 个内置源的静态清单（新源在这里登记）
│   ├── helpers.go             #    取值/截断/错误脱敏等通用辅助
│   ├── webhtml.go             #    网页解析辅助（web / maccms 源用）
│   └── webmedia.go            #    网页媒体嗅探辅助
├── sources/                   # ② 源包层：一个源一个包，互不依赖
│   ├── fanguo/                #    fanguo.go（实现）+ register.go（注册）
│   ├── yaguo/ … maoguo/ …
│   ├── maccmsapi/             #    一包注册 8 个 maccms 资源 API 源
│   ├── maccmsweb/             #    maccms 网页站通用实现
│   └── all/                   # ③ 接入层：all.go 空导入聚合全部源包
│       └── all.go
└── core/                      # Go 核心宿主：桥接 Flutter、消费注册表
    ├── adapter_sources.go     #    空导入 all 包 + 未实现源的兜底适配器
    ├── app_build.go           #    构建旗标 → provider.Configure（ALL_SOURCES 门控）
    └── provider_duanju_dispatch.go  # 按能力旗标（Searcher/Paged）分发调度
```

一次播放请求的完整链路：

```mermaid
flowchart LR
    A[Flutter UI] -->|MethodChannel| B[Go 核心 native/core]
    B -->|SpecOf / Get| C[provider 注册表]
    C -->|能力接口调用| D[native/sources 源包]
    D -->|JSON / Text / MediaPlaylist| E[Host 网络宿主]
    E -->|统一 UA / Referer / 超时| F[(站源服务器)]
```

源包之间零依赖：每个 `native/sources/<id>` 只 import `native/provider`，彼此完全隔离；删除或新增任何一个源包都不影响其他源。

---

## 2. 核心概念

### 2.1 Spec：源的身份证（`provider.Spec`）

每个源在 `native/provider/specs.go` 的 `sourceEntries` 清单里登记一条静态元数据，即使该源还没有任何实现，UI 上也会按这份清单显示站源卡片。

| 字段 | 类型 | 必填 | 说明 |
|---|---|---|---|
| `ID` | `string` | 是 | 全局唯一小写标识（如 `fanguo`）；同文件顶部定义 `SourceFanguo = "fanguo"` 常量 |
| `Name` | `string` | 是 | 展示名（中文，如「饭果」）；`provider.SourceName(id)` 取此值 |
| `Base` | `string` | 是 | 站点基准地址（含 `https://`）；可被运行时 Hosts 配置覆盖 |
| `Kind` | `string` | 建议 | 类型标识：`api`（JSON 接口）/ `web`（网页解析）/ `app`（App 接口）/ `maccms`（maccms 网页站）/ `maccms_api`（maccms 资源 API）；当前仅作归类元数据，不影响调度 |
| `Category` | `Category` | 是 | `shortDrama`（短剧）或 `video`（影视） |
| `Family` | `Family` | 是 | `duanju`（独立源体系）或 `huangguo`（黄果内置体系）；**新源一律 `FamilyDuanju`** |
| `Searcher` | `bool` | 否 | `true` = 参与全局聚合搜索 |
| `Paged` | `bool` | 否 | `true` = 目录按分页加载（配合 `CatalogPage` 返回的 hasMore） |
| `Browser` | `bool` | 否 | `true` = 纳入网页嗅探清单（`native/core/network_browser.go`），适合播放直链需要 WebView 嗅探的站 |
| `RequiresAllSources` | `bool` | 否 | `true` = 仅「全量版」（`ALL_SOURCES=true` 构建，即真果·鉴）可用；精简版（红果鉴）中该源显示「当前版本不包含此站源」 |
| `Agent` / `Referer` | `string` | 否 | 访问该站的默认 UA / Referer |

> 注册表守恒测试（`provider/registry_test.go: TestEveryRegisteredSourceOwnsIdentity`）强制校验：ID 非空且唯一、`Name` 与 `Base` 必填、`Category` 与 `Family` 必填。漏填任何一项 `go test` 直接失败。

### 2.2 五大能力接口：按需实现

所有接口都内嵌 `Provider`（即只需实现 `Spec() Spec`）。Go 是隐式接口——给 `Source` 结构体写上方法即视为实现，**没有的能力就不要写**，注册表与调度层会按能力旗标与接口断言自行判断。

| 接口 | 方法签名 | 触发场景 | 未实现时的表现 |
|---|---|---|---|
| `Cataloguer` | `Categories(ctx, host) ([]CatalogCategory, error)` | 打开源的目录页时取分类 | 目录页报「该站源暂未提供分类」 |
| | `CatalogPage(ctx, host, page, category, query) ([]Drama, bool, error)` | 目录翻页；返回值第二项为 hasMore | 目录页报「该站源暂未接入目录」 |
| `CatalogSorter`（可选） | `CatalogPageSorted(ctx, host, page, category, sort) ([]Drama, bool, error)` | 客户端选了热度/最新等排序且源站支持时，代替 `CatalogPage` 发起带排序参数的请求（sort ∈ heat/views/date） | 回退 `CatalogPage` + 客户端本地排序 |
| `Detailer` | `Detail(ctx, host, sourceID) (Drama, []Chapter, error)` | 进入剧详情、开始播放/下载前取集数 | 详情页报「该站源暂未接入详情」 |
| `Searcher` | `Search(ctx, host, query) ([]Drama, error)` | 聚合搜索（需 `Spec.Searcher=true` 才会被调用） | 该源不参与聚合搜索 |
| `Prober` | `Probe(ctx, host) (string, error)` | 源健康探测 | 跳过探测 |
| `MediaResolver` | `ResolveMedia(ctx, host, task Task) (Media, error)` | 播放/下载前把集数二次解析为可播直链（详见 §4.3） | 直接使用 `Chapter.VideoURL` |

最小可用源 = `Cataloguer + Detailer`；搜索聚合再加 `Searcher`；直链需要解密/跳转的站再补 `MediaResolver`；源站接口原生支持按热度/最新排序时再实现 `CatalogSorter`，让「热度」排序真正作用在全量数据上（而非客户端已加载的分页片段）。同时注意：`Drama.Heat`（热度文本，如 `12.3万次播放`）、`Views`（播放量文本）、`OnlineDate`（`2006-01-02` 系格式）、`ReleaseStatus`（`finished`/`ongoing`，可由集数或「已完结」类备注推断，见 `provider.ReleaseStatus`）四个字段填得越全，客户端排序与完结筛选就越准——字段缺失时对应排序项会在 UI 置灰禁用，避免假排序。

### 2.3 Host：唯一的网络出口

源实现**不直接 `http.Get`**。所有请求经 `Host` 走统一出口（UA / Referer / 超时 / 重定向 / 域名归属都由宿主层处理）：

```go
type Host interface {
    JSON(ctx context.Context, request Request) (map[string]any, error)
    Text(ctx context.Context, request Request) (string, error)
    Bytes(ctx context.Context, request Request) ([]byte, error)
    BaseURL(source string) string // 该源当前生效的 Base（含运行时覆盖）
    MediaPlaylist(ctx context.Context, address, referer string) (playlist, finalURL string, err error)
}

type Request struct {
    Source  string            // 固定填 s.spec.ID，用于日志与域名归属
    Method  string            // 默认 GET
    Address string            // 完整 URL
    Referer string
    Agent   string
    Headers map[string]string
    Body    []byte
    Form    map[string][]string
    Timeout time.Duration
}
```

约定：`Address` 必须是完整地址，基准域名一律通过 `host.BaseURL(s.spec.ID)` 获取（回退 `s.spec.Base`），这样站点换域名时无需改代码（见 §5.3）。

### 2.4 注册表速查（`provider` 包函数）

| 函数 | 用途 |
|---|---|
| `Register(p Provider)` | 把实现注册进注册表，**覆盖**该 ID 的静态占位（新源接入的核心调用） |
| `SpecOf(id) (Spec, bool)` / `Get(id)` | 查元数据 / 查实现 |
| `All() []Provider` | 全部已登记源（含未实现的静态占位），按 ID 排序 |
| `Canonical(src) string` | 把别名/历史标识归一为标准 ID |
| `ForHost(host) string` | 按域名反查源（`hosts` 精确匹配 + `.suffix` 通配） |
| `Available(src) bool` | 该源在当前构建变体下是否可用（门控） |
| `Configure(Config{AllSources, Hosts})` | 注入构建门控与运行时域名覆盖 |
| `KnownSource / DuanjuSource / AllSourcesEnabled / ConfiguredHost` | 判定辅助 |

`aliases` 与 `hosts` 的分工：**aliases** 是「这个源可能被叫作什么」（历史数据、云端同步里的旧标识、中文名），用于 `Canonical` 归一；**hosts** 是「这个源拥有哪些域名」，用于把媒体直链、网页地址反查归属到源（`ForHost`）。清单条目里两者都建议写全：ID 本身、中文名、裸域与常见子域；不固定的临时域名可写 `.xxx.cc` 形式做后缀通配。

### 2.5 数据模型与构造辅助

```go
// 目录分类
type CatalogCategory struct{ ID, Name string }

// 剧（关键字段节选，完整定义见 provider/models.go）
type Drama struct {
    ID        string // 必须 provider.DramaID(source, sourceID) 生成，全局唯一
    Source    string // s.spec.ID
    SourceID  string // 源内唯一键；Detail 收到的 sourceID 与它一致
    Title     string // 展示标题（Name 为兼容别名）
    Intro     string // 简介
    Cover     any    // 封面直链，用 provider.Cover(base, node, "cover", "pic", ...) 从接口节点提取
    EpisodeCount any // 总集数（any 类型，接口给什么放什么）
    Tags      []string
    // ...
}

// 集（章）
type Chapter struct {
    ID             string          // provider.ChapterID 生成，通常直接用 NewChapter
    Source         string
    Title          string
    VideoURL       string          // 可播直链（m3u8/mp4）；需要二次解析的站留给 MediaResolver
    CurrentEpisode json.RawMessage // 集数（RawEpisode(n) 生成）
    PageURL        string          // 网页源可填播放页地址
    Referer        string
}
```

常用辅助（`provider` 包内，全部源包共用）：

| 函数 | 用途 |
|---|---|
| `DramaID(source, sourceID)` / `ChapterID(...)` | 生成全局唯一 ID |
| `NewChapter(source, sourceID, number, title, videoURL, pageURL, referer)` | 一行构造一集（自动补集数标题、生成 ID） |
| `SortChapters(chapters)` | 按集数排序 |
| `Cover(base, node, keys...)` / `FindString(node, keys...)` / `FindInt` / `FindMap` / `FindList` / `StringList` / `CSV` | 从 `map[string]any` 接口节点按候选键取值（接口字段名漂移时加一个候选键即可） |
| `NativeText` / `FirstNonEmpty` / `Truncate` | 文本清洗 |
| `PublicError(err)` | 对外报错前脱敏（不要把内部地址/密钥透给 UI） |

---

## 3. 五步接入一个新源（API 型）

以虚构的 JSON 接口站 `demo`（域名 `api.demo-site.com`，有固定分类、分页目录、搜索、详情直链集数）为例，完整走一遍。全程只新建 2 个文件 + 改 2 个文件，不碰 Flutter、不碰 core。

### 第 1 步：在静态清单登记源（`native/provider/specs.go`）

```go
// ① 顶部 ID 常量区追加
const (
    // ...
    SourceDemo = "demo"
)

// ② sourceEntries 列表末尾追加条目
{
    spec: Spec{
        ID:                 SourceDemo,
        Name:               "示例源",
        Base:               "https://api.demo-site.com",
        Kind:               "api",
        Category:           CategoryShortDrama,   // 影视站用 CategoryVideo
        Family:             FamilyDuanju,         // 新源固定 duanju
        Searcher:           true,                 // 参与聚合搜索
        Paged:              true,                 // 目录分页
        RequiresAllSources: true,                 // 仅全量版提供；默认单源版收录则填 false
    },
    aliases: []string{"demo", "示例源", "api.demo-site.com"},
    hosts:   []string{"api.demo-site.com"},
},
```

要点：
- `aliases` 第一个写 ID 本身，随后是中文名与域名，供历史数据归一；
- `hosts` 写站点**所有可能出现在媒体直链里的域名**（含裸域与子域），播放器靠 `ForHost` 把直链归属到源；
- 改完先跑 `go test ./provider/`，守恒测试会替你检查清单合法性。

### 第 2 步：创建源包骨架（`native/sources/demo/demo.go`）

```go
package demo

import (
    "context"
    "net/url"  // 目录/搜索拼接地址用
    "strconv"  // 页码等数字参数

    "duanjuapp/native/provider"
)

type Source struct {
    spec provider.Spec
}

func New(spec provider.Spec) *Source { return &Source{spec: spec} }

func (s *Source) Spec() provider.Spec { return s.spec }

// base：运行时域名覆盖优先，静态清单兜底（照抄 fanguo.go 的惯例）
func (s *Source) base(host provider.Host) string {
    if host != nil {
        if base := host.BaseURL(s.spec.ID); base != "" {
            return base
        }
    }
    return s.spec.Base
}
```

### 第 3 步：实现需要的能力接口

目录（固定分类直接返回常量；分类动态的站再请求接口）：

```go
func (s *Source) Categories(ctx context.Context, host provider.Host) ([]provider.CatalogCategory, error) {
    return []provider.CatalogCategory{
        {ID: "都市", Name: "都市"},
        {ID: "甜宠", Name: "甜宠"},
        {ID: "战神", Name: "战神"},
    }, nil
}
```

目录分页（`Paged: true` 时 UI 依赖返回的 hasMore 决定是否继续翻页）：

```go
func (s *Source) CatalogPage(ctx context.Context, host provider.Host, page int, category, query string) ([]provider.Drama, bool, error) {
    base := s.base(host)
    address := base + "/api/list?cat=" + url.QueryEscape(category) + "&page=" + strconv.Itoa(page)
    response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address, Referer: base + "/"})
    if err != nil {
        return nil, false, err
    }
    var dramas []provider.Drama
    for _, item := range provider.FindList(response, "data", "list") {
        node, ok := item.(map[string]any)
        if !ok {
            continue
        }
        sourceID := provider.FindString(node, "id", "bookId")
        if sourceID == "" {
            continue
        }
        dramas = append(dramas, provider.Drama{
            ID:       provider.DramaID(s.spec.ID, sourceID),
            Source:   s.spec.ID,
            SourceID: sourceID,
            Title:    provider.FindString(node, "title", "name"),
            Intro:    provider.FindString(node, "desc", "intro"),
            Cover:    provider.Cover(base, node, "cover", "coverUrl", "pic"),
            Tags:     provider.StringList(node["tags"]),
        })
    }
    return dramas, len(dramas) >= 20, nil // hasMore：按站点单页容量判断
}
```

聚合搜索（`Searcher: true` 才会被调度层调用）：

```go
func (s *Source) Search(ctx context.Context, host provider.Host, query string) ([]provider.Drama, error) {
    address := s.base(host) + "/api/search?keyword=" + url.QueryEscape(query)
    response, err := host.JSON(ctx, provider.Request{Source: s.spec.ID, Address: address})
    if err != nil {
        return nil, err
    }
    // …同 CatalogPage 的节点映射，返回 []provider.Drama
}
```

详情 + 集数（`sourceID` 入参就是第 2 步里 `DramaID` 的第二个参数，直接拼站内接口）：

```go
func (s *Source) Detail(ctx context.Context, host provider.Host, sourceID string) (provider.Drama, []provider.Chapter, error) {
    base := s.base(host)
    detail, err := host.JSON(ctx, provider.Request{
        Source:  s.spec.ID,
        Address: base + "/api/detail?id=" + url.QueryEscape(sourceID),
    })
    if err != nil {
        return provider.Drama{}, nil, err
    }
    drama := provider.Drama{/* …标题、简介、封面映射… */}

    items := provider.FindList(detail, "data", "episodes")
    chapters := make([]provider.Chapter, 0, len(items))
    for i, item := range items {
        node, ok := item.(map[string]any)
        if !ok {
            continue
        }
        chapters = append(chapters, provider.NewChapter(
            s.spec.ID, sourceID, i+1,
            provider.FindString(node, "title"),            // 留空则自动「第 N 集」
            provider.FindString(node, "url", "videoUrl"),  // 第 i 集直链
            "", "",
        ))
    }
    provider.SortChapters(chapters)
    return drama, chapters, nil
}
```

> 直链若需要二次解析（Referer 防盗链、加密 m3u8、跳转）不必在这一步做死——集里先放网页地址或加密地址，再实现 `MediaResolver`（见 §4.3）。`Chapter.Referer` 能覆盖宿主默认 Referer。

### 第 4 步：注册与编译期断言（`native/sources/demo/register.go`）

```go
package demo

import "duanjuapp/native/provider"

func init() {
    if spec, found := provider.SpecOf(provider.SourceDemo); found {
        provider.Register(New(spec))
    }
}

var (
    _ provider.Cataloguer = (*Source)(nil)
    _ provider.Detailer   = (*Source)(nil)
    _ provider.Searcher   = (*Source)(nil)
)
```

要点：
- `init` 里先 `SpecOf` 再 `Register`：源实现包被导入时自动注册，**覆盖**静态清单的占位 Provider；
- 接口断言（`var _ provider.Cataloguer = (*Source)(nil)`）是编译期合同——能力方法签名改了，这里立刻编译失败，不会带病上线。

### 第 5 步：聚合导入（`native/sources/all/all.go`）

```go
import (
    // …
    _ "duanjuapp/native/sources/demo"
)
```

`native/core/adapter_sources.go` 空导入了 `all` 包，导入即注册，至此新源已完整接入目录、搜索、详情、播放与下载全链路。

### 自检

```bash
cd native
go build ./core          # 编译 Go 核心
go vet ./...             # 静态检查
go test ./provider/      # 注册表守恒测试
go test ./sources/...    # 既有源包回归
```

---

## 4. 进阶模式

### 4.1 网页解析源（`Kind: "web"`）

播放直链藏在网页里的站点（如河果、maccms 网页版），流程是 `host.Text` 拉取 HTML → `golang.org/x/net/html` 解析 → `provider/webhtml.go` 辅助遍历：

| 辅助函数 | 用途 |
|---|---|
| `HTMLNodes(root, match func(*html.Node) bool)` | 递归收集匹配节点 |
| `HTMLFirstClass(root, names ...string)` | 按 class 名找第一个节点 |
| `HTMLText(node)` / `HTMLAttr(node, name)` / `HTMLClass(node, name)` | 取文本 / 属性 / class 判断 |
| `Absolute(base, reference)` | 相对地址转绝对地址 |
| `EpisodeNumber(raw, fallback)` | 从「第X集/EP3」等文本提取集数 |

播放直链不必自己爬播放器：`provider/webmedia.go` 的

```go
func ResolveWebMedia(ctx, host, address, referer, sourceName) (provider.Media, error)
```

给定**播放页地址**即可自动嗅探出可播 `Media`；配套 `PlayerURL`（从页面提取播放器地址）、`NormalizePlaybackURL`（归一化直链）、`M3U8Duration`（时长估算）。实现 `Detail` 时把集的 `PageURL` 填上网页地址，再实现 `ResolveMedia` 调用 `ResolveWebMedia` 即成完整网页源。参考实现：`native/sources/heguo`、`native/sources/maccmsweb`。

`Spec.Browser: true` 会把源登记进核心的网页嗅探清单（`native/core/network_browser.go`），供需要 WebView 参与解析的场景使用。

### 4.2 一包多源：maccms 资源 API 模式

同构资源站（API 规范一致的 maccms `provide/vod` 接口）**不需要每站写一个包**。`native/sources/maccmsapi/register.go` 的做法：一个通用 `Source` 实现 + 一张「源 ID → 站内短剧分类 ID」映射表，循环注册：

```go
var dramaTypeIDs = map[string]string{
    provider.SourceYingshigongchang: "46",
    provider.Source360ZY:            "46",
    provider.SourceModu:             "38",
    // …
}

func init() {
    for id, typeID := range dramaTypeIDs {
        spec, found := provider.SpecOf(id)
        if !found {
            continue
        }
        provider.Register(New(spec, typeID))
    }
}
```

接入新的同构站只需：`specs.go` 加一条 `Kind: "maccms_api"` 的 sourceEntry + 映射表加一行——**零新增代码文件**。`New(spec, typeID)` 的第二参数供通用实现拼接口地址。

### 4.3 MediaResolver：播放二次解析

当 `Chapter.VideoURL` 不是可直接播放的地址（网页待嗅探、加密 m3u8、需再请求一次拿真实流）时，实现 `MediaResolver`，播放器与下载器会在消费该集前自动调用：

```go
func (s *Source) ResolveMedia(ctx context.Context, host provider.Host, task provider.Task) (provider.Media, error) {
    // 网页源一条龙：嗅探播放页直链
    return provider.ResolveWebMedia(ctx, host, task.Chapter.PageURL, task.Chapter.Referer, provider.SourceName(s.spec.ID))
}
```

`Media` 结构：`URL`（直链）、`Referer`（防盗链）、`Duration`、`Playlist`（m3u8 内容缓存）、`HLSKey` / `CENCKey`（AES-128 / CENC 解密密钥）、`Quality`、`Variants`（多码率备选）。`task.Chapter` 携带集信息，`task.DramaID` / `task.OutPath` 供下载场景区分。

### 4.4 Prober：健康探测

实现 `Probe(ctx, host) (string, error)` 返回一段探测描述，健康检查流程会调用它；不实现则跳过。适合给出「鉴权方式」「资源规模」等说明性信息。

---

## 5. 接入机制：兜底适配与门控

### 5.1 兜底适配器：为什么只登记也能显示

`native/core/adapter_sources.go` 的 `init()` 做一次补位：遍历 `provider.All()`，对 `Family == duanju` 且尚未注册实现的源，注册一个占位适配器。用户点开占位源时收到明确报错（「该站源暂未接入目录/详情」），而不是静默失败。

包初始化顺序保证了正确性：`adapter_sources.go` 空导入 `all` 包 → **各源包的 `init` 先执行注册真实现** → core 的 `init` 只给漏网的源补占位。所以你实现到哪一步接入到哪一步，UI 始终可用。

### 5.2 构建门控（`RequiresAllSources`）

```
ALL_SOURCES=true 构建 ──ldflags──▶ buildAllSources="true" ──▶ provider.Configure(Config{AllSources: true})
```

`native/core/app_build.go` 在 `init` 里把构建旗标注入注册表；`Available(id)` 对 `RequiresAllSources: true` 的源做门控——精简版（红果鉴）里该源不可见/调用时报「当前版本不包含此站源」。**新源一律先 `RequiresAllSources: true`**，真机验证稳定后再决定是否进精简版。

### 5.3 运行时域名覆盖

`Configure(Config{Hosts: map[string]string{ "demo": "https://api.new-domain.com" }})` 可以在不发版的前提下替换某源的 `Base`——这正是第 2 步 `base()` 辅助函数「先问 `host.BaseURL` 再回退 `spec.Base`」存在的原因。站点换域名的处置顺序：临时用 Hosts 覆盖救急 → 发版把 `specs.go` 的 `Base` 改为正式域名，并在 `hosts` 里补上新域。

---

## 6. 验证与验收

### 6.1 命令清单（`native/` 目录下）

```bash
go build ./core                  # 核心可编译
go vet ./...                     # 静态检查
go test ./provider/              # 注册表守恒测试（ID 唯一性、必填字段、门控行为）
go test ./sources/...            # 既有源包回归
go test ./...                    # 全量
```

### 6.2 手工健康检查（等同 App 内「检测连接与播放」）

```powershell
cd native
$env:GUOAPP_HEALTH_CHECK = '1'           # 不设则测试直接跳过
$env:GUOAPP_HEALTH_SOURCES = 'demo'      # 可选：只测指定源（逗号分隔）
go test -run TestManualSourceHealth -v -timeout 120m ./core/
```

### 6.3 真机验收清单

- [ ] 站源管理出现新源卡片，可开关
- [ ] 目录：分类渲染正确；`Paged` 源翻页正常加载、`hasMore=false` 时正确停住
- [ ] 搜索：聚合搜索出现该源结果（`Searcher` + `Search` 实现齐全）
- [ ] 详情：封面 / 简介 / 集数完整，章节集数排序正确
- [ ] 播放：直链可播；媒体直链域名已在 `hosts` 中（归属正确）
- [ ] 下载：单集与批量下载成功，本地文件可导出
- [ ] 门控：不带 `ALL_SOURCES` 的精简构建里该源按预期隐藏
- [ ] `go test ./...` 全绿
- [ ] **重新编译 Go 核心并打包**（测试通过 ≠ App 内核更新，交叉编译命令见 [DEVELOPMENT.md](DEVELOPMENT.md)）

---

## 7. FAQ

**Q1：只在 `specs.go` 登记了、还没写实现，会怎样？**
卡片正常显示；点进去报「该站源暂未接入目录/详情」。这是兜底适配器（§5.1）在工作，不影响其他源。

**Q2：`RequiresAllSources` 什么时候设 `false`？**
默认 `true`。只有希望该源出现在默认精简版（红果鉴）时才设 `false`，且需先在精简版构建下实测通过。

**Q3：新源需要改 Flutter 代码吗？**
不需要。站源完全在 Go 侧，Flutter 只有通用的站源管理与列表渲染；除非引入全新的 UI 能力。

**Q4：源搜索不生效？**
依次检查：`Spec.Searcher: true`、实现了 `Search` 方法、`register.go` 断言里包含 `_ provider.Searcher = (*Source)(nil)`。

**Q5：目录只能翻一页或无限翻页？**
`Paged` 旗标要与 `CatalogPage` 第二个返回值一致：站点只有一页就返回 `false`，不要为了「看起来能翻」硬返回 `true`。

**Q6：maccms 类站点从哪下手？**
先判断站型：资源 API 规范（`provide/vod`）→ 复用 `maccmsapi` 通用包（§4.2）；网页版 → 参考 `maccmsweb`；结构特殊的才单独写包。

**Q7：`Kind` 字段有实际作用吗？**
当前仅作归类元数据（健康检查展示、调试归类）；调度逻辑只看能力旗标（`Searcher/Paged/Browser`）与接口断言。但请如实填写，便于后续维护者识别站型。

**Q8：别名里要不要放旧域名？**
要。历史追剧数据、云端同步记录里可能是旧标识或旧域名，`Canonical` 归一依赖 aliases；丢别名会导致旧数据「找不到源」。

