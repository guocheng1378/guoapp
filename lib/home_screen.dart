import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import 'activation/activation_flow.dart';
import 'app_layout.dart';
import 'about_card.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'folme.dart';
import 'fog_tuning.dart';
import 'glass.dart';
import 'haptics.dart';
import 'glass_menu.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'home_carousel.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'js_module_screen.dart';
import 'route_transition.dart';
import 'detail_screen.dart';
import 'playback_launch_screen.dart';
import 'downloads_screen.dart';
import 'download_summary.dart';
import 'local_store.dart';
import 'ui_scale.dart';
import 'lan_screen.dart';
import 'live_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'home_feed_models.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'search_input.dart';
import 'search_suggestion.dart';
import 'source_search.dart';
import 'sources_screen.dart';
import 'text_input_dismiss.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'saved_library.dart';
import 'app_icons.dart';
import 'follow_updater.dart';
import 'motion.dart';

/// 手机/iOS 悬浮玻璃底栏的内容底部避让高度（栏高 68 + 浮动下边距 12 + 余量）。
const _floatingNavInset = 96.0;

/// 站源长按菜单与 TV 站源菜单中「电视直播」条目的哨兵值。
const _liveEntryChoice = '__live_tv__';

/// 站源菜单「切换分类…」条目的哨兵值（显性跨类入口，见 _showSourceMenu）。
const _switchCategoryChoice = '__switch_category__';

