# 性能修复任务说明（2026-10-29）

本文件把《三维度性能审查报告》的全部结论收敛为一份可执行清单：8 项修复对象、每项判据、三条行为红线、两个契约变更点、交付步骤。

修复分三个维度：**运行期**（项 1/4/5/7）、**启动**（项 3/6）、**播放与写盘**（项 2/8）。

---

## 一、修复对象与判据

### 项 1（P0）`LocalStore.saveWatch` 全量重解析 + 全量通知

| 项 | 内容 |
| --- | --- |
| 位置 | `lib/local_store.dart:695` `saveWatch`、`:221` `_loadLibrary`、`:124` `_notify`、`:527` `_commit` |
| 现状 | 每 5 秒（`player_screen.dart:456` 定时器）触发一次：整份历史 `jsonEncode` → 落盘 → `_loadLibrary()` 清空六个内存表并重解析全部键 → `notifyListeners()` 整树重建 |
| 改法 | ① `saveWatch(WatchEntry entry, {bool notify = false})`；② 删除末尾无条件 `_loadLibrary()`，改为只增量更新 `_history[id]` / `_followStates[id]` / `_favorites[id]`；③ `_lanDocumentCache = null` 单点失效；④ 排序推迟到读取侧 `_sortedHistory`（`updatedAt` 降序、截断 300），超出 300 条时才裁剪一次 |
| 判据 | 周期保存路径零 `_loadLibrary`、零 `notifyListeners`；退出播放页 / 切换用户 / 播完自动下一集各触发一次 `notify: true` 的 flush |
| 红线 | 见「三、红线 1」 |

### 项 4（P1）弹幕 overlay 每帧线性遍历

| 项 | 内容 |
| --- | --- |
| 位置 | `lib/danmaku_overlay.dart:157` 起的 `for (final flight in _schedule)` |
| 现状 | `AnimatedBuilder` 内每帧对全部弹幕做 `if (可见窗口)` 过滤，O(n) |
| 改法 | schedule 重建时同步预建按 `timeMs` 升序的索引数组；渲染时二分定位窗口下界，只遍历命中区间 |
| 判据 | 位置高频推进时单帧不再遍历全部弹幕；可见集合与改造前逐帧一致 |

### 项 5（P1）播放器位置流无节流

| 项 | 内容 |
| --- | --- |
| 位置 | `lib/player_screen.dart:400` `_player.stream.position.listen` |
| 现状 | 每个位置事件都跑 `_applySkipMarks` / `_syncDanmaku` / `_syncPreload` / `_acknowledgeHandoff` |
| 改法 | 收敛到单一节流入口（位置增量 ≥ 阈值才跑重活）；`_resumePosition` 仍每事件更新；跳片真命中、位置不连续跳转、握手确认在事件到达时立即执行，不受节流影响 |
| 判据 | 正常播放每 5 秒写盘逻辑不变；跳片标记与握手不丢触发 |

### 项 7（P1）每请求一次 Isolate 往返

| 项 | 内容 |
| --- | --- |
| 位置 | `lib/core_bridge.dart:76`、`:890` `Isolate.run(() => _nativeRequest(body))` |
| 改法 | 常驻单 worker isolate（懒启动 + 请求队列 + `Completer` 回填），保留超时与错误语义 |
| 判据 | 单次请求不再新建 isolate；结果/异常/超时语义与现状一致 |

### 项 3（P0）首帧前同步解析 `catalogs.json`

| 项 | 内容 |
| --- | --- |
| 位置 | `native/core/app_runtime.go:345` `engine.loadCatalogCache()`；`native/core/app_catalog_cache.go:32` |
| 改法 | 四次同步加载（resource/ranking/live/catalog/source）改为 `sync.Once` 懒初始化，由首次 `cached()` / `nativeCatalog` 触发 |
| 判据 | `cached()` 首次调用即返回磁盘目录且 `Fresh` 判定正确（`catalogStates.UpdatedAt` 一并加载） |
| 红线 | 见「三、红线 2」 |

### 项 6（P1）启动串行 await

| 项 | 内容 |
| --- | --- |
| 位置 | `lib/main.dart:45` `await AppDevice.detect()`、`:128` 起的串行初始化 |
| 改法 | 设备检测不阻塞 `runApp`（保留安全默认值，首帧后回填）；无写冲突的初始化步骤并行 |
| 判据 | 首帧更早；启动后版本号/设备形态判定仍正确（更新弹窗依赖 build 号） |

