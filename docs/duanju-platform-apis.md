# 短剧平台 API 接口文档

> 整理自本地源包 `星微261002，本地包.zip` → `tvboxTW/本地【星微vip线】/js/duanju_juhe.js`（drpy 猫爬虫，2178 行）。
> 该爬虫聚合 **12 家短剧平台**的接口（默认启用 7 家，另 5 家被 `cate_remove` 停用，见 §1）。本文档将其逐一展开，并给出接入 guoapp（真果鉴）站源体系的评估。
>
> ⚠️ 合规提示：接口均为第三方私有 API（部分含逆向所得的固定密钥与签名），仅供学习测试，请勿商用或传播；接口随时可能失效。

---

## 1. 总览

| # | 平台 | vod_id 前缀 | 主域名 | 鉴权/加密 | 播放格式 | 接入难度 | 建议 |
|---|------|------------|--------|-----------|----------|---------|------|
| 1 | 甜圈 | `tianquan@` | mov.cenguigui.cn | 无 | mp4 | ★ | 首选试点 |
| 2 | 软鸭 | `ruanya@` | api.xingzhige.com | 无 | mp4/m3u8 | ★ | 首选试点 |
| 3 | 围观 | `weiguan@` | api.drama.9ddm.com | 无 | mp4（多清晰度） | ★ | 推荐 |
| 4 | 锦鲤 | `jinli@` | api.jinlidj.com | 无 | mp4（自解析） | ★★ | 推荐 |
| 5 | 百度 | `baidu@` | mbd.baidu.com | UA + version=md5 | 多清晰度 mp4 | ★★ | 推荐 |
| 6 | 番茄 | `fanqie@` | reading.snssdk.com / fqgo.52dns.cc | 固定 body 参数 | mp4 | ★★ | 可接 |
| 7 | 七猫 | `qimao@` | api-store.qmplaylet.com | qm-params 混淆 + md5 sign | m3u8 | ★★★ | 可接 |
| 8 | 星芽 | `xingya@` | app.whjzjx.cn / u.shytkjgs.com | 账号登录 token | m3u8 | ★★★ | 可接 |
| 9 | 碎片 | `suipian@` | free-api.bighotwind.cc | token（AES 时间戳头） | 视频文件直链 | ★★★ | 可接 |
| 10 | 河马 | `hema@` | freevideo.zqqds.cn | AES-128-CBC（hex 密文） | m3u8 | ★★★ | 可接 |
| 11 | 牛牛 | `niuniu@` | new.tianjinzhitongdaohe.com | AES-ECB + HMAC-SHA256 + token | mp4 | ★★★★ | 暂缓 |
| 12 | 西饭 | `xifan@` | xifan-api-cn.youlishipin.com | 硬编码 JWT session | mp4 | ★★★★ | 暂缓（session 会过期） |

通用默认头（`aggConfig.headers.default`）：手机 UA、`client: android`；每个请求 5s 超时（`request()` 统一封装）。

**默认启用状态**：`cate_remove = ['分类排除','软鸭','碎片','锦鲤','番茄','甜圈']`（js:23），而 `home()`/`homeVod()`/`search()` 三个入口统一经 `getPlatList()` 过滤（js:601/619/1865）——**默认仅 7 家在线：星芽、西饭、七猫、牛牛、百度、围观、河马**。被停用的 5 家代码完整可随时恢复，但恰好都是第三方聚合类接口（cenguigui/xingzhige 等），推测打包时已不稳定——接入试点时应优先做存活率探测。

---

## 2. 数据模型约定

- **vod_id**：`平台名@资源ID`，如 `tianquan@7123456`。detail/search 统一 `split('@')` 分发到对应平台实现。
- **分类即内容流**：12 家平台全部**没有真正的排序参数**。`area` 里的「推荐/新剧/都市/逆袭…」是**频道标签**，传给 API 后返回的就是该频道的编辑流。guoapp 的排序/筛选仍应在本地做（现有 `catalog_sort.dart` 思路正确）。
- **推荐**：`homeVod()` 的实现 = **随机挑一个启用平台 → 拉它的频道首页 → 返回列表**。即「推荐 = 各平台精选位聚合轮换」，无算法。
- **搜索**：启用平台 `Promise.all` 并发请求（默认 7 家），6s 超时、逐平台 try/catch 吞错，结果按「标题包含关键词」过滤并去重。

---

## 3. 逐平台 API 详解