/// 搜索结果是否可放行。
///
/// 服务端精准搜索（红果、剧果/黄果AI/黑桃）信任服务端结果；maccms 系
/// 视频源（duanjuPaged）的 wd 搜索是模糊匹配、会返回标题与关键词无关的
/// 条目，本地剧库匹配 / 忽略 query 的目录接口（真果·鉴、韩小圈等）同理，
/// 必须再过一遍 matchesDramaQuery 复核。旧实现把 maccms 在线搜索结果
/// 无条件放行，视频类搜索因此混入大量不匹配剧集。
bool acceptsSearchHit(Drama drama, String query, SourceSite? site) {
  if (query.isEmpty) return true;
  final trustedServerSearch =
      (site?.onlineSearch ?? false) && !(site?.duanjuPaged ?? false);
  if (trustedServerSearch) return true;
  return matchesDramaQuery(drama, query);
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({
    super.key,
    required this.repository,
    required this.store,
    this.backClock,
  });
  final AppRepository repository;
  final LocalStore store;

  /// 二次退出窗口的时钟源（测试注入，缺省系统时钟）。
  final DateTime Function()? backClock;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with RouteAware {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  // 手机横屏沉浸当前态（_syncImmersive 幂等守卫；dispose 时恢复）。
  bool _immersive = false;
  late SourceSite _source;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _searchVisible = false;
  /// 只有用户主动点开搜索才自动聚焦。换源搜索（播放失败的兜底）、
  /// 起播后返回首页都不能再自动聚焦，否则输入法会跟着 opaque:false
  /// 的播放薄壳/返回转场重新弹出来。
  bool _searchAutoFocus = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  FollowUpdater? _followUpdater;
  /// 上次弹「追剧更新」提醒时的累计未读部数：同一累计值不重复弹。
  int _lastFollowUpdateNotice = 0;
  // 更新提醒「去看看」：给追剧页的一次性筛选请求（'updates'=有更新）。
  // 离开追剧页即清空，避免下次切回来还停在筛选态。
  final _libraryFilter = ValueNotifier<String>('');
  // 首页继续观看条每次启动提醒一次：条目真正出现起 8 秒无操作自动收起，
  // 点条目去播放或点「不再提醒」立即收起，收起后本会话不再出现。
  bool _resumeDismissed = false;
  Timer? _resumeHideTimer;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  // 首页「模糊封面」当前状态（移植自 Xanerix/guoapp 29e1afe）：
  // 按钮是否出现由设置决定，开屏是否先模糊由另一个设置决定。
  bool _blurCovers = false;

  // 顶栏眼睛按钮移除后，「是否糊封面」只看当前源的记忆（在「已装模块」
  // 页按分组开关写入）。
  bool get _blurring => _blurCovers && !AppLayout.isTelevision(context);
  // 下载全局汇总：已消费过的批次结束事件序号（防重复弹提示）。
  int _seenSummaryBatch = 0;
  // 手机端二次退出保护：首次按返回的时间戳，2 秒内再按才真正退出。
  DateTime? _lastBackAt;

  // 回顶雾面钮（FogFab）：滚动方向点亮/熄灭，过渡由组件内弹簧完成。
  // 停止滚动 2s 后自动隐藏（每次滚动事件重置计时）。
  //
  // 用 ValueNotifier 而不是 bool + setState：这两个值在滚动中会随方向
  // 翻转，`setState` 会把整个 HomeScreen（网格 + 分类条 + 四个 tab）重建
  // 一遍——滚动起手那一下掉帧就是这么来的。现在只重建这颗按钮。
  double _fabPrevPixels = 0;
  final ValueNotifier<bool> _fabShown = ValueNotifier<bool>(false);
  final ValueNotifier<bool> _fabLit = ValueNotifier<bool>(false);
  Timer? _fabHideTimer;

  /// 接近度信号（demo 真值）：滚动距离/50 clamp 0..1，驱动顶栏雾玻璃
  /// 岛与分类胶囊白描边亮起；滚回顶部（px=0）熄灭。同值不通知。
  final ValueNotifier<double> _prox = ValueNotifier<double>(0);

  // 调参台「雾面高度」延伸量：吸顶头 extent 与雾面挂点高度随之加
  // 高（0=现状）。仅此参数需要整页 rebuild（extent 变化），其余调
  // 参维度由 TopFog 内部监听自行重建。
  double _fogHeight = 0;
  bool _showRecommendations = false;
  /// 网格错峰入场动画是否已演过一次（只有首屏演，之后切分类/切源直接出图）。
  bool _entranceDone = false;
  bool _catalogLoadScheduled = false;
  // 远端主页（站点 /v1/feed/home 自描述区块）：分类条与轮播的内容源。
  HomeFeed? _homeFeed;
  bool _homeFeedLoading = false;
  int _homeFeedGeneration = 0;
  int _homeSectionPage = 1;
  final _filtersKey = GlobalKey<RemoteRowState>();
  final _gridKey = GlobalKey<RemoteGridState>();
  final _navKey = GlobalKey<RemoteListState>();
  final _appBarFocus = FocusNode(debugLabel: 'tv-appbar');
  final _sourceMenuKey = GlobalKey(debugLabel: 'source-menu-anchor');
  final _moreMenuKey = GlobalKey(debugLabel: 'more-menu-anchor');
  final _sortMenuKey = GlobalKey(debugLabel: 'sort-menu-anchor');
  final _selectionFocus = FocusNode(debugLabel: 'tv-selection');

  // 首页站源菜单按四分类组织（与站源管理页同口径）：
  // 短剧类 / 视频类 / 黄果类 / 成人类，无「全部站源」聚合项；默认落在当前源所在类。
  // 黄果类与成人类整组隐藏，仅在「关于」浮卡连点 5 次解锁后显示。
  // 搜索分组与站源菜单/管理页同口径，不把隐藏源搜出来。
  List<SourceSite> get _visibleSources {
    final unlocked = widget.store.restrictedUnlocked;
    return widget.store.sources
        .where(
          (source) =>
              unlocked ||
              !(source.inHuangguoCategory || source.isAdultSource),
        )
        .toList();
  }

  List<SourceGroup> get _sourceCategories {
    final sources = _visibleSources;
    // 用户定调（2026-11-18）：分组里的源按使用频率排，不再把某个源硬置顶。
    // 未使用过（次数 0）的源保持定义顺序，避免每次 build 时相互跳动。
    final usage = widget.store.sourceUsage;
    final huangguo = SourceSite.orderByUsage(
      sources.where((source) => source.inHuangguoCategory),
      usage,
    );
    final rest = sources
        .where((source) => !source.inHuangguoCategory)
        .toList();
    final shortDrama = SourceSite.orderByUsage(
      rest.where((source) => source.isShortDrama),
      usage,
    );
    final video = SourceSite.orderByUsage(
      rest.where((source) => source.isVideoSource),
      usage,
    );
    final local = SourceSite.orderByUsage(
      rest.where((source) => source.isLocalSource),
      usage,
    );
    final adult = SourceSite.orderByUsage(
      rest.where((source) => source.isAdultSource),
      usage,
    );
    return [
      if (shortDrama.isNotEmpty) SourceGroup('cat-short', '短剧类', shortDrama),
      if (video.isNotEmpty) SourceGroup('cat-video', '视频类', video),
      if (local.isNotEmpty) SourceGroup('cat-local', '本地类', local),
      if (huangguo.isNotEmpty)
        SourceGroup('cat-huangguo', '黄果类', huangguo),
      if (adult.isNotEmpty) SourceGroup('cat-adult', '成人类', adult),
    ];
  }

  // 首页浏览始终加载当前选中源（单源），不在分类间聚合；
  // 搜索一律只圈定**当前源所在分组**：短剧类下搜「霸总」同时搜红果 +
  // 其余短剧类站源，绝不跨到视频类/黄果类/成人类。
  //
  // 曾经的「全源搜索」例外（播放失败时跨全部已启用站源）已取消：18 个源
  // 逐个等网络返回，实测慢到不可用；换源兜底留在同组内已经够用。
  SourceGroup get _group =>
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  SourceGroup get _searchGroup {
    final sameClass = _visibleSources
        .where((source) => source.classKey == _source.classKey)
        .toList();
    // 当前源恰是隐藏源（未解锁黄果/成人类）时 visible 会把它滤掉，
    // 至少保住当前源，避免搜索组为空导致整页不发起请求。
    if (sameClass.isEmpty) sameClass.add(_source);
    return SourceGroup(
      'class-${_source.classKey}-search',
      SourceSite.classLabel(_source.classKey),
      sameClass,
    );
  }
  bool get _onlineSearch =>
      _searchGroup.sources.any((source) => source.onlineSearch);
  // 搜索建议词库服务于短剧场景（词库来自红果），只在短剧类源下请求；
  // 视频类站源不拿短剧建议词来提示。真果·鉴接站内建议（/v1/suggest）。
  bool get _searchSuggestions => _group.sources.any(
    (source) => source.isShortDrama || source.id == 'dongpiandi',
  );
  String get _searchHint {
    if (!_onlineSearch) {
      return '筛选本机已更新剧库';
    }
    return '搜索${_searchGroup.name}';
  }

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories {
    // 站点板块、源站上报分类、条目池分类、本地题材词表、长短剧档是
    // 几路独立来源；板块标题截前两字后可能与源站分类同名（「电影热播」
    // →「电影」），旧实现直接展开零去重，条上出现两个同名 chip 且内容
    // 不同/重复。按归一化名去重，保留远端主页优先的原始顺序。
    return dedupeCategories(<CatalogCategory>[
      CatalogCategory.all,
      ..._remoteHomeCategories,
      if (_group.id == 'hongguo')
        const CatalogCategory(_recommendationCategory, '推荐'),
      ..._categories.where((entry) => entry.id.isNotEmpty),
    ]);
  }

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesError = error;
    });
    // 站点板块分类不属于源站分类列表，不能被「分类不存在」逻辑踢回全部。
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        remoteSectionIdOf(_category) == null &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    // 下拉刷新同时刷新站点板块（站点改了板块名/增删板块即刻生效）。
    await _loadHomeFeed(force: true);
    if (mounted) await _load(force: true);
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  /// 长按站源岛：弹出分类选择菜单，点选一类即切到该类上次用过的源
  /// （没有记忆才回落到该类第一个源）；
  /// 末尾固定附「电视直播」条目（直播不进站源体系，见 _openLiveScreen）。
  Future<void> _pickSourceCategory() async {
    final categories = _sourceCategories;
    final picked = await showGlassMenu<Object>(
      context: context,
      anchorKey: _sourceMenuKey,
      entries: [
        for (final category in categories)
          GlassMenuEntry<Object>(
            category,
            category.name,
            checked: category.sources.any((source) => source.id == _source.id),
          ),
        GlassMenuEntry<Object>(_liveEntryChoice, '电视直播'),
      ],
    );
    if (picked == _liveEntryChoice) {
      _openLiveScreen();
      return;
    }
    if (picked is SourceGroup && picked.sources.isNotEmpty) {
      _changeSource(_preferredSourceIn(picked));
    }
  }

  /// 分组的落点源：优先该组上次选中的源，其次该组第一个可用源。
  /// 记忆里的源已被关闭/下线时 sourceForGroup 返回 null，自动回落。
  SourceSite _preferredSourceIn(SourceGroup group) {
    final remembered = widget.store.sourceForGroup(group.id);
    return group.sources.firstWhere(
      (source) => source.id == remembered,
      orElse: () => group.sources.first,
    );
  }

  /// 站源所属分组的 id（不在任何分组里返回空串）。
  String _groupIdOf(SourceSite source) {
    for (final group in _sourceCategories) {
      if (group.sources.any((site) => site.id == source.id)) return group.id;
    }
    return '';
  }

  /// 打开电视直播页；自填直播源从本地配置读出经 liveUrls 传给 Go 核心合并。
  void _openLiveScreen() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LiveScreen(
          repository: widget.repository,
          liveUrls: widget.store.liveSourceUrls,
          liveSources: widget.store.liveSourceEntries,
        ),
      ),
    );
  }

  /// 手机端站源切换玻璃菜单（TV 端走 PopupMenuButton 实底保焦点导航）。
  /// 只列当前源所在分类下的源；末尾附「切换分类…」显性入口——
  /// 长按换类的手势很多人发现不了，菜单里给一条明确路径。
  Future<void> _showSourceMenu() async {
    final categories = _sourceCategories;
    if (categories.expand((category) => category.sources).length <= 1) return;
    final current = categories.firstWhere(
      (category) => category.sources.any((source) => source.id == _source.id),
      orElse: () => categories.first,
    );
    final picked = await showGlassMenu<Object>(
      context: context,
      anchorKey: _sourceMenuKey,
      entries: [
        GlassMenuEntry<Object>(
          current.sources.first,
          current.name,
          header: true,
        ),
        for (final source in current.sources)
          GlassMenuEntry<Object>(
            source,
            source.name,
            checked: source.id == _source.id,
          ),
        GlassMenuEntry<Object>(_switchCategoryChoice, '切换分类…'),
      ],
    );
    if (picked == _switchCategoryChoice) {
      await _pickSourceCategory();
      return;
    }
    if (picked is SourceSite) _changeSource(picked);
  }

  void _onMoreSelected(String value) {
    if (value == 'rankings') {
      _openRankings();
    } else if (value == 'modules') {
      _manageModules();
    } else if (value == 'sources') {
      _manageSources();
    } else if (value == 'settings') {
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => SettingsScreen(
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
    } else if (value == 'users') {
      _openUserManagement();
    } else if (value == 'display') {
      _chooseDisplayMode();
    } else if (value == 'about') {
      // 手机端：屏幕居中的轻量信息浮卡——无 barrier 压暗、点空白关闭，
      // 含检查更新入口；TV 保留玻璃弹窗（遥控焦点导航可靠）。
      if (AppLayout.isTelevision(context)) {
        showDialog<void>(
          context: context,
          builder: (context) => GlassDialogShell(
            child: AboutDialog(
              applicationName: appName,
              applicationVersion: AppLayout.versionOf(context),
              applicationIcon: AppIcon(AppIcons.playCircleFilled, size: 48, color: Color(0xFFFF765F)),
              children: [
                const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
              ],
            ),
          ),
        );
      } else {
        showAboutCard(
          context: context,
          anchorKey: _moreMenuKey,
          appName: appName,
          version: AppLayout.versionOf(context),
          onActivate: () async {
            // 5 连点 = 弹激活页；设备本已激活或本次激活成功，都解锁隐藏站源。
            final wasActive = await activationActive();
            final activated = await showActivationPage(context);
            if (!mounted) return;
            if (wasActive || activated) _unlockRestrictedSources();
          },
        );
      }
    }
  }

  /// 用户管理入口：未激活设备先弹激活页，激活成功（或本已激活）才放行。
  Future<void> _openUserManagement() async {
    final activated =
        await activationActive() || await showActivationPage(context);
    if (!mounted || !activated) return;
    Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => ProfilesScreen(store: widget.store),
      ),
    );
  }

  /// 解锁黄果类/成人类隐藏站源并提示。
  void _unlockRestrictedSources() {
    widget.store.setRestrictedUnlocked(true);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已显示黄果类与成人类站源')),
    );
  }

  /// 顶栏图标按钮：尺寸跟随界面缩放（clamp 0.9~1.1）。
  ///
  /// AppIcon 的 size 是固定值、不读 textScaler，必须显式乘；IconButton 的
  /// padding/constraints 也要一起缩，否则外框仍是 48dp（只缩了图标）。
  Widget _navIcon(
    String icon, {
    Key? key,
    required String tooltip,
    required VoidCallback onPressed,
    Color? color,
  }) {
    final factor = UiScale.buttonFactor(context);
    return IconButton(
      key: key,
      tooltip: tooltip,
      onPressed: onPressed,
      iconSize: 24 * factor,
      padding: EdgeInsets.all(12 * factor),
      constraints: BoxConstraints(
        minWidth: 48 * factor,
        minHeight: 48 * factor,
      ),
      icon: AppIcon(icon, size: 24 * factor, color: color),
    );
  }

  /// 顶栏独立玻璃胶囊岛：手机端把标题/按钮各自包成悬浮岛，
  /// TV/桌面保持原样（glass=false）。
  Widget _navPill(Widget child, {required bool glass}) {
    if (!glass) return child;
    return Padding(
      // 颗间距 10px：四颗是独立胶囊岛（对齐小米主题商店顶栏图标钮），
      // 之前 left:4 等于没有间隙，三颗贴死读作一坨。
      padding: EdgeInsets.only(left: 10 * UiScale.buttonFactor(context)),
      // demo 雾玻璃配方（FogPill）：σ 真磨砂 + 半透玻璃底 + 白描边
      // 随滚动亮起（回顶熄灭）。不再用瓷面岛——瓷面半透白瓷（0.72 白）
      // 叠在雾面上读作一层透明膜，也让顶栏区域雾感与分类条不一致。
      // Folme 果冻按压：按下 0.96、松手弹簧弹回（轻过冲）。
      //
      // inheritBlur：顶栏区域已有整条 TopFog 模糊（状态栏→顶栏一条
      // BackdropFilter），四颗胶囊若各自再带一层 blur = 同层双采样 →
      // 整体发灰。默认继承整条模糊（胶囊只画 tint + 柔光特征）；
      // 只有雾面高度被调成负档（整条模糊盖不满顶栏）时才让胶囊自带磨砂。
      child: FogPill(
        prox: _prox,
        inheritBlur: _fogHeight >= 0,
        child: FolmePress(child: child),
      ),
    );
  }

  Future<void> _showMoreMenu({required bool narrow}) async {
    final value = await showGlassMenu<String>(
      context: context,
      anchorKey: _moreMenuKey,
      entries: [
        // 「更新剧库」入口已移除：首页内容区有下拉刷新，菜单不再重复。
        // 「榜单」已提到顶栏图标，菜单不再重复。
        if (widget.repository.supportsSourceManagement)
          const GlassMenuEntry('modules', '站源模块'),
        const GlassMenuEntry('users', '用户管理'),
        const GlassMenuEntry('settings', '设置与备份'),
        const GlassMenuEntry('display', '界面模式'),
        const GlassMenuEntry('about', '关于$appName'),
      ],
    );
    if (value != null) _onMoreSelected(value);
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      AppHaptics.selection();
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _searchVisible = false;
        _submittedQuery = '';
      });
      return;
    }
    if (_category == category && !_showRecommendations) return;
    AppHaptics.selection();
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _swipeCategory(DragEndDetails details) {
    final velocity = details.primaryVelocity ?? 0;
    if (velocity.abs() < 240) return;
    final categories = _displayCategories;
    final index = categories.indexWhere(
      (entry) => entry.id == _displayCategory,
    );
    final next = index + (velocity < 0 ? 1 : -1);
    if (next >= 0 && next < categories.length) {
      _changeCategory(categories[next].id);
    } else {
      // 横滑到头也要有反馈，别像「划了没反应」。
      AppHaptics.light();
    }
  }

  void _toggleSearch() {
    if (AppLayout.isTelevision(context)) {
      _televisionSearch();
      return;
    }
    if (_showRecommendations) _changeCategory('');
    final hadQuery = _search.text.isNotEmpty;
    setState(() {
      _searchVisible = !_searchVisible;
      _searchAutoFocus = _searchVisible;
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible) {
      unawaited(dismissPlaybackTextInput());
    }
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  /// 站源模块页（含从 zip 安装与内置站源管理入口）。
  void _manageModules() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => JsModuleScreen(
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialCategory: _source.classKey,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          // 站源管理入口要看全部站点卡片（含模块源/自定义源），与播放失败
          // 页的「站源诊断」同口径；默认 builtin 只列直播/TVBox 会像空白页。
          mode: SourcesScreenMode.all,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Future<void> _chooseDisplayMode() async {
    // 电视模式：遥控可导航的选项对话框（与排序/about 同范式）。
    // 不能走锚定 _moreMenuKey 的玻璃菜单——该 Key 只挂在手机模式的 ⋮
    // 岛上，电视模式未挂载，锚点缺失时 showGlassMenu 静默返回、菜单
    // 根本不弹（切到电视模式后曾因此无法切回手机模式）。
    if (AppLayout.isTelevision(context)) {
      final selection = await showDialog<String>(
        context: context,
        builder: (_) => TelevisionActionDialog(
          title: '界面模式',
          options: [
            for (final mode in const {
              'auto': '自动识别设备',
              'television': '电视 / 遥控器',
              'standard': '手机 / 电脑',
            }.entries)
              TelevisionAction(
                value: mode.key,
                label: mode.value,
                description: switch (mode.key) {
                  'auto' => '按设备自动选择手机或电视界面',
                  'television' => '大屏布局 + 遥控器方向键导航',
                  _ => '触屏布局 + 底部导航栏',
                },
                icon: switch (mode.key) {
                  'auto' => AppIcon(AppIcons.devices),
                  'television' => AppIcon(AppIcons.tv),
                  _ => AppIcon(AppIcons.smartphone),
                },
                // 与手机端玻璃菜单同口径：当前档位打勾，
                // 避免「选了但界面没变」时无法确认当前状态。
                checked: mode.key == widget.store.displayMode,
              ),
          ],
        ),
      );
      if (selection != null && mounted) {
        await saveUserChange(
          context,
          () => widget.store.setDisplayMode(selection),
        );
      }
      return;
    }
    // 手机模式：与「设置与备份」同款玻璃胶囊菜单：独立胶囊列+勾选态，
    // 无整块玻璃壳（GlassDialogShell 方块玻璃已废弃）。
    final selection = await showGlassMenu<String>(
      context: context,
      anchorKey: _moreMenuKey,
      entries: [
        for (final mode in const {
          'auto': '自动识别设备',
          'television': '电视 / 遥控器',
          'standard': '手机 / 电脑',
        }.entries)
          GlassMenuEntry(
            mode.key,
            mode.value,
            checked: mode.key == widget.store.displayMode,
          ),
      ],
    );
    if (selection != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setDisplayMode(selection),
      );
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _onlineSearch
            ? '搜索${_searchGroup.name}'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        // TV 端建议点选=搜索该词（遥控不适合直达播放链路）。
        suggestions: _searchSuggestions
            ? (query) =>
                  widget.repository.suggestions(query, source: _source.id)
            : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  /// 站内建议直达播放（真果·鉴 /v1/suggest 的 intent=play 建议）：
  /// 用 variant_id 构造最小剧目，薄壳起播（详情/错误/VIP 由
  /// PlaybackLaunchScreen 处理）；异常回退普通搜索。
  Future<void> _playSuggestion(SearchSuggestion suggestion) async {
    if (suggestion.variantId.isEmpty) {
      _submitSearch(suggestion.submitText);
      return;
    }
    final drama = Drama(
      id: 'dongpiandi:${suggestion.variantId}',
      source: 'dongpiandi',
      title: suggestion.label,
    );
    try {
      await openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      );
    } catch (_) {
      if (!mounted) return;
      _submitSearch(suggestion.submitText);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != 0) {
      setState(() => _tab = 0);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  /// 当前源是否走远端主页（/v1/feed/home 自描述区块）：是则分类条里出现
  /// 站点板块、轮播播站点主推板块，本地不维护任何板块清单。
  String? get _remoteHomeFeedSource {
    for (final source in _group.sources) {
      if (_remoteHomeSources.contains(source.id)) return source.id;
    }
    return null;
  }

  /// 支持远端主页板块的站源（/v1/feed/home 自描述区块）。
  static const _remoteHomeSources = <String>{'dongpiandi'};

  /// 分类 id 前缀：命中即表示这是站点下发的一个板块（不是源站分类）。
  static const _remoteSectionPrefix = 'home:';

  /// 当前选中的分类是不是站点板块；是则返回板块 id。
  String? remoteSectionIdOf(String category) {
    if (!category.startsWith(_remoteSectionPrefix)) return null;
    final id = category.substring(_remoteSectionPrefix.length);
    return id.isEmpty ? null : id;
  }

  /// 站点板块在分类条里的分类项：名称取板块标题前两个字（「韩剧在追」→
  /// 「韩剧」），站点改名/增删即刻生效。
  List<CatalogCategory> get _remoteHomeCategories => [
    for (final section in _homeFeed?.secondary ?? const <HomeSection>[])
      CatalogCategory(
        '$_remoteSectionPrefix${section.id}',
        _shortSectionLabel(section.title),
      ),
  ];

  static String _shortSectionLabel(String title) {
    final trimmed = title.trim();
    if (trimmed.isEmpty) return trimmed;
    final characters = trimmed.characters.toList();
    return characters.length <= 2
        ? trimmed
        : characters.take(2).join();
  }

  /// 轮播内容：站点主推板块（「大家都在看」）的卡片。
  List<Drama>? get _remoteCarouselItems =>
      _homeFeed?.primary?.items.take(HomeCarousel.maxItems).toList();

  Future<void> _loadHomeFeed({bool force = false}) async {
    final generation = ++_homeFeedGeneration;
    final source = _remoteHomeFeedSource;
    final groupId = _group.id;
    if (source == null) {
      if (_homeFeed != null && mounted) setState(() => _homeFeed = null);
      return;
    }
    // 不再用布尔守卫丢弃后续请求：快速连切时它会让第二次刷新直接
    // 不发起，旧源板块一直留在新源首页。改用代次让旧响应作废。
    _homeFeedLoading = true;
    try {
      final feed = await widget.repository.homeFeed(source, force: force);
      if (!mounted ||
          generation != _homeFeedGeneration ||
          _group.id != groupId) {
        return;
      }
      setState(() => _homeFeed = feed);
    } catch (_) {
      // 远端主页拉不到就退回纯本地浏览（分类条不出现站点板块），
      // 首页主体不受影响，也不弹错。
    } finally {
      if (generation == _homeFeedGeneration) _homeFeedLoading = false;
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onCatalogScroll);
    _scroll.addListener(_onFabScroll);
    _source = SourceSite.byId(widget.store.source) ?? SourceSite.hongguo;
    // 开屏模糊：按「当前源」恢复上次眼睛按钮留下的状态（每个源各记各的），
    // 这个源没有记忆才回落到「开屏自动模糊」设置。
    _blurCovers = widget.store.blurCoversFor(_source.id);
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    // 启动同步：调参台 load() 在首页构建前已写入保存值，监听器只报
    // 「变化」——不先取当前值，雾面高度启动永远停在 0（用户症状根因）。
    _fogHeight = FogTuningStore.state.value.fogHeight;
    FogTuningStore.state.addListener(_onFogTuning);
    // 播放失败/简介不可用时，各页面把「换个源找」请求写到总线，
    // 首页是根路由，负责切回发现页并按剧名在本分组内搜一遍。
    SourceSearchBus.pending.addListener(_onSourceSearchRequest);
    // 请求可能在首页挂载前就写入（冷启动直接进播放器/简介页）：
    // 注册后主动取一次，否则要等到下一次写入才唤醒。
    _onSourceSearchRequest();
    // 下载完成/失败全局汇总：差量轮询引擎常驻，底栏下载入口亮未读徽标，
    // 一批任务全部结束时弹一次汇总提示。
    unawaited(DownloadSummary.instance.bind(widget.repository, widget.store));
    DownloadSummary.instance.addListener(_onSummaryChanged);
    _seenSummaryBatch = DownloadSummary.instance.batch;
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
      // 远端主页板块（分类条与轮播的内容源）异步补上，失败自动退回本地浏览。
      unawaited(_loadHomeFeed());
    } else {
      _loading = false;
    }
    // 追剧更新后台巡检：启动让路 30s 后首轮，之后每 30 分钟一轮
    // （每轮最多 10 部、6h 去重、失败指数退避），「N 集更新」角标
    // 自动亮起。测试环境（Motion.inTest）不启动——避免 fake-async
    // Pending Timer 与网络依赖；真实场景 Timer 已在 dispose 中取消。
    if (!Motion.inTest) {
      _followUpdater = FollowUpdater(
        widget.repository,
        widget.store,
        onUpdated: (updated) {
          if (!mounted || updated <= 0) return;
          final total = widget.store.favorites
              .where(
                (drama) => widget.store.following(drama.id)?.hasUpdates == true,
              )
              .length;
          // 文案报本轮新增（旧文案报累计未读，长期不点开追剧页时每
          // 30 分钟只要有任意一部涨集数就重弹同一条）；累计值没涨就
          // 不重复打扰，用户读掉后基准回落，下次真新增会再提醒。
          if (total <= 0 || total <= _lastFollowUpdateNotice) {
            _lastFollowUpdateNotice = total;
            return;
          }
          _lastFollowUpdateNotice = total;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('追剧新增 $updated 部更新'),
              action: SnackBarAction(
                label: '去看看',
                onPressed: _showFollowUpdates,
              ),
              // 右侧 X：用户不想现在看时可直接关闭
              showCloseIcon: true,
            ),
          );
        },
      )..start();
    }
  }

  /// 手机横屏沉浸+紧凑化同步：进入横屏切 immersiveSticky（状态栏隐藏、
  /// 下滑临时呼出），回竖屏恢复 edgeToEdge。幂等，可在 build 中每帧调用。
  void _syncImmersive(bool compact) {
    if (_immersive == compact) return;
    _immersive = compact;
    // try/catch 包装而非 catchError：Future<void>.catchError 的 handler
    // 返回 null 在部分运行时会抛 ArgumentError（fake_async 实测）。
    unawaited(() async {
      try {
        await SystemChrome.setEnabledSystemUIMode(
          compact ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        );
      } catch (_) {}
    }());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute<dynamic>) {
      appRouteObserver.subscribe(this, route);
    }
  }

  /// 上层路由（播放页/详情/设置）pop 回来时，FocusScope 会把焦点还给
  /// 栈底搜索框，输入法随之重新弹出。这里统一释放，杜绝「出来又弹」。
  @override
  void didPopNext() {
    if (!AppLayout.isTelevision(context)) {
      _searchAutoFocus = false;
      unawaited(dismissPlaybackTextInput());
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    if (_immersive) _syncImmersive(false);
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    _followUpdater?.dispose();
    _libraryFilter.dispose();
    _resumeHideTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _scroll.removeListener(_onFabScroll);
    _fabHideTimer?.cancel();
    _scroll.dispose();
    _prox.dispose();
    _fabShown.dispose();
    _fabLit.dispose();
    FogTuningStore.state.removeListener(_onFogTuning);
    SourceSearchBus.pending.removeListener(_onSourceSearchRequest);
    DownloadSummary.instance.removeListener(_onSummaryChanged);
    // 2s 轮询由首页唯一持有：离开时停掉，别留常驻 timer 空转
    // （也是一批 widget 测试 teardown 报 pending timer 的来源）。
    DownloadSummary.instance.unbind();
    _appBarFocus.dispose();
    _selectionFocus.dispose();
    super.dispose();
  }

  void _onCatalogScroll() {
    if (!mounted ||
        _showRecommendations ||
        !_hasMore ||
        _loading ||
        _loadingMore ||
        !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.5).clamp(320.0, 900.0);
    if (position.extentAfter > threshold || _catalogLoadScheduled) return;
    _catalogLoadScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _catalogLoadScheduled = false;
      if (!mounted ||
          _showRecommendations ||
          !_hasMore ||
          _loading ||
          _loadingMore ||
          !_scroll.hasClients) {
        return;
      }
      unawaited(_load(more: true));
    });
  }

  /// 回顶雾面钮：滚出首屏（>400px）浮现；上行点亮、下行熄灭，
  /// 方向量带 ±4px 迟滞防抖，明暗过渡交给 FogFab 内部弹簧。
  /// 滚动中常显；最后一次滚动事件 2s 后自动隐藏，再滚立即重现。
  /// 调参台「雾面高度」变化回调：值变了才 setState（extent 与雾面
  /// 挂点高度需整页 rebuild）；拖动其它滑块零开销。
  void _onFogTuning() {
    final h = FogTuningStore.state.value.fogHeight;
    if (h != _fogHeight && mounted) setState(() => _fogHeight = h);
  }

  /// 下载入口图标：有未读汇总（新完成/失败任务）时套数字徽标。
  Widget _downloadIcon() {
    final unread = DownloadSummary.instance.unread;
    final icon = AppIcon(AppIcons.download);
    return unread > 0 ? Badge(label: Text('$unread'), child: icon) : icon;
  }

  /// 下载全局汇总回调：刷新底栏未读徽标；一批任务全部结束时弹一次
  /// 汇总提示（正看着下载页则不打扰）。
  void _onSummaryChanged() {
    if (!mounted) return;
    final summary = DownloadSummary.instance;
    if (summary.batch > _seenSummaryBatch) {
      _seenSummaryBatch = summary.batch;
      final text = summary.batchText;
      if (text.isNotEmpty &&
          _tab != 3 &&
          widget.store.canDownload &&
          !Motion.inTest) {
        ScaffoldMessenger.of(context)
          ..hideCurrentSnackBar()
          ..showSnackBar(
            SnackBar(
              content: Text(text),
              action: SnackBarAction(
                label: '查看',
                onPressed: () => _changeTab(3),
              ),
            ),
          );
      }
    }
    setState(() {});
  }

  /// 雾面挂点实际高度：负档收窄（底缘上移），clamp≥0 防负高度断言。
  double _fogBandHeight(double base) {
    final h = base + _fogHeight;
    return h < 0 ? 0 : h;
  }

  void _onFabScroll() {
    if (!_scroll.hasClients) return;
    final pixels = _scroll.position.pixels;
    final delta = pixels - _fabPrevPixels;
    _fabPrevPixels = pixels;
    var lit = _fabLit.value;
    // 方向判定加滞回：±4px 在惯性尾段会反复翻转。
    if (delta < -8) {
      lit = true;
    } else if (delta > 8) {
      lit = false;
    }
    final shown = pixels > 400;
    // 停止滚动计时：滚出首屏期间每次滚动事件都重置，2s 静默后隐藏；
    // 滚回首屏内直接取消（按钮随即隐藏，无需计时）。
    _fabHideTimer?.cancel();
    if (shown) {
      _fabHideTimer = Timer(const Duration(seconds: 2), () {
        if (!mounted) return;
        _fabShown.value = false;
      });
    }
    if (shown == _fabShown.value && lit == _fabLit.value) return;
    _fabShown.value = shown;
    _fabLit.value = lit;
  }

  /// 接近度信号更新（demo 真值）：滚动距离/50 clamp 0..1。50px 内
  /// 线性点亮全部顶栏岛与分类胶囊描边，回顶熄灭；ValueNotifier 同值
  /// 不通知，滚动稳态零开销。走 ScrollNotification 冒泡——全部 tab
  /// 的滚动（首页/追剧/最近/下载）都驱动同一信号；横滑列表过滤掉。
  ///
  /// 该信号只被玻璃面的 `CustomPainter.repaint` 消费（见
  /// `SoftGlassSurface.edgeProx`）：值变了只重绘 1px 描边，不重建子树、
  /// 不重采样 backdrop。旧实现由 `ListenableBuilder` 包整颗胶囊，滚动的
  /// 头 50px 会重建两三百次子树——那才是滚动卡顿的主源。
  bool _onBodyScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    final raw = (n.metrics.pixels / 50).clamp(0.0, 1.0);
    // 量化成 10 档：描边亮度 10 档肉眼无差，重绘频率降一个数量级。
    final next = (raw * 10).round() / 10;
    if (_prox.value != next) _prox.value = next;
    return false;
  }

  void _backToTop() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      0,
      duration: MotionDurations.hero,
      curve: MotionCurves.standard,
    );
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final query = _onlineSearch ? _search.text.trim() : '';
    // 浏览（无关键词）走当前单源；有关键词只按当前源所在分组搜索。
    final group = query.isEmpty ? _group : _searchGroup;
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(CatalogPage result, {bool cached = false}) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = cached && !result.fresh;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final view = widget.store.catalogView;
      // 站点板块分类：直接按站点给的 browse 参数翻页（本地不做类别推断）。
      final sectionId = query.isEmpty ? remoteSectionIdOf(_category) : null;
      if (sectionId != null) {
        final page = more ? _homeSectionPage + 1 : 1;
        final result = await widget.repository.homeSection(
          _source.id,
          sectionId,
          page: page,
        );
        if (!mounted || generation != _generation) return;
        setState(() {
          _items = more ? _appendPage(_items, result.items) : result.items;
          _hasMore = result.hasMore;
          _homeSectionPage = page;
          _submittedQuery = query;
          _loading = false;
          _loadingMore = false;
          _error = result.warning.isEmpty ? null : result.warning;
        });
        unawaited(
          saveUserChange(context, () => widget.store.refreshDramas(result.items)),
        );
        return;
      }
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        sort: view.sort == CatalogSort.source ? '' : view.sort.name,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      final message = friendlyError(error);
      setState(() {
        _loading = false;
        _loadingMore = false;
        // 刷新/加载失败时保留已在显示的缓存列表：旧实现无条件清空
        // _items，下拉刷新一次失败就把整页内容抹掉（「缓存突然没了」）。
        // 搜索词变化时上方已按 query 清过一次，这里不再重复清。
        _error = message;
      });
      // 错误面板只在空列表时占位；有缓存内容时改用轻提示，既不遮内容
      // 也让用户知道这次刷新没成功。
      if (_items.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  /// 翻页追加：站点板块的分页可能有重复条目（榜单重算），按 id 去重。
  List<Drama> _appendPage(List<Drama> current, List<Drama> page) {
    final seen = {for (final drama in current) drama.id};
    final merged = <Drama>[...current];
    for (final drama in page) {
      if (seen.contains(drama.id)) continue;
      seen.add(drama.id);
      merged.add(drama);
    }
    return merged;
  }

  void _changeSource(SourceSite source) {
    if (_source.id == source.id) {
      return;
    }
    AppHaptics.selection();
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _source = source;
      // 换源即换「这个源上次是不是糊着」的记忆。
      _blurCovers = widget.store.blurCoversFor(source.id);
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
      // 板块是源相关的：切源立即清掉上一个源的 home: 分类，别让它们
      // 在新源首页残留到下一次请求返回。
      _homeFeed = null;
      _homeFeedGeneration++;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: false),
      ),
    );
    // 分组记忆：记住「这个分组上次用的是哪个源」，下次长按切回该类时
    // 直接落在它上面（用户 2026-11-15 要求）。
    unawaited(
      widget.store
          .rememberGroupSource(_groupIdOf(source), source.id)
          .catchError((Object _) {}),
    );
    // 切源立即冲刷合并窗：上一个源待写的剧库快照先落盘，别等 2 秒窗口
    // 或下一个源的首次写入（进程此时被杀会丢掉旧源的最后一次变更）。
    // widget 测试没有原生核心，这条冲刷只会留下一条 10 秒排队超时计时器，
    // 让测试收尾报「Timer is still pending」——测试环境直接跳过。
    if (!Motion.inTest) unawaited(flushNativeCatalogWrites());
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
    unawaited(_loadHomeFeed());
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    // 搜索提交后界面「回弹」：释放文本焦点、硬断编辑连接、列表回顶。
    // 键盘收起后窗口 resize 才会复位，顶栏与分组栏不再停在错位状态挡结果。
    _searchAutoFocus = false;
    unawaited(dismissPlaybackTextInput());
    if (_scroll.hasClients) _scroll.jumpTo(0);
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  /// 当前目录上有效的排序项（含源站服务端排序能力）。
  Set<CatalogSort> _catalogSortSupport() {
    // 用当前浏览池（含站源开关/分类/VIP/搜索过滤）而不是未过滤的
    // _items：本分组搜索态只要有一条别的源带 heat 就宣布全池支持，
    // 点选后其实全 null 降级，是「排序点了没反应」的 UI 根因。
    final supported = catalogSortSupport(_browsableItems);
    // 剧果「全部」页由源站按热度序返回（sort=hot），条目本身无热度
    // 字段；搜索态 Go 的搜索分支完全忽略 sort，且当前源可能不是剧果，
    // 故特判收窄到「当前源=剧果 + 非搜索 + 全部分类」。
    if (_category.isEmpty &&
        _search.text.trim().isEmpty &&
        _submittedQuery.isEmpty &&
        _source.id == 'huangju') {
      supported.add(CatalogSort.heat);
    }
    return supported;
  }

  Future<void> _chooseCatalogView() async {
    // TV 保留底部弹层：遥控焦点导航可靠 + 「应用」确认步骤；
    // 手机改锚定 ≡ 岛的轻量筛选浮卡，点选即生效，不再占半屏大玻璃。
    //
    // 整段包保护：这里任何一步抛错都会表现为「点了没反应」（异常在
    // release 下只进日志，用户看不到），至少先把原因打到控制台。
    try {
      await _chooseCatalogViewBody();
    } catch (error, stack) {
      debugPrint('排序与筛选打开失败：$error\n$stack');
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('排序与筛选打开失败，请重试')));
    }
  }

  Future<void> _chooseCatalogViewBody() async {
    final watch = Stopwatch()..start();
    final supported = _catalogSortSupport();
    // 筛选选项按「当前其它过滤态下选中必有内容」聚合：浏览池已含
    // 分类/搜索/VIP/站源开关过滤，聚合某维度选项时跳过该维度自身、
    // 其余筛选维度照常生效——显示的每个选项选中后都不会得到空列表；
    // 无该字段数据的源（如部分短剧类源）选项为空，面板对应节整体隐藏。
    // 切源/切档后持久化的 area/year 在新池可能已不存在：先清掉悬空
    // 值再聚合选项，否则另一维度也被它过滤成空、面板整节消失。
    //
    // 浏览池只重建一次：原实现在这里调了两次 _browsableItems，每次都要
    // 对整库跑一遍站源/VIP/分类/搜索判定——库上万条时点 ≡ 明显卡一下。
    final browsable = _browsableItems;
    var view = effectiveFilterView(browsable, widget.store.catalogView);
    final stored = widget.store.catalogView;
    if (view != stored) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(view),
      );
      if (!mounted) return;
    }
    // 选项列表封顶：面积/年份来自条目池，脏数据（每个条目一个不同值）
    // 会把面板撑成上千枚胶囊——弹层不是懒加载列表，一帧内全建完会直接
    // 卡死。按出现次数降序取前 32 个，并保证当前已选的选项一定在列。
    List<String> capped(List<String> options, String selected) {
      if (options.length <= 32) return options;
      final head = options.take(32).toList();
      if (selected.isNotEmpty && !head.contains(selected)) head.add(selected);
      return head;
    }

    final areaOptions = capped(
      catalogFilterOptions(filterCatalog(browsable, view, skipArea: true)).areas,
      view.area,
    );
    final yearOptions = capped(
      catalogFilterOptions(filterCatalog(browsable, view, skipYear: true)).years,
      view.year,
    );
    final releaseOptions = catalogReleaseOptions(
      filterCatalog(browsable, view, skipRelease: true),
    );
    debugPrint(
      '[DBG] filter options pool=${browsable.length} '
      'area=${areaOptions.length} year=${yearOptions.length} '
      'rel=${releaseOptions.length} sort=${supported.length} '
      '${watch.elapsedMilliseconds}ms',
    );
    if (AppLayout.isTelevision(context)) {
      final selected = await chooseCatalogView(
        context,
        view,
        supported: supported,
        areaOptions: areaOptions,
        yearOptions: yearOptions,
        releaseOptions: releaseOptions,
      );
      if (selected != null && mounted) {
        final previous = widget.store.catalogView;
        await saveUserChange(
          context,
          () => widget.store.setCatalogView(selected),
        );
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        // 排序变化时重拉目录，让服务端排序（剧果 sort=hot/new）真正生效。
        if (mounted && previous.sort != selected.sort) unawaited(_load());
      }
      return;
    }
    await showCatalogFilterMenu(
      context: context,
      anchorKey: _sortMenuKey,
      current: view,
      supported: supported,
      areaOptions: areaOptions,
      yearOptions: yearOptions,
      releaseOptions: releaseOptions,
      onChanged: (view) async {
        final previous = widget.store.catalogView;
        await saveUserChange(
          context,
          () => widget.store.setCatalogView(view),
        );
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
        if (mounted && previous.sort != view.sort) unawaited(_load());
      },
    );
  }

  void _openDrama(Drama drama, {bool download = false}) {
    _pauseCatalog();
    // 搜索态点卡会带着输入框焦点起播，键盘跟到播放器上；这里统一收口
    // （电视模式跳过，别清掉遥控焦点）。
    if (!AppLayout.isTelevision(context)) {
      // 起播后回到首页时搜索框若重建，autofocus 会再把输入法弹出来。
      _searchAutoFocus = false;
      FocusManager.instance.primaryFocus?.unfocus();
    }
    if (download) {
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => DetailScreen(
            drama: drama,
            repository: widget.repository,
            store: widget.store,
            downloadOnOpen: true,
          ),
        ),
      );
      return;
    }
    unawaited(
      openPlaybackDirectly(
        context,
        drama: drama,
        repository: widget.repository,
        store: widget.store,
      ),
    );
  }

  /// 轮播卡点击：豆瓣条目无播放链路，同名搜索进详情；其余照常直进播放。
  void _openCarouselDrama(Drama drama) {
    if (drama.source == SourceSite.douban.id) {
      // 豆瓣条目无播放链路（用户定调 2026-11-18）：走搜索，而不是自动跨源
      // 搜完直跳命中源——冷门片常只有真果·鉴（AI 聚合）命中，表现为
      // 「点豆瓣卡只跳转真果鉴」。首页本就是搜索宿主，直接复用。
      searchAllSources(drama.title);
      return;
    }
    _openDrama(drama);
  }

  void _changeTab(int tab) => setState(() {
    _tab = tab;
    _selectionMode = false;
    _selectedDramas.clear();
    // 新 tab 尚无滚动帧，残留的旧 tab 接近度会让描边虚亮——复位。
    _prox.value = 0;
    // 筛选请求是一次性的：离开追剧页即消费掉，下次切回来是「全部」。
    if (tab != 1) _libraryFilter.value = '';
  });

  /// 更新提醒「去看看」：切到追剧页并自动选中「有更新」筛选。
  void _showFollowUpdates() {
    _changeTab(1);
    _libraryFilter.value = 'updates';
  }

  /// 首页继续观看条：最近一条还没看完的观看记录（history 已按时间倒序）。
  /// 判定式与追剧页 continue-watching 卡一致。
  WatchEntry? get _resumeEntry {
    if (_resumeDismissed || _searchVisible) return null;
    return widget.store.history.where((entry) {
      if (!entry.finished) return true;
      // history 里的 drama 是观看当时的快照：剧后来更新了集数、但 6h
      // 巡检还没跑/未收藏时，旧快照会让「继续观看」条凭空消失。取
      // 详情回填与收藏档案里最新的集数判定。
      final latest = widget.repository.catalogUpdates.current(entry.drama);
      final favorite = widget.store.favorites
          .where((drama) => drama.id == entry.drama.id)
          .firstOrNull;
      final episodes = [
        entry.drama.episodes,
        latest.episodes,
        favorite?.episodes ?? 0,
      ].fold<int>(0, (best, value) => value > best ? value : best);
      return episodes <= 0 || entry.episode < episodes;
    }).firstOrNull;
  }

  /// 追剧/最近卡片菜单「换个源找」：回发现页用剧名触发本分组搜索。
  void _findSourceFor(String title) => searchAllSources(title);

  /// 按剧名换源：在当前源所在分组内搜一遍（播放失败/追剧换源兜底）。
  /// 与用户手动搜索走的是同一套分组、同一套结果页，只是由外部页面
  /// 触发且不自动聚焦键盘。方法名沿用历史调用点，不再跨全部站源。
  void searchAllSources(String title) {
    final query = title.trim();
    if (query.isEmpty) return;
    _changeTab(0);
    setState(() {
      _showRecommendations = false;
      // 别被首页残留分类（尤其 local: 题材/长短剧档）过滤掉命中。
      _categorySelections[_group.id] = '';
      _searchVisible = true;
      _searchAutoFocus = false;
    });
    _submitSearch(query);
  }

  /// 播放器/简介页写入的换源搜索请求（见 source_search.dart）。
  ///
  /// 帧内（initState 取首笔、或别的 widget 构建期写入）不能直接 setState，
  /// 延后到本帧画完再执行；帧外（总线监听回调）必须当场执行——空闲时
  /// `addPostFrameCallback` 不会主动申请新帧，硬延后会一直挂着不跑。
  void _onSourceSearchRequest() {
    final request = SourceSearchBus.take();
    if (request == null || !mounted) return;
    final phase = SchedulerBinding.instance.schedulerPhase;
    final inFrame = phase == SchedulerPhase.persistentCallbacks ||
        phase == SchedulerPhase.midFrameMicrotasks ||
        phase == SchedulerPhase.transientCallbacks;
    if (!inFrame) {
      searchAllSources(request.query);
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      searchAllSources(request.query);
    });
  }

  /// 继续观看条自动收起时长：出现后无操作 8 秒即收，不常驻占版面。
  static const _resumeAutoHideDelay = Duration(seconds: 8);

  /// 首次真正渲染出条目才开始计时——history 异步就绪，若从 initState
  /// 起算，冷启动加载耗时会把倒计时耗在条目出现之前。
  void _scheduleResumeAutoHide() {
    if (_resumeHideTimer != null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _resumeDismissed || _resumeHideTimer != null) return;
      _resumeHideTimer = Timer(_resumeAutoHideDelay, () {
        _resumeHideTimer = null;
        if (mounted && !_resumeDismissed) {
          setState(() => _resumeDismissed = true);
        }
      });
    });
  }

  /// 立即收起（点「不再提醒」/点条目去播放）：取消自动收起计时。
  void _dismissResume() {
    _resumeHideTimer?.cancel();
    _resumeHideTimer = null;
    setState(() => _resumeDismissed = true);
  }

  Widget _continueWatchingCard() {
    final entry = _resumeEntry;
    if (entry == null) return const SizedBox.shrink();
    _scheduleResumeAutoHide();
    return Card(
      margin: EdgeInsets.zero,
      child: ListTile(
        key: const ValueKey('home-continue-watching'),
        leading: AppIcon(AppIcons.playCircle),
        title: Text(
          '继续观看 · ${entry.drama.title}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          '第 ${entry.episode} 集 · ${formatPosition(entry.position)}',
        ),
        trailing: IconButton(
          tooltip: '不再提醒',
          onPressed: _dismissResume,
          icon: AppIcon(AppIcons.close, size: 20),
        ),
        onTap: () {
          // 提醒已响应：收起后去播放，回到首页不再常驻此条。
          _dismissResume();
          _openDrama(entry.drama);
        },
      ),
    );
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        widget.store.canDownload && widget.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      blurred: _blurring,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        store: widget.store,
        onDownload: widget.repository.supportsDownloads && widget.store.canDownload
            ? () => _openDrama(drama, download: true)
            : null,
        onSelect: widget.repository.supportsDownloads && widget.store.canDownload
            ? () => _selectDrama(drama)
            : null,
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  /// 构建当前浏览过滤态下的条目池（站源开关 + 分类 local 过滤 + VIP 隐藏
  /// + 搜索词，不含筛选维度），排序与筛选面板选项聚合共用。
  ///
  /// 逐条都要重复求值的量全部提到循环外：真机实测剧库 18959 条时，原来在
  /// 谓词里对每条调用 `store.allowsSource` 与 `_hideVip`（后者内部还要遍历
  /// 当前分组站源列表）就要 480ms——滑一下加载新页，整屏卡半秒。
  List<Drama> _buildBrowsePool() {
    final store = widget.store;
    final query = _search.text.trim().toLowerCase();
    final local = _category.startsWith('local:');
    final bool? kindLong = _category == localLongCategory
        ? true
        : _category == localShortCategory
        ? false
        : null;
    final genre = local && kindLong == null ? _category.substring(6) : '';
    final hideVip = _hideVip;
    // 站源开关与站源对象按 source 缓存：全库只有几十个源，实测省掉上万次
    // getter 求值（这是那 480ms 的大头）。
    final allowed = <String, bool>{};
    final sites = <String, SourceSite?>{};

    SourceSite? siteOf(String source) => sites.containsKey(source)
        ? sites[source]
        : (sites[source] = SourceSite.byId(source));

    bool passes(Drama drama) {
      final source = drama.source;
      if (!(allowed[source] ??= store.allowsSource(source))) return false;
      if (local) {
        if (kindLong != null) {
          // 短剧/长剧档：按显式定性 / 分类标签 / 站源属性判定（不看时长）。
          if (dramaIsLongDrama(drama, siteOf(source)) != kindLong) return false;
        } else if (!matchesLocalGenre(drama, genre)) {
          return false;
        }
      }
      if (hideVip && source == 'huangdou' && drama.vip) return false;
      if (query.isEmpty) return true;
      return acceptsSearchHit(drama, query, siteOf(source));
    }

    return _items.where(passes).toList();
  }

  List<Drama> get _browsableItems => _buildBrowsePool();

  List<Drama>? _visibleCache;
  String? _visibleKey;

  /// 过滤+排序结果缓存：key 覆盖全部输入（条目集、分类、搜索词、在线
  /// 搜索、排序视图、VIP 隐藏、站源开关），任一变化即重算——不靠手动
  /// 失效点枚举，杜绝「改了输入忘了清缓存」；单次 build 内多次调用
  /// （items 与 _searchGroups）只排一次序。
  List<Drama> get _visible {
    // catalogView getter 每次访问都 jsonDecode 新建实例，这里只取一次；
    // key 必须展开字段值——CatalogView 若以默认 toString 进 join 会恒为
    // "Instance of 'CatalogView'"，排序/筛选变化全部不失效缓存（真 bug）。
    final view = widget.store.catalogView;
    final key = [
      identityHashCode(_items),
      _category,
      _search.text,
      _onlineSearch,
      view.sort.name,
      view.release,
      view.area,
      view.year,
      view.allSources,
      _hideVip,
      _source.id,
      _group.id,
      // 多源搜索结果里每条按自身 source 过滤，站源管理页开关其它源
      // 也要让缓存失效；旧 key 只列当前单源，禁源条目会一直残留。
      for (final source in widget.store.sources)
        widget.store.allowsSource(source.id),
    ].join('|');
    final cached = _visibleCache;
    if (cached != null && _visibleKey == key) return cached;
    final query = _search.text.trim().toLowerCase();
    final watch = Stopwatch()..start();
    final result = sortCatalog(_buildBrowsePool(), view);
    watch.stop();
    // 只在明显变慢时留一条，便于以后回归定位（正常是 1~3ms）。
    if (watch.elapsedMilliseconds > 50) {
      debugPrint(
        '[DBG] visible slow items=${_items.length} out=${result.length} '
        'sort=${view.sort.name} rel=${view.release} area=${view.area} '
        'year=${view.year} q=${query.length} ${watch.elapsedMilliseconds}ms',
      );
    }
    _visibleKey = key;
    _visibleCache = result;
    return result;
  }

  int _relevanceOf(Drama drama, String query) {
    final title = drama.title.toLowerCase();
    if (title == query) return 0;
    if (title.startsWith(query)) return 1;
    if (title.contains(query)) return 2;
    return 3;
  }

  /// 聚合搜索态的分组结果：组内按相关度（精确 > 前缀 > 包含 > 原序）排序，
  /// 组间按组内最佳相关度排序；仅在多源命中时返回分组，否则返回 null。
  Map<String, List<Drama>>? _searchGroupsCache;
  String? _searchGroupsKey;

  Map<String, List<Drama>>? get _searchGroups {
    final query = _search.text.trim().toLowerCase();
    if (!_onlineSearch || _submittedQuery.isEmpty || query.isEmpty) {
      _searchGroupsKey = null;
      _searchGroupsCache = null;
      return null;
    }
    final items = _visible;
    // 一次 build 内 _visible 与网格各读一次；输入时每按一键都会整页
    // rebuild，没有这层缓存就等于每次按键把多源命中重新排序一遍。
    final key = '$query|${identityHashCode(items)}|${items.length}';
    if (_searchGroupsKey == key) return _searchGroupsCache;
    int relevance(Drama drama) => _relevanceOf(drama, query);
    final groups = <String, List<Drama>>{};
    final best = <String, int>{};
    for (final drama in items) {
      final rank = relevance(drama);
      groups.putIfAbsent(drama.source, () => []).add(drama);
      final current = best[drama.source];
      if (current == null || rank < current) best[drama.source] = rank;
    }
    if (groups.length < 2) {
      _searchGroupsKey = key;
      _searchGroupsCache = null;
      return null;
    }
    final ordered = <String, List<Drama>>{};
    for (final entry in groups.entries) {
      final list = entry.value;
      final weighted = [
        for (var index = 0; index < list.length; index++)
          (relevance(list[index]), index, list[index]),
      ]..sort((a, b) {
        final compare = a.$1.compareTo(b.$1);
        return compare != 0 ? compare : a.$2.compareTo(b.$2);
      });
      ordered[entry.key] = [for (final item in weighted) item.$3];
    }
    final keys = ordered.keys.toList()
      ..sort((a, b) => (best[a] ?? 3).compareTo(best[b] ?? 3));
    final result = <String, List<Drama>>{
      for (final source in keys) source: ordered[source]!,
    };
    _searchGroupsKey = key;
    _searchGroupsCache = result;
    return result;
  }

  Widget _sourceSectionHeader(String sourceId, double padding) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
        child: Text(
          SourceSite.byId(sourceId)?.name ?? '未知源',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w800,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        // 错峰入场只在「首次进页面」演一次。之后切分类/切站源时整批网格
        // 条目都是新建 State，若照旧播入场＝一屏 20+ 个 FadeTransition
        // 同时上 saveLayer 半秒，这就是切分类/切分组卡的主因。
        if (!_entranceDone && _items.isNotEmpty) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _entranceDone = true;
          });
        }
        final television = AppLayout.isTelevision(context);
        // 宽屏布局含高度门槛（同 detail_screen）：手机横屏逻辑高度 <600
        // （如折叠屏展开态 869x400），旋转后仍保持手机布局。
        final desktop =
            constraints.maxWidth >= 840 && constraints.maxHeight >= 600;
        // 悬浮玻璃底栏只在手机/iOS 出现；开启 extendBody 让内容透到玻璃后被模糊。
        final floatingNav = !desktop && !television;
        final navEntries = <(int, Widget, String)>[
          (0, AppIcon(AppIcons.explore), '发现'),
          (1, AppIcon(AppIcons.bookmark, filled: true), '追剧'),
          (2, AppIcon(AppIcons.history), '最近观看'),
          if (widget.store.canDownload) (3, _downloadIcon(), '下载'),
        ];
        // 手机横屏紧凑档：顶栏 56→44；沉浸后 padding.top=0 自动让位。
        final compactLandscape =
            floatingNav && AppLayout.landscapePhone(context);
        _syncImmersive(compactLandscape);
        final topInset = floatingNav
            ? MediaQuery.paddingOf(context).top +
                  (compactLandscape ? 44.0 : 56.0)
            : 0.0;
        Widget scaffold = Scaffold(
          extendBody: floatingNav,
          // 手机端顶栏悬浮玻璃：内容延伸到顶栏后方，滚动时从玻璃后穿过。
          extendBodyBehindAppBar: floatingNav,
          appBar: AppBar(
            toolbarHeight: television ? 64 : (compactLandscape ? 44 : null),
            titleSpacing: floatingNav ? 8 : 12,
            title: _selectionMode
                ? _navPill(
                    glass: floatingNav,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: const Text(
                        '选择短剧',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  )
                : _tab == 0
                ? television
                      ? PopupMenuButton<Object>(
                          key: const ValueKey('source-switch'),
                          tooltip: '切换站源',
                          onSelected: (value) {
                            if (value == _liveEntryChoice) {
                              _openLiveScreen();
                            } else if (value is SourceSite) {
                              _changeSource(value);
                            }
                          },
                          itemBuilder: (_) => [
                            for (final category in _sourceCategories) ...[
                              if (category != _sourceCategories.first)
                                const PopupMenuDivider(),
                              ...category.sources.map(
                                (source) => PopupMenuItem<Object>(
                                  value: source,
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(source.name)),
                                      if (source.id == _source.id)
                                        AppIcon(AppIcons.check, size: 20),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                            const PopupMenuDivider(),
                            const PopupMenuItem<Object>(
                              value: _liveEntryChoice,
                              child: Row(
                                children: [
                                  Icon(Icons.live_tv, size: 20),
                                  SizedBox(width: 8),
                                  Text('电视直播'),
                                ],
                              ),
                            ),
                          ],
                          child: SizedBox(
                            height: 48,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: Text(
                                    _group.name,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ),
                                if (_sourceCategories.expand((c) => c.sources).length > 1)
                                  AppIcon(AppIcons.expandMore),
                              ],
                            ),
                          ),
                        )
                      : !_showRecommendations
                      ? _navPill(
                          glass: floatingNav,
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: GestureDetector(
                              key: const ValueKey('source-switch'),
                              behavior: HitTestBehavior.opaque,
                              onTap: _showSourceMenu,
                              onLongPress: () {
                                AppHaptics.light();
                                _pickSourceCategory();
                              },
                              child: KeyedSubtree(
                                // 胶囊菜单锚点仍用 _sourceMenuKey（GlobalKey）。
                                key: _sourceMenuKey,
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    final multiSource = _sourceCategories
                                        .expand((c) => c.sources)
                                        .length > 1;
                                    // 窄屏（如 density 540 的 320dp 设备 + 一排
                                    // 工具岛）里箭头会把源名挤成 0 宽：空间不足
                                    // 先让出箭头，再不足只显示源名首字——否则顶栏
                                    // 只剩一颗圆点箭头，用户看不出当前站源
                                    //（症状：「导航只出真果鉴」）。整颗胶囊仍可
                                    // 点击/长按切换。
                                    final showArrow =
                                        multiSource && constraints.maxWidth >= 110;
                                    final compactLabel = constraints.maxWidth < 64;
                                    final name = _group.name.isEmpty
                                        ? appName
                                        : _group.name;
                                    final factor = UiScale.buttonFactor(
                                      context,
                                    );
                                    return SizedBox(
                                      height: 48 * factor,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Flexible(
                                            child: Text(
                                              compactLabel
                                                  ? name.substring(0, 1)
                                                  : name,
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                              style: const TextStyle(
                                                fontWeight: FontWeight.w800,
                                                fontSize: 13,
                                              ),
                                            ),
                                          ),
                                          if (showArrow)
                                            AppIcon(
                                              AppIcons.expandMore,
                                              size: 24 * factor,
                                            ),
                                        ],
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                          ),
                        )
                      : const SizedBox.shrink()
                : _navPill(
                    glass: floatingNav,
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: const Text(appName),
                    ),
                  ),
            actions: [
              if (_selectionMode) ...[
                _navPill(
                  glass: floatingNav,
                  TextButton(
                    key: const ValueKey('clear-catalog-selection'),
                    onPressed: _selectedDramas.isEmpty
                        ? null
                        : () => setState(_selectedDramas.clear),
                    child: const Text('清空'),
                  ),
                ),
                _navPill(
                  glass: floatingNav,
                  TextButton(
                    key: const ValueKey('cancel-catalog-selection'),
                    focusNode: _appBarFocus,
                    onPressed: _cancelSelection,
                    child: const Text('取消'),
                  ),
                ),
              ] else ...[
                if (_tab == 1)
                  _navPill(
                    glass: floatingNav,
                    _navIcon(
                      AppIcons.sync,
                      key: const ValueKey('follow-lan-sync'),
                      tooltip: '追剧同步',
                      onPressed: () => openLanSync(context),
                    ),
                  ),
                if (_tab == 0) ...[
                  // 站源岛已移回 title 槽贴左：actions 删除多选按钮后
                  // title 宽度充裕，actions 仅留工具岛贴右。
                  // 「模糊封面」按钮已从顶栏移除，改到「已装模块」页按分组开关。
                  if (!_showRecommendations)
                    _navPill(
                      glass: floatingNav,
                      _navIcon(
                        AppIcons.sort,
                        key: _sortMenuKey,
                        tooltip:
                            '排序与筛选 · ${widget.store.catalogView.sort.label}',
                        onPressed: _chooseCatalogView,
                        color:
                            widget.store.catalogView.sort !=
                                    CatalogSort.source ||
                                widget.store.catalogView.release.isNotEmpty
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                    ),
                  _navPill(
                    glass: floatingNav,
                    _navIcon(
                      _searchVisible ? AppIcons.searchOff : AppIcons.search,
                      key: const ValueKey('toggle-search'),
                      tooltip: _searchVisible ? '收起搜索' : '搜索',
                      onPressed: _toggleSearch,
                    ),
                  ),
                  if (!_showRecommendations)
                    _navPill(
                      glass: floatingNav,
                      _navIcon(
                        AppIcons.leaderboard,
                        key: const ValueKey('open-rankings'),
                        tooltip: '榜单',
                        onPressed: _openRankings,
                      ),
                    ),
                ],
                television
                    ? PopupMenuButton<String>(
                        tooltip: '更多',
                        onSelected: _onMoreSelected,
                        itemBuilder: (_) => [
                          if (widget.repository.supportsSourceManagement)
                            const PopupMenuItem(
                              value: 'modules',
                              child: Text('站源模块'),
                            ),
                          const PopupMenuItem(
                            value: 'users',
                            child: Text('用户管理'),
                          ),
                          const PopupMenuItem(
                            value: 'settings',
                            child: Text('设置与备份'),
                          ),
                          const PopupMenuItem(
                            value: 'display',
                            child: Text('界面模式'),
                          ),
                          const PopupMenuItem(
                            value: 'about',
                            child: Text('关于$appName'),
                          ),
                        ],
                      )
                    : _navPill(
                        glass: floatingNav,
                        _navIcon(
                          AppIcons.moreVert,
                          key: _moreMenuKey,
                          tooltip: '更多',
                          onPressed: () => _showMoreMenu(
                            narrow: constraints.maxWidth < 400,
                          ),
                        ),
                      ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            // bottom:false：内容延伸到悬浮玻璃底栏后方，真正被模糊。
            bottom: false,
            child: Row(
              children: [
                if (television) ...[
                  SizedBox(
                    width: 176,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                      child: RemoteList(
                        key: _navKey,
                        itemKeys: [
                          for (final entry in navEntries) '${entry.$1}',
                        ],
                        itemExtent: 60,
                        spacing: 14,
                        padding: EdgeInsets.zero,
                        autofocus: true,
                        onExitRight: _tab == 0
                            ? () => _gridKey.currentState?.focusCurrent()
                            : null,
                        itemBuilder: (_, index, node, onFocus) {
                          final entry = navEntries[index];
                          return RemoteButton(
                            key: ValueKey('tv-nav-${entry.$1}'),
                            label: entry.$3,
                            icon: entry.$2,
                            selected: _tab == entry.$1,
                            focusNode: node,
                            onFocus: onFocus,
                            onPressed: () => _changeTab(entry.$1),
                          );
                        },
                      ),
                    ),
                  ),
                  const VerticalDivider(width: 1),
                ] else if (desktop) ...[
                  NavigationRail(
                    selectedIndex: _tab,
                    onDestinationSelected: _changeTab,
                    labelType: NavigationRailLabelType.all,
                    groupAlignment: -.8,
                    destinations: [
                      NavigationRailDestination(
                        icon: AppIcon(AppIcons.explore),
                        selectedIcon: AppIcon(AppIcons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: AppIcon(AppIcons.bookmark),
                        selectedIcon: AppIcon(AppIcons.bookmark, filled: true),
                        label: Text('追剧'),
                      ),
                      NavigationRailDestination(
                        icon: AppIcon(AppIcons.history),
                        label: Text('最近观看'),
                      ),
                      if (widget.store.canDownload)
                        NavigationRailDestination(
                          icon: _downloadIcon(),
                          selectedIcon: _downloadIcon(),
                          label: Text('下载'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  // 接近度信号覆盖全部 tab：任何 tab 的滚动通知都驱动
                  // _prox（顶栏岛/分类胶囊白描边亮起），只听首页
                  // ScrollController 的旧实现让其他 tab 滚动时描边不亮。
                  child: NotificationListener<ScrollNotification>(
                    onNotification: _onBodyScroll,
                    child: Stack(
                      children: [
                        _tab == 0
                            ? widget.store.sources.isEmpty
                                  ? const StatusPanel(
                                      title: '暂无可用站源',
                                      message: '请联系管理员为当前用户开放站源。',
                                    )
                                  : _catalog(
                                      selectionInBody: desktop || television,
                                      topInset: topInset,
                                    )
                            : _tab == 3
                            ? DownloadsScreen(
                                repository: widget.repository,
                                store: widget.store,
                                embedded: true,
                                bottomInset: floatingNav
                                    ? _floatingNavInset
                                    : 0,
                                topInset: topInset,
                              )
                            : SavedLibrary(
                                key: ValueKey('saved-tab-$_tab'),
                                repository: widget.repository,
                                store: widget.store,
                                bottomInset: floatingNav
                                    ? _floatingNavInset
                                    : 0,
                                topInset: topInset,
                                history: _tab == 2,
                                filterRequest: _libraryFilter,
                                remoteAutofocus: television,
                                onExitLeft: television
                                    ? () =>
                                          _navKey.currentState?.focusCurrent()
                                    : null,
                                onOpen: _openDrama,
                                onContinue: (drama) => _openDrama(drama),
                                onDownload:
                                    widget.repository.supportsDownloads &&
                                    widget.store.canDownload
                                    ? (drama) =>
                                          _openDrama(drama, download: true)
                                    : null,
                                onFindSource: allSourcesEnabled
                                    ? _findSourceFor
                                    : null,
                              ),
                        // 其他三个 tab（追剧/最近/下载）没有首页那条 pinned
                        // 雾面带——雾面挂在 _catalog 内部只随 tab0 存在。
                        // 在 body 顶部补同一条雾面（高度=顶栏整体），
                        // 滚动内容穿顶时同样糊化；底缘由 tint painter
                        // 内置羽化自然消散。
                        if (_tab != 0 && topInset > 0)
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: SizedBox(
                              // 「雾面高度」正档向下延伸、负档收窄（糊化
                              // /雾形/羽化整体跟随）；clamp≥0 防负高度。
                              height: _fogBandHeight(topInset),
                              child: const TopFog(),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          bottomNavigationBar: desktop || television
              ? null
              : _selectionMode
              ? _selectionBar()
              : AppBottomNavigation(
                  selectedIndex: _tab,
                  onDestinationSelected: _changeTab,
                  compact: compactLandscape,
                  destinations: [
                    NavigationDestination(
                      icon: AppIcon(AppIcons.explore),
                      selectedIcon: AppIcon(AppIcons.explore),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: AppIcon(AppIcons.bookmark),
                      selectedIcon: AppIcon(AppIcons.bookmark, filled: true),
                      label: '追剧',
                    ),
                    NavigationDestination(
                      icon: AppIcon(AppIcons.history),
                      label: '最近观看',
                    ),
                    if (widget.store.canDownload)
                      NavigationDestination(
                        icon: _downloadIcon(),
                        selectedIcon: _downloadIcon(),
                        label: '下载',
                      ),
                  ],
                ),
        );
        // 横屏沉浸：窗口已延伸进挖孔区（MainActivity SHORT_EDGES），
        // 移除左右系统避让（挖孔/手势条 inset），内容跟着延伸到边缘；
        // 否则窗口覆盖了但 UI 仍从挖孔右侧开始，左侧只留一条背景。
        if (compactLandscape) {
          scaffold = MediaQuery.removePadding(
            context: context,
            removeLeft: true,
            removeRight: true,
            child: scaffold,
          );
        }
        if (television || _selectionMode) {
          return PopScope(
            canPop:
                !_selectionMode &&
                (!television || _tab == 0 && _search.text.isEmpty),
            onPopInvokedWithResult: (didPop, result) {
              if (!didPop) _televisionBack();
            },
            child: CallbackShortcuts(
              bindings: {
                // 返回键交给系统 popRoute（双通道会一次退两级）。
                const SingleActivator(LogicalKeyboardKey.escape): () =>
                    Navigator.of(context).maybePop(),
              },
              child: scaffold,
            ),
          );
        }
        // 手机端二次退出保护：首次返回弹提示，2 秒内再按才真正退出，
        // 防止误触一次返回直接丢掉整个应用。
        return PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, result) {
            if (didPop) return;
            final now =
                widget.backClock?.call() ?? DateTime.now();
            final last = _lastBackAt;
            if (last != null &&
                now.difference(last) < const Duration(seconds: 2)) {
              unawaited(SystemNavigator.pop());
              return;
            }
            _lastBackAt = now;
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(const SnackBar(content: Text('再按一次返回键退出')));
          },
          child: scaffold,
        );
      },
    ),
  );

  Widget _catalog({required bool selectionInBody, double topInset = 0}) {
    final items = _visible;
    final television = AppLayout.isTelevision(context);
    // 手机端悬浮玻璃顶栏：岛与海报必须同处一个从屏幕顶端开始的全屏滚动
    // 视口，否则内容滚动被筛选岛下方的视口边缘裁剪，永远穿不进顶栏后方
    // （玻璃后只有背景色=假透）。TV/桌面/推荐模式维持原 Column 结构。
    if (topInset > 0 && !_showRecommendations) {
      return _catalogFloating(topInset, selectionInBody: selectionInBody);
    }
    return Column(
      children: [
        if (_searchVisible && !television)
          Padding(
            padding: EdgeInsets.fromLTRB(16, 4 + topInset, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: _searchAutoFocus,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? (query) =>
                        widget.repository.suggestions(query, source: _source.id)
                  : null,
              onSuggestionSelected: _searchSuggestions
                  ? _playSuggestion
                  : null,
              onChanged: _searchChanged,
              onCancel: () => unawaited(widget.repository.cancelSuggestions()),
              onSearch: _submitSearch,
            ),
          ),
        if (_searchVisible &&
            _search.text.trim().isEmpty &&
            widget.store.recentSearches.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final query in widget.store.recentSearches)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: ActionChip(
                              avatar: AppIcon(AppIcons.history, size: 16),
                              label: Text(query),
                              onPressed: () => _submitSearch(query),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '清空最近搜索',
                  onPressed: () =>
                      saveUserChange(context, widget.store.clearRecentSearches),
                  icon: AppIcon(AppIcons.delete, size: 20),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.only(top: topInset),
          child: _catalogFilters(televisionFocus: true),
        ),
        if (!television && !_showRecommendations && _category.isEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: _continueWatchingCard(),
          ),
        if (_showRecommendations)
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: RecommendationsScreen(
                repository: widget.repository,
                store: widget.store,
                embedded: true,
                gridKey: _gridKey,
                onExitLeft: television
                    ? () => _navKey.currentState?.focusCurrent()
                    : null,
              ),
            ),
          )
        else ...[
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: GestureDetector(
              onHorizontalDragEnd: television ? null : _swipeCategory,
              child: _loading && _items.isEmpty
                  ? const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 18),
                          Text('正在加载剧集'),
                        ],
                      ),
                    )
                  : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                      icon: AppIcon(AppIcons.wifiOff),
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.sources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '加载更多',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        if (television) {
                          return _televisionGrid(
                            items,
                            constraints.maxWidth,
                            controller: _scroll,
                            footer: Padding(
                              padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                              child: Center(
                                child: _loadingMore
                                    ? const CircularProgressIndicator()
                                    : _hasMore
                                    ? RemoteButton(
                                        label: '加载更多',
                                        icon: AppIcon(AppIcons.expandMore),
                                        onPressed: () => _load(more: true),
                                      )
                                    : const Text('已经看到这里的全部剧集'),
                              ),
                            ),
                          );
                        }
                        final padding = constraints.maxWidth < 600
                            ? 16.0
                            : 24.0;
                        final navInset =
                            (constraints.maxWidth >= 840 &&
                                constraints.maxHeight >= 600)
                            ? 0.0
                            : _floatingNavInset;
                        final searchGroups = _searchGroups;
                        final gridDelegate = dramaGridDelegate(
                          context,
                          constraints.maxWidth - 2 * padding,
                        );
                        return FogRefresh(
                          onRefresh: () => _refreshCatalog(),
                          refreshFailed: () =>
                              _error != null ||
                              _categoriesError != null ||
                              _group.sources.any(
                                (s) => _updater.error(s.id).isNotEmpty,
                              ),
                          // 胶囊停在视口顶 6px：经典布局视口顶在筛选条之下，
                          // 内容上缘即视口顶，小间隙即可。
                          displacement: 6,
                          child: CustomScrollView(
                            // PageStorageKey：切走再切回时恢复滚动位置
                            // （同 saved-library 的做法）。
                            key: const PageStorageKey('home-catalog'),
                            controller: _scroll,
                            physics: const AlwaysScrollableScrollPhysics(),
                            slivers: [
                              if (searchGroups == null)
                                SliverPadding(
                                  padding: EdgeInsets.fromLTRB(
                                    padding,
                                    0,
                                    padding,
                                    16,
                                  ),
                                  sliver: SliverGrid(
                                    gridDelegate: gridDelegate,
                                    delegate: SliverChildBuilderDelegate(
                                      (_, index) =>
        StaggeredListItem(
          index: index,
          animate: !_entranceDone,
          child: _catalogTile(items[index]),
        ),
                                      childCount: items.length,
                                    ),
                                  ),
                                )
                              else
                                for (final entry in searchGroups.entries) ...[
                                  _sourceSectionHeader(entry.key, padding),
                                  SliverPadding(
                                    padding: EdgeInsets.fromLTRB(
                                      padding,
                                      0,
                                      padding,
                                      16,
                                    ),
                                    sliver: SliverGrid(
                                      gridDelegate: gridDelegate,
                                      delegate: SliverChildBuilderDelegate(
                                        (_, index) =>
                                            _catalogTile(entry.value[index]),
                                        childCount: entry.value.length,
                                      ),
                                    ),
                                  ),
                                ],
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    bottom: 24 + navInset,
                                  ),
                                  child: Center(
                                    child: _loadingMore
                                        ? const CircularProgressIndicator()
                                        : _hasMore
                                        ? OutlinedButton.icon(
                                            onPressed: () => _load(more: true),
                                            icon: AppIcon(AppIcons.expandMore),
                                            label: const Text('加载更多'),
                                          )
                                        : Text(
                                            '已经看到这里的全部剧集',
                                            style: TextStyle(
                                              color: Theme.of(
                                                context,
                                              ).colorScheme.onSurfaceVariant,
                                              fontSize: 12,
                                            ),
                                          ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
            ),
          ),
          if (_selectionMode && selectionInBody)
            _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  /// 手机端悬浮玻璃顶栏的剧库视图：单一全屏 CustomScrollView，
  /// 搜索岛/筛选岛/海报随滚动穿过顶栏玻璃后方。
  Widget _catalogFloating(double topInset, {required bool selectionInBody}) {
    final items = _visible;
    final searchGroups = _searchGroups;
    // 轮播已改为「豆瓣选片 + 当前源条目补位」（见 HomeCarousel）：补位
    // 卡就是当前源条目，网格恒排除轮播前几条，避免动图与下方剧图重复；
    // 豆瓣命中来自其他同类站源，与网格本就无交集。搜索/分类视图不排除
    // ——那两种状态下轮播不挂载，网格显示全量。
    final carouselIds =
        !_searchVisible && _category.isEmpty && items.isNotEmpty
        ? items.take(HomeCarousel.maxItems).map((drama) => drama.id).toSet()
        : const <String>{};
    final gridItems = carouselIds.isEmpty
        ? items
        : [
            for (final drama in items)
              if (!carouselIds.contains(drama.id)) drama,
          ];
    return Column(
      children: [
        Expanded(
          child: Stack(
            children: [
              GestureDetector(
                onHorizontalDragEnd: _swipeCategory,
                child: FogRefresh(
                  // 胶囊停在分类条之下：顶栏+吸顶分类条总高再留 6px 间隙，
                  // 刷新胶囊的雾面矩形不罩到分类胶囊（MIUI 同款位置）。
                  displacement: topInset + _filtersExtent + 6,
                  // 分类条吸顶层：钉在原位不随下拉平移（真机定调「分组
                  // 不跟着下来，刷新图标在白区」）——下拉时只有内容层
                  // 下滑让位，分类条下方露出白区，环落在白区里；刷新全
                  // 程分类条不动，动画做完内容才回去。
                  header: _searchVisible
                      ? _searchHeaderBar(context, topInset)
                      : _pinnedFiltersBar(context, topInset),
                  headerExtent: _searchVisible
                      ? _searchHeaderExtent(topInset)
                      : topInset +
                            _filtersExtent +
                            (_fogHeight > 0 ? _fogHeight : 0),
                  onRefresh: () => _refreshCatalog(),
                  refreshFailed: () =>
                      _error != null ||
                      _categoriesError != null ||
                      _group.sources.any(
                        (s) => _updater.error(s.id).isNotEmpty,
                      ),
                  child: LayoutBuilder(
                builder: (context, constraints) {
                  final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
                  final navInset =
                      (constraints.maxWidth >= 840 &&
                          constraints.maxHeight >= 600)
                      ? 0.0
                      : _floatingNavInset;
                  final gridDelegate = dramaGridDelegate(
                    context,
                    constraints.maxWidth - 2 * padding,
                  );
                  return CustomScrollView(
                    // 同 classic 分支：切走再切回时恢复滚动位置。
                    key: const PageStorageKey('home-catalog'),
                    controller: _scroll,
                    // 必须是 clamping 系物理：RefreshIndicator 依赖
                    // OverscrollNotification 触发，bouncing 物理不发该通知
                    // 会导致下拉刷新失效。
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_searchVisible &&
                          _search.text.trim().isEmpty &&
                          widget.store.recentSearches.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Row(
                              children: [
                                Expanded(
                                  child: SingleChildScrollView(
                                    scrollDirection: Axis.horizontal,
                                    child: Row(
                                      children: [
                                        for (final query
                                            in widget.store.recentSearches)
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              right: 8,
                                            ),
                                            child: ActionChip(
                                              avatar: AppIcon(AppIcons.history, size: 16),
                                              label: Text(query),
                                              onPressed: () =>
                                                  _submitSearch(query),
                                            ),
                                          ),
                                      ],
                                    ),
                                  ),
                                ),
                                IconButton(
                                  tooltip: '清空最近搜索',
                                  onPressed: () => saveUserChange(
                                    context,
                                    widget.store.clearRecentSearches,
                                  ),
                                  icon: AppIcon(AppIcons.delete, size: 20),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // 分类条已挪到 FogRefresh.header 吸顶层（钉在原位
                      // 不随下拉平移）；视口内留等高占位，首屏内容仍从
                      // 分类条下方起排，滚动语义不变。搜索态无吸顶条
                      // （改随搜索岛一起滚动，见下方滚动分支）。
                      if (!_searchVisible)
                        SliverToBoxAdapter(
                          child: SizedBox(
                            height: topInset +
                                _filtersExtent +
                                (_fogHeight > 0 ? _fogHeight : 0),
                          ),
                        ),
                      if (_searchVisible)
                        SliverToBoxAdapter(
                          // 吸顶搜索头的等高占位：搜索结果必须从 header
                          // 下方起排，否则第一排会被钉在原位的顶栏+搜索框
                          // 整块盖住（「搜索后把界面挡了」）。
                          child: SizedBox(
                            key: const ValueKey('search-header-spacer'),
                            height: _searchHeaderExtent(topInset),
                          ),
                        ),
                      // 已出结果时不再挂分组栏：搜索本来就不按当前分类
                      // 过滤（_load 会强制清分类），留着只会再压掉一屏。
                      if (_searchVisible && _submittedQuery.isEmpty)
                        SliverToBoxAdapter(child: _catalogFilters()),
                      if (!_searchVisible && _category.isEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                            child: _continueWatchingCard(),
                          ),
                        ),
                      // 轮播只在「全部」分类出现；选择具体分类/题材后
                      // 隐藏，把首屏留给筛选结果。
                      if (!_searchVisible &&
                          _category.isEmpty &&
                          items.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            // 轮播与下方剧卡流的间距。
                            padding: const EdgeInsets.only(bottom: 14),
                            child: HomeCarousel(
                              store: widget.store,
                              repository: widget.repository,
                              onOpen: _openCarouselDrama,
                              fallbackItems: items,
                              anchor: _source,
                              // 站点主推板块（大家都在看）有数据时轮播播它。
                              remoteItems: _remoteCarouselItems,
                            ),
                          ),
                        ),
                      if (_loading && _items.isNotEmpty)
                        const SliverToBoxAdapter(
                          child: LinearProgressIndicator(minHeight: 2),
                        ),
                      if (_loading && _items.isEmpty)
                        const SliverFillRemaining(
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(),
                                SizedBox(height: 18),
                                Text('正在加载剧集'),
                              ],
                            ),
                          ),
                        )
                      else if (_items.isEmpty && _error != null)
                        SliverFillRemaining(
                          child: StatusPanel(
                            title: '暂时无法加载',
                            message: _error!,
                            onRetry: () => _load(force: true),
                            secondaryAction:
                                widget.repository.supportsSourceManagement
                                ? TextButton(
                                    onPressed: _manageSources,
                                    child: const Text('站源诊断'),
                                  )
                                : null,
                            icon: AppIcon(AppIcons.wifiOff),
                          ),
                        )
                      else if (items.isEmpty)
                        SliverFillRemaining(
                          child: StatusPanel(
                            title: '没有找到匹配的短剧',
                            message: _hideVip
                                ? '可以换个搜索词，或显示 VIP 内容。'
                                : widget.store.sources.length > 1
                                ? '可以换个搜索词或切换站源。'
                                : '可以换个搜索词，或刷新后重试。',
                            onRetry:
                                _hasMore &&
                                    !_loadingMore &&
                                    (!_onlineSearch ||
                                        _search.text.isEmpty ||
                                        _group.sources.any(
                                          (source) => source.pagedSearch,
                                        ))
                                ? () => _load(more: true)
                                : null,
                            action: '加载更多',
                          ),
                        )
                      else if (searchGroups == null)
                        SliverPadding(
                          padding: EdgeInsets.fromLTRB(padding, 0, padding, 16),
                          sliver: SliverGrid(
                            gridDelegate: gridDelegate,
                            delegate: SliverChildBuilderDelegate(
                              // Folme 进场：滚入视口 y=30→0 + alpha 0→1，30ms 错峰。
                              (_, index) => StaggeredListItem(
                                index: index,
                                animate: !_entranceDone,
                                child: _catalogTile(gridItems[index]),
                              ),
                              childCount: gridItems.length,
                            ),
                          ),
                        )
                      else
                        for (final entry in searchGroups.entries) ...[
                          _sourceSectionHeader(entry.key, padding),
                          SliverPadding(
                            padding: EdgeInsets.fromLTRB(
                              padding,
                              0,
                              padding,
                              16,
                            ),
                            sliver: SliverGrid(
                              gridDelegate: gridDelegate,
                              delegate: SliverChildBuilderDelegate(
                                (_, index) => StaggeredListItem(
                                  index: index,
                                  animate: !_entranceDone,
                                  child: _catalogTile(entry.value[index]),
                                ),
                                childCount: entry.value.length,
                              ),
                            ),
                          ),
                        ],
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.only(bottom: 24 + navInset),
                          child: Center(
                            child: _loadingMore
                                ? const CircularProgressIndicator()
                                : _hasMore
                                ? OutlinedButton.icon(
                                    onPressed: () => _load(more: true),
                                    icon: AppIcon(AppIcons.expandMore),
                                    label: const Text('加载更多'),
                                  )
                                : Text(
                                    '已经看到这里的全部剧集',
                                    style: TextStyle(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
                ),
              ),
              // 回顶雾面钮：滚出首屏浮现，内容上行点亮（Folme 弹簧三参数联动）。
              // 只重建这颗按钮（ListenableBuilder），不惊动整页网格。
              if (!_selectionMode)
                Positioned(
                  right: 18,
                  bottom: 24 + _floatingNavInset,
                  child: ListenableBuilder(
                    listenable: Listenable.merge([_fabShown, _fabLit]),
                    builder: (context, _) => AnimatedScale(
                      scale: _fabShown.value ? 1 : 0.4,
                      duration: MotionDurations.micro,
                      curve: MotionCurves.press,
                      child: AnimatedOpacity(
                        key: const ValueKey('home-fab-opacity'),
                        opacity: _fabShown.value ? 1 : 0,
                        duration: MotionDurations.micro,
                        child: IgnorePointer(
                          ignoring: !_fabShown.value,
                          child: FogFab(lit: _fabLit.value, onTap: _backToTop),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        if (_selectionMode && selectionInBody)
          _selectionBar(safeBottom: false),
      ],
    );
  }

  /// 分类条总高（含上下外边距）：与 CatalogFilters 非 TV 布局保持一致。
  double get _filtersExtent =>
      CatalogFilters.barHeight(context, extra: 12);

  /// 搜索态吸顶头高度：顶栏整体 + 搜索框。header 层与滚动视口内的
  /// 占位必须取同一个值，否则内容会被钉在原位的 header 盖住。
  double _searchHeaderExtent(double topInset) => topInset + 64;

  /// 吸顶分类条：雾面整条盖住吸顶头（状态栏→顶栏→分类条均匀一块，
  /// σ4.5 + 白蒙，底缘硬切），内容上滑穿过时整块糊在雾面后、无明暗
  /// 分界（用户定调「不要凹凸感」）；分类胶囊仍是独立瓷面小岛（带
  /// Folme 果冻按压），浮在雾面之上。
  /// 分类条构造（TV 列表/搜索岛/吸顶条三处共用）：差异仅在电视焦点
  /// 出口回调，由 [televisionFocus] 开关。
  Widget _catalogFilters({
    bool televisionFocus = false,
    bool inheritBlur = false,
  }) {
    return CatalogFilters(
      key: ValueKey('filters-${_group.id}'),
      categories: _displayCategories,
      category: _displayCategory,
      error: _categoriesError,
      remoteKey: _filtersKey,
      onExitUp: televisionFocus && _selectionMode
          ? () => _appBarFocus.requestFocus()
          : null,
      onExitDown: televisionFocus
          ? () => _gridKey.currentState?.focusCurrent()
          : null,
      onCategory: _changeCategory,
      onRetry: () => _loadCategories(force: true),
      proxListenable: _prox,
      inheritBlur: inheritBlur,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_supportsVipFilter)
            IconButton(
              tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
              onPressed: () => saveUserChange(
                context,
                () async {
                  await widget.store.setHideVip(!widget.store.hideVip);
                  // store 变化只重建 MaterialApp 外壳，HomeScreen 元素
                  // 复用不重跑 build——主动刷新让列表立即应用过滤。
                  if (mounted) setState(() {});
                },
              ),
              icon: VipIcon(hidden: widget.store.hideVip),
            ),
        ],
      ),
    );
  }

  /// 搜索态吸顶搜索框层：钉在顶栏下方，不再随列表滚动穿过悬浮玻璃栏
  /// （用户反馈滚动时搜索框穿顶被雾面遮住/模糊）。与分类条吸顶同机制。
  Widget _searchHeaderBar(BuildContext context, double topInset) {
    return SizedBox(
      height: _searchHeaderExtent(topInset),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _fogBandHeight(_searchHeaderExtent(topInset)),
            child: const TopFog(),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(16, topInset + 6, 16, 4),
            child: SearchInput(
              key: ValueKey('search-${_group.id}'),
              controller: _search,
              autofocus: _searchAutoFocus,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? (query) => widget.repository.suggestions(
                      query,
                      source: _source.id,
                    )
                  : null,
              onSuggestionSelected:
                  _searchSuggestions ? _playSuggestion : null,
              onChanged: _searchChanged,
              onCancel: () => unawaited(
                widget.repository.cancelSuggestions(),
              ),
              onSearch: _submitSearch,
            ),
          ),
        ],
      ),
    );
  }

  Widget _pinnedFiltersBar(BuildContext context, double topInset) {
    return SizedBox(
      // 布局高度只随正档增长（负档只缩雾，不裁分类 chips）。
      height: topInset + _filtersExtent + (_fogHeight > 0 ? _fogHeight : 0),
      child: Stack(
        children: [
          // 雾面整条盖满吸顶头（状态栏→顶栏→分类条均匀一整块，底缘
          // 硬切）：用户定调「不要凹凸感」——只垫上沿会在雾面与清晰
          // 内容之间留一条明暗分界台阶；整块糊化后无分界。TopFog 按
          // 自身高度自适应（玻璃开关总控，关闭即完全穿透）。
          // 雾面定高：负档时雾短于吸顶头（分类 chips 区露出来）。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _fogBandHeight(topInset + _filtersExtent),
            child: const TopFog(),
          ),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            // 吸顶头已有整条雾面模糊盖住分类条 → 分类胶囊继承该模糊，
            // 不再各自采样（同层单 backdrop，避免整体发灰）。
            // 雾面高度调成负档时整条模糊盖不满分类条，胶囊回退自带磨砂。
            child: _catalogFilters(inheritBlur: _fogHeight >= 0),
          ),
        ],
      ),
    );
  }

  Widget _selectionBar({bool safeBottom = true}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    final bottomInset =
        (safeBottom ? MediaQuery.paddingOf(context).bottom : 0.0) + 12;
    return Padding(
      padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final summary = Semantics(
            liveRegion: true,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  count == 0
                      ? '最多 ${BatchDownloads.maxDramas} 部'
                      : '下一步选择分集和画质',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
          final next = FilledButton(
            key: const ValueKey('download-selected-dramas'),
            focusNode: _selectionFocus,
            onPressed: count == 0 ? null : _downloadSelected,
            style: FilledButton.styleFrom(
              minimumSize: const Size(96, 48),
              padding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 12,
              ),
            ),
            child: const Text('下一步'),
          );
          final Widget content =
              constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [summary, const SizedBox(height: 12), next],
                )
              : Row(
                  children: [
                    Expanded(child: summary),
                    const SizedBox(width: 16),
                    next,
                  ],
                );
          return GlassSurface(
            variant: GlassVariant.surface,
            radius: GlassTokens.radiusBar,
            // 形态：方形圆角矩形（宽扁顶栏条不做药丸）。
            borderRadius: BorderRadius.circular(GlassTokens.radiusBar),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            // 双态玻璃材质：与分类条/底栏同源（pill 档）。
            tint: GlassTint.pill,
            child: content,
          );
        },
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: _gridKey,
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      onExitUp: () => _filtersKey.currentState?.focusCurrent(),
      onExitLeft: () => _navKey.currentState?.focusCurrent(),
      onExitDown: _selectionMode ? () => _selectionFocus.requestFocus() : null,
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}