### 项 2（P0）Go 侧 catalog 整份写盘

| 项 | 内容 |
| --- | --- |
| 位置 | `native/core/app_catalog_cache.go:259` `writeCatalogDiskLocked` |
| 现状 | 每页变更整份 `json.Marshal` + `Sync` + `Rename`，连续翻页 O(n²) IO |
| 改法 | 同步 Marshal + 同步大小判定保留（超限当场返回），实际 IO 交合并窗（脏标记 + 定时 flush）；强制 flush：重试保存、切换源/用户、上报保存错误前 |
| 判据 | 两次连续分页变更只落盘一次；超限仍在同一调用栈返回 `errNativeCatalogLimit` |
| 红线 | 见「三、红线 3」 |

### 项 8（需决策）Referer 兜底源域

| 项 | 内容 |
| --- | --- |
| 位置 | `native/core/provider_media.go:235` 附近 |
| 现状 | Referer 兜底取 `providerBaseURL(source)`，与实际命中镜像域不一致 |
| 改法 | 兜底值改为「本次请求实际命中的 host 对应 base」，仅兜底路径生效 |
| 判据 | 新增用例断言兜底 Referer 与命中 host 一致；heguo/xingguo/fanguo/maoguo/yaguo 现有用例零变化 |

---

## 二、契约变更点（用户已同意）

1. **catalog 每页整份写盘语义**：允许合并窗，但「超 32 MiB 当场同步报错」必须在内存层同步判定并同步返回；`TestNativeCatalogSizeLimitPreservesPreviousFile` 同步改写编码，不得删除。
2. **core baseURL 语义**：仅允许把 Referer 兜底改为实际命中 host；禁止改动源注册、两跳回退逻辑与 heguo/xingguo/fanguo/maoguo/yaguo 的既有行为。

---

## 三、三条不可破坏的行为红线

### 红线 1：`saveWatch` 静默化不得丢通知

- 退出播放页、切换用户、播完自动下一集必须有一次带 `notify` 的 flush，否则「继续观看」条滞后。
- `updatedAt` 降序、取前 300 的排序语义原样保留，只允许把排序推迟到读取时计算。

### 红线 2：`cached()` 语义不变

- 仍返回「磁盘已有目录 + `Fresh` 判定」，只把解析时点从 `initialize` 后移到首次调用。
- `catalogStates.UpdatedAt` 必须一起加载，否则 `Fresh` 恒 false，客户端会退化成每次全量重拉。

### 红线 3：延迟合并不得丢写

- 必须有空闲 flush、进程退出/引擎关闭 flush、切换用户或源立即 flush。
- `writeNativeCacheFile` 的 `Sync` + `Rename` 保留。
- 超限与磁盘满的报错仍走 `nativePersistenceError` / `catalogSaveError` 回传 Dart。

---

## 四、验收标准

- Dart：分文件、分变体（默认单源 / `--dart-define=ALL_SOURCES=true`）跑 `flutter test` 全绿；`flutter analyze` 零新增告警。
- Go：`go test` 全绿（module 根 `C:\guoapp\native`）。
- 真机装机冒烟：启动、首页进内容、播放、追剧页「继续观看」行为不变；`logcat -b crash -d` 无 FATAL。
- 不强制前后量化对比；允许临时插桩，合入前移除。视觉类不做截图验收。

---

## 五、交付步骤

1. 本文件落盘（范围 / 判据 / 红线 / 契约 / 口径）。
2. 五个代码域并行修改 + 对应测试扩充。
3. `verify-all`：分文件分变体测试 + `go test` + `flutter analyze` + code-reviewer 复查红线。
4. `build-ship`：`git show origin/main:app_config.json` 查线上 build 号 → bump → `zhen_repub.ps1` 刷 lock → Go 有改动走 `build_zhen.ps1` 全流水线 → APK 装机冒烟 + `logcat -b crash -d` 查 FATAL。

---

## 六、执行注意事项

- 禁止整文件回退 `lib/player_screen.dart` / `lib/player_controls.dart`，只做定点编辑。
- 改 `pubspec.yaml` 版本后先跑 `C:\cmake-src\zhen_repub.ps1`；`flutter test` / `flutter analyze` 会改写 lock，跑完需重刷。
- `go test -run` 正则含 `|` 在 cmd 下需拆多条。
- 工程根必须经纯 ASCII junction `C:\guoapp` 构建。