### 3.1 甜圈 tianquan（最简单，cenguigui 自建聚合 API）
| 操作 | 请求 |
|------|------|
| 列表 | `GET https://mov.cenguigui.cn/duanju/api.php?classname={频道名}&offset={页码}` → `data.list[]`（`book_id / title / cover`） |
| 详情 | `GET …/api.php?book_id={id}` → `data.book_data`（info + `list[]` 集数：`title / video_id`） |
| 搜索 | `GET …/api.php?name={关键词}` |
| 播放 | `GET …/api.php?video_id={vid}&type=mp4` → `data.url` |

无任何鉴权；风险在于这是个人自建聚合站，稳定性一般。

### 3.2 软鸭 ruanya（xingzhige 第三方 API）
| 操作 | 请求 |
|------|------|
| 列表 | `GET https://api.xingzhige.com/API/playlet?keyword={频道名}`（分类即关键词） |
| 详情 | `GET …/API/playlet/?book_id={id}` → `data`（`title / cover / chapter_list[]` 带 `video_id`） |
| 播放 | `GET …/API/playlet/?video_id={vid}&quality=original` → `data.url` |

### 3.3 围观 weiguan（9ddm，无鉴权）
| 操作 | 请求 |
|------|------|
| 列表 | `GET https://api.drama.9ddm.com/shortVideoTags?tag_id={分类id}&offset={页}&count=24` → `data.list[]` |
| 详情 | `GET …/shortVideoDetail?video_id={id}` → `data.playSetting[]`（多清晰度 `url + quality: 1080/720/480`）+ 集数列表 |
| 搜索 | `GET …/shortVideoSearch?keyword={kw}` |

### 3.4 锦鲤 jinli
| 操作 | 请求 |
|------|------|
| 列表 | `POST https://api.jinlidj.com/api/search`，JSON body `{page, limit:24, type_id, year, keyword}` → `data.data[]` |
| 详情 | `GET …/api/detail/{id}` → `data`（`episodes[]`: `title / url`，`remark`） |
| 播放 | `GET {url}&auto=1` → 响应 HTML 中抓 `let data={...}` 行 → JSON 的 `data.url` |

### 3.5 百度 baidu
| 操作 | 请求 |
|------|------|
| 列表 | `POST https://mbd.baidu.com/ma/qingyan/feedapi/list`，body `{coll_id, offset, count:24, t: 毫秒时间戳, version: md5(t+"v2")}` → `data.list[]` |
| 搜索 | `POST …/feedapi/search`，body `{word, pn, count, version…}` |
| 详情 | `POST …/feedapi/detail`，body `{coll_id}` → `data.detail`（`episodes[]`: `item_id / title`） |
| 播放 | `POST …/feedapi/collect_info`，body `{coll_id, item_id}` → `data.url_list[]`（多清晰度） |

必备头：`User-Agent: Mozilla/5.0 … baiduboxapp/…`、`Referer: https://mbd.baidu.com/`。

### 3.6 番茄 fanqie（头条系）
| 操作 | 请求 |
|------|------|
| 列表 | `POST https://reading.snssdk.com/api/novel/channel/homepage/library/cell/change/v/`，body `{tab_id, offset, count:18, …}` → `data.data[]`（`item_id / book_name / thumb_url / tags`） |
| 搜索 | `POST https://fqgo.52dns.cc/fanqie-api/api/search/novel`，body `{query, offset, count}` |
| 详情 | `GET https://fqgo.52dns.cc/fanqie-api/api/catalog?book_id={id}` → info + `item_ids[]` |
| 播放 | `GET https://fqgo.52dns.cc/fanqie-api/api/video?item_ids={vid}` → `main_url` 为 base64，`atob` 解码后取 `data[0].main_url_mp4_1` |

### 3.7 七猫 qimao（qm-params 混淆 + 签名）
- 签名算法（`getAndSign()`，js:1979）：
  1. 构造设备 JSON（uuid/device-id/model/brand 等字段，多数可固定值，`session-id` 取毫秒时间戳）
  2. `qm_params = base64(JSON)` 再经 `charMap` 字符替换表混淆
  3. `sign = md5("AUTHORIZATION=app-version=10001application-id=com.duoduo.readchannel=unknownis-white=net-env=5platform=androidqm-params={qm}reg=d3dGiJc651gSQ8w1")`
- 请求头：`qm-params`、`sign`、`application-id: com.duoduo.read`、`app-version: 10001`、`platform: android`
| 操作 | 请求 |
|------|------|
| 列表 | `POST https://api-store.qmplaylet.com/yplaylet/index/all`，body `{page, tab, id: tabId}` |
| 详情 | `POST https://api-read.qmplaylet.com/yplaylet/player/playlet/info`，body `{playlet_id}` → `data.playlet + play_list[]`（`sequence / video_url` m3u8） |
| 搜索 | store 域同名接口带 `text` |

