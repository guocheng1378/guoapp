# 真果鉴 Code Wiki — Flutter 前端模块详解

## 1. 模块组织一览

Flutter 层共 81 个 Dart 文件，按职责可划分为以下模块组：

| 模块组 | 文件数 | 核心文件 | 职责 |
| --- | --- | --- | --- |
| **应用入口与启动** | 5 | `main.dart`, `app_build.dart`, `app_layout.dart` | 应用初始化、主题、方向、平台检测 |
| **FFI 桥接层** | 3 | `core_bridge.dart`, `cover_decoder.dart` | Go 原生核心调用、封面图片解码 |
| **数据模型** | 2 | `models.dart`, `danmaku_models.dart` | Drama/Episode/Catalog/SourceSite/Danmaku 等纯数据类 |
| **本地状态** | 3 | `local_store.dart`, `local_snapshot.dart`, `local_profiles.dart` | 用户隔离的状态快照、追剧、历史、偏好持久化 |
| **UI 页面** | 12 | `home_screen.dart`, `detail_screen.dart`, `player_screen.dart` 等 | 首页、详情、播放器、下载、榜单、推荐、设置 |
| **播放器子系统** | 10 | `player_controls.dart`, `playback_loader.dart`, `danmaku_controller.dart` 等 | 播放控制、弹幕、缓冲、预加载、画质增强 |
| **下载子系统** | 6 | `downloads_screen.dart`, `batch_downloads.dart`, `media_merge.dart` 等 | 下载队列、批量下载、合并导出 |
| **局域网互联** | 5 | `lan_controller.dart`, `lan_sync.dart`, `lan_playback.dart` 等 | DNS-SD 发现、追剧同步、播放接力 |
| **电视适配** | 2 | `television_controls.dart`, `remote_widgets.dart` | 遥控器焦点、TV 专用控件 |
| **视频增强** | 6 | `video_enhancement.dart`, `video_enhancement_mpv.dart` 等 | Windows 端 Anime4K/FSRCNNX AI 画质增强 |

## 2. 应用入口：main.dart

```
main()  →  WidgetsFlutterBinding.ensureInitialized()
           ├─ Android: SystemChrome.setEnabledSystemUIMode(edgeToEdge)
           ├─ Windows: windowManager.ensureInitialized()
           ├─ MediaKit.ensureInitialized()
           ├─ VideoEnhancementAssets.registerLicenses()
           └─ runApp(AppBootstrap(device: device))
```

**`AppBootstrap`** 是 `StatefulWidget`，负责：
1. 检测平台设备类型（手机 / 电视 / 电脑）
2. 初始化 `NativeRepository`（Go 核心）
3. 初始化 `LocalStore`（本地偏好快照）
4. 附着 `MediaLibrary`（下载索引）和 `LanController`（局域网互联）
5. 构建 `DuanjuApp`（MaterialApp）

**`DuanjuApp`** 配置：
- 中文本地化
- 浅色/深色主题 + 跟随系统
- 电视模式：`FocusTraversalGroup` + 遥控器快捷键
- 启动锁：`store.locked` 时先显示 `ProfilesScreen`（用户登录）
- 主页面：`HomeScreen`

## 3. FFI 桥接层：core_bridge.dart

### 3.1 NativeRepository

继承自抽象类 `AppRepository`，通过 FFI 调用 Go 核心。核心调用路径：

```dart
String _nativeRequest(String body) {
  final library = DynamicLibrary.open(libraryPath); // .so / .dll / process()
  final request = library.lookupFunction<_NativeRequest, _DartRequest>('DuanjuRequest');
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  try {
    return request(input).toDartString();
  } finally {
    malloc.free(input);
    free(output);
  }
}
```

### 3.2 异步调用模式

所有桥接调用都被包装为 `Future<T>`，在 Dart 主线程外的 Isolate 执行，避免阻塞 UI：

```dart
class NativeRepository extends AppRepository {
  LocalStore? access; // 用户隔离的配置访问
  int _readSequence;
  Map<String, int> _activeReads;

  Future<Map<String, dynamic>> _call(String command, Map<String, dynamic> body) {
    body['command'] = command;
    final json = jsonEncode(body);
    final response = _nativeRequest(json);
    return Future.value(jsonDecode(response));
  }
}
```

### 3.3 AppRepository 抽象接口

定义了所有可用的原生操作：