### 3.8 星芽 xingya（需登录 token）
- 登录（js 内置固定账号）：`POST https://u.shytkjgs.com/duanju/user/v1/account/login`，body `{device: 32位hex, account, password: md5}` → `data.token`；后续头 `authorization: {token}`。
| 操作 | 请求 |
|------|------|
| 列表 | `POST https://app.whjzjx.cn/duanju/cloud/v2/theater/home_page?theater_class_id={id}` → `data.list[]`；tab 元数据在 `data.tabs[]` |
| 搜索 | `POST …/cloud/v3/search`，body `{text}` |
| 详情 | `POST …/cloud/v2/theater/parent/parent_list`，body `{theater_parent_id, page, size}` → `data.list[].drama_list[]`（`name / images / episode_num`，集数地址随 detail 返回） |

### 3.9 碎片 suipian
- 取 token（`getSuiPianToken()`，js:2028）：
  1. `openId = md5(uuid).slice(0,16)`
  2. 请求头 `key = AES-128-ECB(当前毫秒时间戳, 密钥 "p0sfjw@k&qmewu#w")` 的 hex
  3. `POST https://free-api.bighotwind.cc/papaya/papaya-api/oauth2/uuid`，body `{openId}` → `data.token`
- 列表/搜索/详情走 `papaya-api` 各端点，头带 token；封面/视频文件在独立下载域 `download/{imageKey}/{imageName}`。

### 3.10 河马 hema（AES-128-CBC hex 密文响应）
- 加解密（js:1900-1929）：key hex `647a6b6a67667978677368796c677a6d`（ASCII `dzkjgfyxgshylgzmd`），iv hex `6170697570646f776e65646372797074`（ASCII `apiupdownedcrypt`），CBC/PKCS7；响应是 **hex 大写密文** → 解密得 JSON。
| 操作 | 请求 |
|------|------|
| 列表 | `GET https://freevideo.zqqds.cn/freevideo/portal/{tabId}/{页码}` → 解密后 `data.list[]` |
| 详情/播放 | portal 子路径（1121/1131/1132/1133/1803 等）→ 解密；播放地址 `…m3u8720p` |
| 兜底 | `GET https://api.cenguigui.cn/duanju/hema.php?video_id={vid}` 直接返回 m3u8 |

### 3.11 牛牛 niuniu（最复杂）
- 双层保护（`niuniuPost()`，js:2095）：
  1. 请求体为表单串 → 字符串替换注入 `timestamp/lock_free/lock_ad/count/index` → `body2 = AES-128-ECB(体, "ce49b18dd4e0a4d8")`
  2. `X-Signature = HMAC-SHA256(t10 + "X9UknYKtLa3DmtjC" + body1, "aceaa47f96b4875d446b2e1d97e03bbb")`
  3. 头：`X-Salt: FD8188A8D5`、`X-Nonce`、`X-Timestamp`、`X-Access-Token`（先 `csj-sp` 游客接口取 token，响应体也是 AES-ECB）
- 端点：`new.tianjinzhitongdaohe.com/shortplay/screenMovie`（列表）、`/shortplay/movieDetails`（详情）、`/shortplay/search`（搜索）；含广告解锁字段（`lock_ad` 等），剧集 url 由 detail 返回。

### 3.12 西饭 xifan
- `POST https://xifan-api-cn.youlishipin.com/api/web/portalPage`（列表）/ `…/aggregationPage`（搜索）。
- 头里 **硬编码 `session` / `feedssession` JWT**（js 内 `xifan_headers`）——**这是时效性最差的接口**，JWT 过期即全站 401，不推荐接入。

---

## 4. 鉴权与加密汇总

| 平台 | 算法 | 密钥/参数 | 备注 |
|------|------|-----------|------|
| 七猫 | base64+字符表混淆 + md5 | sign 盐 `d3dGiJc651gSQ8w1`；charMap 表在 js `aggConfig` | 设备字段可写死 |
| 星芽 | md5 密码 + Bearer token | 内置账号密码 | token 有效期未知 |
| 碎片 | AES-128-ECB | key `p0sfjw@k&qmewu#w`（明文 16B） | 加密对象是时间戳 |
| 河马 | AES-128-CBC/PKCS7 | key `dzkjgfyxgshylgzmd`、iv `apiupdownedcrypt` | 响应 hex 密文 |
| 牛牛 | AES-128-ECB + HMAC-SHA256 | AES `ce49b18dd4e0a4d8`；HMAC `aceaa47f96b4875d446b2e1d97e03bbb`；nonce `X9UknYKtLa3DmtjC`；salt `FD8188A8D5` | 双重签名+游客 token |
| 西饭 | —（JWT 直传） | js 内硬编码 | 会过期 |
| 百度 | version=md5(t+"v2") | — | UA 必须是百度系 |

---

## 5. guoapp 接入评估

### 5.1 现状
guoapp 数据通道是 **FFI 原生内核**：`core_bridge.dart:28` `DuanjuRequest`（`libduanju_core.so` / `duanju_core.dll`），Flutter 侧仅 `NativeRepository` 一个源（`core_bridge.dart:240`）。站源的目录/筛选/聚合/下载全部由内核完成，UI（首页/排行/推荐/下载）零感知。

### 5.2 三条接入路线
| 路线 | 做法 | 优点 | 代价 |
|------|------|------|------|
| **A. 内核侧 adapter（推荐）** | 在 duanju_core 里按平台实现同一条命令族（catalog/search/detail/play），加密用内核侧现成 AES/MD5/HMAC | 全 UI 自动受益：聚合搜索、排行榜、追剧、下载链路零改动 | 要改内核并重编 Android+Windows 两条链 |
| **B. Dart 侧补充源** | 新建 `RemoteSourceRepository extends AppRepository`，自管 HTTP + 加密（`crypto` + `encrypt` 包），聚合进 catalog/search 结果 | 不动内核、迭代快 | 与内核源的去重/排序/下载链路要手工打通 |
| **C. 试点混合** | 先用 B 接甜圈/软鸭 1-2 家验证接口存活率与画质，再决定内核化范围 | 风险最小 | — |

### 5.3 分批建议
1. **第一批（无鉴权，1-2 天量级）**：甜圈、软鸭、围观、锦鲤 —— 纯 HTTP + JSON，Dart 直连即可。
2. **第二批（固定签名）**：百度、番茄、七猫、河马 —— 签名算法确定，移植成本低。
3. **第三批（带状态）**：星芽（登录 token）、碎片（时间戳 token）。
4. **暂缓**：牛牛（双签名+广告解锁逻辑）、西饭（JWT 必过期）。

### 5.4 与排序/推荐/排行榜的对接语义
- **排序**：平台侧无排序参数，`area` 是频道流 → guoapp 维持本地排序（`catalog_sort.dart`），把 12 家的「频道标签」映射进 `catalog_filters.dart` 即可。
- **推荐**：参考爬虫 `homeVod()` —— 轮换取各接入平台首页精选位，guoapp 的 `recommendations_screen` 加一个「多源精选」聚合卡片即可复刻。
- **排行榜**：本爬虫无榜单端点；排行榜现走豆瓣官方合集（`native/core/provider_rankings_douban.go`，`movie_top250 / movie_real_time_hotest / movie_weekly_best` 等参数表），无需本地榜单。

### 5.5 风险清单
- 第三方接口随时失效，需按平台做熔断与「源健康」提示（复用现有 `source_status.dart`）。
- 固定设备指纹/UA 硬编码，量大可能触发风控。
- 均为逆向所得接口，**不建议**随 app 分发到生产；学习测试环境使用。

---

## 6. 附：包内线路时效与短剧资源分布

按文件修改时间排序的 19 条线路时效（zip 保留原始时间戳）：

| 线路 | 最新文件日期 | 短剧相关 |
|------|------------|----------|
| **星微vip线** | **2026-10-02（最新）** | `js/duanju_juhe.js`（本文档对象） |
| 嗷呜线路 | 2026-09-29 | 短剧站 `csp_HgdhAmns`（红果系，闭源 jar 不可移植）；带弹幕服务/壁纸代理的影视仓增强配置 |
| 九月线路 | 2026-09-27 | — |
| 拾光线路 | 2026-09-26 | `open/duanju_juhe.js` 与星微线副本 **MD5 完全一致**（591A60677649B7777D6A56D5376E7684，79030B） |
| VOX线路 | 2026-02-02 | `json/duanjucen.json`：**50 个短剧题材分类词表**（总裁/女帝/赘婿/战神/甜宠/逆袭/闪婚/年代…），可作 guoapp `catalog_filters.dart` 的题材词表参考 |

结论：**星微vip线就是本包的「最新线路」**，短剧聚合爬虫全包仅此一份（两处副本相同）；其他线路的短剧能力要么在闭源 jar 里，要么是纯分类词表，均不改变本文档的接入评估。