| 方法 | 说明 |
| --- | --- |
| `initialize()` | 初始化原生核心、建立存储、加载站源 |
| `catalog(source, page, query, category)` | 目录列表 / 搜索 |
| `detail(drama)` | 剧集详情（分集列表） |
| `resolve(drama, episode, quality)` | 解析当前集播放地址，返回 PlaybackPlan |
| `fallback(plan)` | 播放失败时尝试备用地址 |
| `cover(drama)` | 获取封面图片字节 |
| `suggestions(query)` | 搜索联想 |
| `categories(source)` | 读取分类 |
| `rankingBoards()` / `rankings(board, page)` | 榜单 |
| `recommendations(genre)` | 红果推荐 |
| `preload(drama, episode)` | 预加载下一集 |
| `danmaku(plan, startMs, durationMs)` | 弹幕拉取 |
| `downloads()` / `enqueueDownloads(...)` / `controlDownloads(cmd)` | 下载管理 |
| `lan(command, payload)` | 局域网互联命令 |
| `resourceSettings()` / `saveResourceSettings()` | 网络与资源设置 |
| `storage()` / `moveDownloads(dir)` | 存储位置管理 |

## 4. 本地状态：local_store.dart

`LocalStore` 是**用户隔离的本地状态中心**，管理追剧、历史、偏好配置。

### 4.1 核心数据

```dart
class LocalStore extends ChangeNotifier {
  LocalStore(this._prefs);
  final SharedPreferences _prefs;
  Profile _profile;          // 当前用户
  List<Profile> _profiles;  // 所有用户
  late LocalSnapshot snapshot; // 快照（追剧 + 历史 + 偏好）

  bool get locked => _profile.locked;
  String get themeMode;       // light / dark / system
  String get displayMode;     // auto / phone / television / computer
  Set<String> get allowedSources;
  DownloadPreferences get downloadPrefs;
  PlaybackPreferences get playbackPrefs;
}
```

### 4.2 快照机制

所有用户数据被打包为 `LocalSnapshot` 写入 SharedPreferences 的一个 key：

```dart
class LocalSnapshot {
  List<FollowEntry> follows;        // 追剧
  List<HistoryEntry> history;       // 观看历史
  Map<String, UserSettings> users;  // 各用户偏好
  List<String> recentSearches;      // 搜索历史
}
```

每次写入完整快照，写入失败时回滚原数据并锁定访问。

### 4.3 追剧状态

```dart
class FollowEntry {
  String id;            // 站源+剧集ID
  String source;
  FollowState state;    // want / watching / watched
  DateTime? watchedAt;
  int knownEpisodes;    // 已知集数（判断更新基准）
  bool updateRead;      // 已读更新
  EpisodeProgress progress; // 续播进度
}
```

## 5. UI 页面体系

### 5.1 首页 HomeScreen

核心功能入口，包含：
- 顶部：排序筛选、榜单图标、多选下载、搜索
- 分类栏：左右滑动切换
- 内容网格：卡片式短剧列表（2:3 海报 + 两行标题 + 一行分类/进度）
- 底部导航：发现 / 追剧 / 最近观看 / 下载 / 更多

### 5.2 详情页 DetailScreen

- 上半部：封面、资料（标题、简介、追剧状态）
- 底部固定 CTA：立即播放 / 继续播放 + 下载入口
- 选集：默认折叠，每组 50 集，支持跳转、定位当前集
- 红果系列剧显示相关推荐

### 5.3 播放器 PlayerScreen（68KB，最大文件）

```
PlayerScreen
├── 视频画面层（media_kit Video 组件）
│   ├── 弹幕覆盖层 DanmakuOverlay
│   ├── 中央控制层（播放/暂停、进度条）
│   ├── 侧边按钮（弹幕、画中画）
│   └── 手势识别（上滑下一集、下滑上一集、长按3倍速）
├── 控制层 PlayerControls
│   ├── 横竖屏适配（手机竖屏下方Tab / 横屏分栏）
│   ├── 播放、暂停、倍速、清晰度、选集
│   ├── 下一集预加载状态显示
│   └── 缓冲进度二级轨道
├── 播放菜单 PlayerMenu
│   ├── 画质选择（源画质 → 低画质回退）
│   ├── 倍速（0.5x - 3x，长按临时3x）
│   ├── 画质增强开关（仅Windows）
│   └── 推送播放
└── 下方面板 Tab
    ├── 选集 EpisodeBrowser（紧凑网格）
    ├── 简介（含追剧入口）
    └── 下载
```

### 5.4 其他主要页面

| 文件 | 大小 | 功能 |
| --- | --- | --- |
| `downloads_screen.dart` | 40 KB | 下载队列管理、批量操作、进度显示 |
| `lan_screen.dart` | 44 KB | 局域网设备发现、同步面板、推送设置 |
| `profiles_screen.dart` | 17 KB | 用户管理、密码验证、权限分配 |
| `rankings_screen.dart` | 15 KB | 榜单浏览 |
| `sources_screen.dart` | 19 KB | 站源管理、健康检测、独立更新 |
| `settings_screen.dart` | 24 KB | 外观、备份、网络与资源设置 |

## 6. 播放器子系统

### 6.1 组件关系

```
PlaybackLoader       — 加载播放计划（调用 Go 核心 resolve）
    │
    ▼
PlayerScreen         — UI 容器 + media_kit Video
    │
    ├─ PlayerControls    — 手动控制层
    ├─ DanmakuController — 弹幕控制器
    │   └─ DanmakuOverlay — 弹幕动画层
    ├─ PlaybackRecovery   — 失败自动恢复（切备用地址）
    ├─ PlaybackPreloader  — 下一集预加载
    └─ VideoEnhancement   — Windows AI 增强
```

### 6.2 播放流程

1. 用户点击剧集 → `PlaybackLoader.load(drama, episode)`
2. 调用 `repository.resolve(drama, episode, quality)` → Go 返回 `PlaybackPlan`
3. `PlaybackPlan` 包含：媒体 URL、headers、cookie、时长、可用画质列表
4. 创建 `media_kit.Player`，打开媒体
5. 同时：DanmakuController 拉弹幕、PlaybackPreloader 预取下一集
6. 播放中：PlaybackRecovery 监控缓冲，失败时尝试 fallback

### 6.3 画质增强（仅 Windows）

```dart
// video_enhancement.dart
class VideoEnhancement {
  // 根据画质模式（自动/省电/清晰）和画面类型（真人/动漫）
  // 动态替换 mpv.conf 中的 shader 路径
  void apply(VideoEnhancementPreference prefs);

  // 支持 Anime4K 和 FSRCNNX 两种 shader
}
```

## 7. 数据模型（Dart 端）

### 7.1 Drama

```dart
class Drama {
  final String id;           // "站源:源站ID" 格式
  final String source;       // 站源标识 hongguo / yaguo / ...
  final String sourceId;     // 站源内部 ID
  final String title;
  final String description;
  final String cover;        // 封面 URL
  final int episodes;        // 已知集数
  final String category;     // 分类
  final bool? vipStatus;     // null=未知, true=VIP, false=免费
  final String heat;         // 热度
  final String views;        // 播放量
  final String onlineDate;   // 上线日期
  final List<String> tags;
  final String releaseStatus; // finished / ongoing / unknown
}
```

### 7.2 PlaybackPlan

播放器从 Go 核心获取的播放计划：

```dart
class PlaybackPlan {
  final String session;         // 播放会话 ID
  final String sessionDir;      // 会话临时目录
  final int quality;            // 选用画质索引
  final List<MediaSegment> segments; // HLS 分片或 MP4 段
  final Duration duration;      // 总时长
  final bool downloadable;      // 可下载标记
}
```

### 7.3 SourceSite

静态站源定义，含名称、描述、搜索能力：

```dart
class SourceSite {
  const SourceSite(this.id, this.name, this.description);
  final String id;              // hongguo, yaguo, ...
  final String name;            // 红果、芽果、...
  final String description;

  bool get onlineSearch;        // 是否支持在线搜索
  bool get pagedSearch;         // 是否支持分页搜索
  bool get searchSuggestions;   // 是否支持搜索联想
}
```

## 8. 电视适配

### 8.1 遥控器焦点

```dart
// television_controls.dart
class TelevisionFocus extends StatefulWidget {
  // 为遥控器自动滚动到焦点项
}

// FocusTraversalGroup 在 DuanjuApp.build 中配置
Shortcuts(
  shortcuts: const {
    SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.gameButtonA): ActivateIntent(),
    SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
  },
  child: FocusTraversalGroup(child: child!),
)
```

### 8.2 横屏布局

```dart
class AppOrientationScope extends InheritedWidget {
  final bool television; // TV 模式固定横屏
}
```

## 9. 文件命名与组织约定

| 约定 | 说明 |
| --- | --- |
| 页面文件以 `_screen.dart` 结尾 | home_screen.dart, detail_screen.dart |
| 控制器以 `_controller.dart` 结尾 | danmaku_controller.dart, lan_controller.dart |
| 数据模型以 `_models.dart` 或直接类文件 | models.dart, danmaku_models.dart |
| 偏好相关以 `_preferences.dart` | playback_preferences.dart |
| 下载 / 合并相关以 `download` 或 `merge` 开头 | media_merge.dart, batch_downloads.dart |

## 10. 关键依赖流向

```
main.dart
  └─ NativeRepository (core_bridge.dart) → Go FFI
  └─ LocalStore (local_store.dart) → SharedPreferences
  └─ MediaLibrary (media_library.dart) → 文件系统
  └─ LanController (lan_controller.dart) → nsd 包

home_screen.dart
  └─ NativeRepository.catalog()
  └─ NativeRepository.categories()
  └─ NativeRepository.rankingBoards()

detail_screen.dart
  └─ NativeRepository.detail()
  └─ NativeRepository.resolve()  // 进入播放器前预取

player_screen.dart
  └─ media_kit (播放)
  └─ PlaybackLoader → NativeRepository.resolve()
  └─ DanmakuController → NativeRepository.danmaku()
  └─ PlaybackPreloader → NativeRepository.preload()
  └─ VideoEnhancement (Windows)
```
