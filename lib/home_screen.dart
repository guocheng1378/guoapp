import 'dart:async';
import 'dart:math' show max;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'about_card.dart';
import 'app_bottom_navigation.dart';
import 'core_bridge.dart';
import 'glass.dart';
import 'glass_menu.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'home_carousel.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'playback_launch_screen.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'lan_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'search_input.dart';
import 'sources_screen.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'saved_library.dart';

/// 手机/iOS 悬浮玻璃底栏的内容底部避让高度（栏高 68 + 浮动下边距 12 + 余量）。
const _floatingNavInset = 96.0;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
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
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;
  bool _catalogLoadScheduled = false;
  final _filtersKey = GlobalKey<RemoteRowState>();
  final _gridKey = GlobalKey<RemoteGridState>();
  final _navKey = GlobalKey<RemoteListState>();
  final _appBarFocus = FocusNode(debugLabel: 'tv-appbar');
  final _sourceMenuKey = GlobalKey(debugLabel: 'source-menu-anchor');
  final _moreMenuKey = GlobalKey(debugLabel: 'more-menu-anchor');
  final _sortMenuKey = GlobalKey(debugLabel: 'sort-menu-anchor');
  final _selectionFocus = FocusNode(debugLabel: 'tv-selection');

  // 首页站源菜单按三分类组织（与站源管理页同口径）：
  // 短剧类 / 视频类 / 黄果类，无「全部站源」聚合项；默认落在当前源所在类。
  List<SourceGroup> get _sourceCategories {
    final sources = widget.store.sources;
    final huangguo = sources
        .where((source) => source.inHuangguoCategory)
        .toList();
    final rest = sources
        .where((source) => !source.inHuangguoCategory)
        .toList();
    final shortDrama = rest.where((source) => source.isShortDrama).toList();
    final video = rest.where((source) => source.isVideoSource).toList();
    return [
      if (shortDrama.isNotEmpty) SourceGroup('cat-short', '短剧类', shortDrama),
      if (video.isNotEmpty) SourceGroup('cat-video', '视频类', video),
      if (huangguo.isNotEmpty)
        SourceGroup('cat-huangguo', '黄果类', huangguo),
    ];
  }

  // 首页始终加载当前选中源（单源），不在三分类间聚合。
  SourceGroup get _group =>
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);
  String get _searchHint {
    if (!_onlineSearch) {
      return '筛选本机已更新剧库';
    }
    return _group.id == 'all' ? '搜索全部站源及本机剧库' : '搜索${_group.name}';
  }

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

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
    if (!_showRecommendations &&
        _category.isNotEmpty &&
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

  /// 长按站源岛：弹出三分类选择菜单，点选一类即切到该类第一个源。
  Future<void> _pickSourceCategory() async {
    final categories = _sourceCategories;
    if (categories.length <= 1) return;
    final picked = await showGlassMenu<SourceGroup>(
      context: context,
      anchorKey: _sourceMenuKey,
      entries: [
        for (final category in categories)
          GlassMenuEntry(
            category,
            category.name,
            checked: category.sources.any((source) => source.id == _source.id),
          ),
      ],
    );
    if (picked != null && picked.sources.isNotEmpty) {
      _changeSource(picked.sources.first);
    }
  }

  /// 手机端站源切换玻璃菜单（TV 端走 PopupMenuButton 实底保焦点导航）。
  /// 只列当前源所在分类下的源（想换类用长按站源岛弹三分类菜单，见 _pickSourceCategory）。
  Future<void> _showSourceMenu() async {
    final categories = _sourceCategories;
    if (categories.expand((category) => category.sources).length <= 1) return;
    final current = categories.firstWhere(
      (category) => category.sources.any((source) => source.id == _source.id),
      orElse: () => categories.first,
    );
    final entries = <GlassMenuEntry<SourceSite>>[
      GlassMenuEntry(current.sources.first, current.name, header: true),
      for (final source in current.sources)
        GlassMenuEntry(source, source.name, checked: source.id == _source.id),
    ];
    final picked = await showGlassMenu<SourceSite>(
      context: context,
      anchorKey: _sourceMenuKey,
      entries: entries,
    );
    if (picked != null) _changeSource(picked);
  }

  void _onMoreSelected(String value) {
    if (value == 'rankings') {
      _openRankings();
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
      Navigator.push(
        context,
        MaterialPageRoute<void>(
          builder: (_) => ProfilesScreen(store: widget.store),
        ),
      );
    } else if (value == 'display') {
      _chooseDisplayMode();
    } else if (value == 'about') {
      // 手机端：锚定 ⋯ 岛的轻量信息浮卡——无 barrier 压暗、点空白关闭，
      // 与排序筛选浮卡同族；TV 保留玻璃弹窗（遥控焦点导航可靠）。
      if (AppLayout.isTelevision(context)) {
        showDialog<void>(
          context: context,
          builder: (context) => GlassDialogShell(
            child: AboutDialog(
              applicationName: appName,
              applicationVersion: AppLayout.versionOf(context),
              applicationIcon: const Icon(
                Icons.play_circle_filled_rounded,
                size: 48,
                color: Color(0xFFFF765F),
              ),
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
        );
      }
    }
  }

  /// 顶栏独立玻璃胶囊岛：手机端把标题/按钮各自包成悬浮岛，
  /// TV/桌面保持原样（glass=false）。
  Widget _navPill(Widget child, {required bool glass}) {
    if (!glass) return child;
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: GlassSurface(
        radius: 24,
        topHighlight: true,
        // 统一滑动栏瓷面档：微透白瓷（默认 dark 0.08/light 0.72）
        // + 白描边，与分类胶囊同材质语言。
        child: child,
      ),
    );
  }

  Future<void> _showMoreMenu({required bool narrow}) async {
    final value = await showGlassMenu<String>(
      context: context,
      anchorKey: _moreMenuKey,
      entries: [
        // 「更新剧库」入口已移除：首页内容区有下拉刷新，菜单不再重复。
        if (_tab == 0 && !_showRecommendations)
          const GlassMenuEntry('rankings', '榜单'),
        if (widget.repository.supportsSourceManagement)
          const GlassMenuEntry('sources', '站源管理'),
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
      if (!_searchVisible) _search.clear();
    });
    if (!_searchVisible && hadQuery) _searchChanged('');
  }

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
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
    // 与「设置与备份」同款玻璃胶囊菜单：独立胶囊列+勾选态，
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
        title: _group.id == 'all'
            ? '搜索已开放站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
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

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onCatalogScroll);
    _source = SourceSite.byId(widget.store.source);
    _browser = CatalogBrowser(widget.repository);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _search.dispose();
    _scroll.removeListener(_onCatalogScroll);
    _scroll.dispose();
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
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
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
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        if (!more) _items = [];
        _error = error.toString();
      });
    }
  }

  void _changeSource(SourceSite source) {
    if (_source.id == source.id) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _source = source;
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: false),
      ),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
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

  Future<void> _chooseCatalogView() async {
    // TV 保留底部弹层：遥控焦点导航可靠 + 「应用」确认步骤；
    // 手机改锚定 ≡ 岛的轻量筛选浮卡，点选即生效，不再占半屏大玻璃。
    if (AppLayout.isTelevision(context)) {
      final selected = await chooseCatalogView(
        context,
        widget.store.catalogView,
      );
      if (selected != null && mounted) {
        await saveUserChange(
          context,
          () => widget.store.setCatalogView(selected),
        );
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      }
      return;
    }
    await showCatalogFilterMenu(
      context: context,
      anchorKey: _sortMenuKey,
      current: widget.store.catalogView,
      onChanged: (view) async {
        await saveUserChange(
          context,
          () => widget.store.setCatalogView(view),
        );
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      },
    );
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
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

  void _changeTab(int tab) => setState(() {
    _tab = tab;
    _selectionMode = false;
    _selectedDramas.clear();
  });

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
    onContinue: () => _openDrama(drama, resume: true),
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
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        store: widget.store,
        onContinue: () => _openDrama(drama, resume: true),
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

  List<Drama>? _visibleCache;
  String? _visibleKey;

  /// 过滤+排序结果缓存：key 覆盖全部输入（条目集、分类、搜索词、在线
  /// 搜索、排序视图、VIP 隐藏、站源开关），任一变化即重算——不靠手动
  /// 失效点枚举，杜绝「改了输入忘了清缓存」；单次 build 内多次调用
  /// （items 与 _searchGroups）只排一次序。
  List<Drama> get _visible {
    final key = [
      identityHashCode(_items),
      _category,
      _search.text,
      _onlineSearch,
      widget.store.catalogView,
      _hideVip,
      for (final source in _group.sources)
        widget.store.allowsSource(source.id),
    ].join('|');
    final cached = _visibleCache;
    if (cached != null && _visibleKey == key) return cached;
    final query = _search.text.trim().toLowerCase();
    final result = sortCatalog(
      _items.where((drama) {
        if (!widget.store.allowsSource(drama.source)) return false;
        if (_category.startsWith('local:') &&
            categoryName(drama.category) != _category.substring(6)) {
          return false;
        }
        if (_hideVip && drama.source == 'huangdou' && drama.vip) {
          return false;
        }
        return _onlineSearch ||
            query.isEmpty ||
            matchesDramaQuery(drama, query);
      }),
      widget.store.catalogView,
    );
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
  Map<String, List<Drama>>? get _searchGroups {
    final query = _search.text.trim().toLowerCase();
    if (!_onlineSearch || _submittedQuery.isEmpty || query.isEmpty) {
      return null;
    }
    final items = _visible;
    int relevance(Drama drama) => _relevanceOf(drama, query);
    final groups = <String, List<Drama>>{};
    final best = <String, int>{};
    for (final drama in items) {
      final rank = relevance(drama);
      groups.putIfAbsent(drama.source, () => []).add(drama);
      final current = best[drama.source];
      if (current == null || rank < current) best[drama.source] = rank;
    }
    if (groups.length < 2) return null;
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
    return {for (final key in keys) key: ordered[key]!};
  }

  Widget _sourceSectionHeader(String sourceId, double padding) {
    final theme = Theme.of(context);
    return SliverToBoxAdapter(
      child: Padding(
        padding: EdgeInsets.fromLTRB(padding, 4, padding, 4),
        child: Text(
          SourceSite.byId(sourceId).name,
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
        final television = AppLayout.isTelevision(context);
        final desktop = constraints.maxWidth >= 840;
        // 悬浮玻璃底栏只在手机/iOS 出现；开启 extendBody 让内容透到玻璃后被模糊。
        final floatingNav = !desktop && !television;
        final navEntries = <(int, IconData, String)>[
          (0, Icons.explore_rounded, '发现'),
          (1, Icons.bookmark_rounded, '追剧'),
          (2, Icons.history_rounded, '最近观看'),
          if (widget.store.canDownload) (3, Icons.download_rounded, '下载'),
        ];
        final topInset = floatingNav
            ? MediaQuery.paddingOf(context).top + 56.0
            : 0.0;
        final scaffold = Scaffold(
          extendBody: floatingNav,
          // 手机端顶栏悬浮玻璃：内容延伸到顶栏后方，滚动时从玻璃后穿过。
          extendBodyBehindAppBar: floatingNav,
          appBar: AppBar(
            toolbarHeight: television ? 64 : null,
            // 手机端顶栏：贴顶渐隐雾面回归，压低模糊与底色让穿透
            // 内容大面积可辨；独立胶囊岛照常叠加其上。
            titleSpacing: floatingNav ? 8 : 12,
            actionsPadding: floatingNav
                ? const EdgeInsets.only(right: 8)
                : null,
            // 贴顶渐隐雾面属于玻璃浮层，受「玻璃效果」开关总控：
            // 关闭后不渲染任何模糊层，顶栏完全穿透。
            flexibleSpace: floatingNav ? const TopFog() : null,
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
                      ? PopupMenuButton<SourceSite>(
                          key: const ValueKey('source-switch'),
                          tooltip: '切换站源',
                          enabled: _sourceCategories.expand((c) => c.sources).length > 1,
                          onSelected: _changeSource,
                          itemBuilder: (_) => [
                            for (final category in _sourceCategories) ...[
                              if (category != _sourceCategories.first)
                                const PopupMenuDivider(),
                              ...category.sources.map(
                                (source) => PopupMenuItem<SourceSite>(
                                  value: source,
                                  child: Row(
                                    children: [
                                      Expanded(child: Text(source.name)),
                                      if (source.id == _source.id)
                                        const Icon(
                                          Icons.check_rounded,
                                          size: 20,
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
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
                                  const Icon(Icons.expand_more_rounded),
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
                                HapticFeedback.lightImpact();
                                _pickSourceCategory();
                              },
                              child: KeyedSubtree(
                                // 胶囊菜单锚点仍用 _sourceMenuKey（GlobalKey）。
                                key: _sourceMenuKey,
                                child: SizedBox(
                                  height: 48,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          _group.name.isEmpty
                                              ? appName
                                              : _group.name,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w800,
                                            fontSize: 13,
                                          ),
                                        ),
                                      ),
                                      if (_sourceCategories.expand((c) => c.sources).length > 1)
                                        const Icon(Icons.expand_more_rounded),
                                    ],
                                  ),
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
                    IconButton(
                      key: const ValueKey('follow-lan-sync'),
                      tooltip: '追剧同步',
                      onPressed: () => openLanSync(context),
                      icon: const Icon(Icons.sync_rounded),
                    ),
                  ),
                if (_tab == 0) ...[
                  // 站源岛已移回 title 槽贴左：actions 删除多选按钮后
                  // title 宽度充裕，站源名不再截断；actions 仅留工具岛贴右。
                  if (!_showRecommendations)
                    _navPill(
                      glass: floatingNav,
                      IconButton(
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
                        icon: const Icon(Icons.sort_rounded),
                      ),
                    ),
                  _navPill(
                    glass: floatingNav,
                    IconButton(
                      key: const ValueKey('toggle-search'),
                      tooltip: _searchVisible ? '收起搜索' : '搜索',
                      icon: Icon(
                        _searchVisible
                            ? Icons.search_off_rounded
                            : Icons.search_rounded,
                      ),
                      onPressed: _toggleSearch,
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
                              value: 'sources',
                              child: Text('站源管理'),
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
                        IconButton(
                          key: _moreMenuKey,
                          tooltip: '更多',
                          onPressed: () => _showMoreMenu(
                            narrow: constraints.maxWidth < 400,
                          ),
                          icon: const Icon(Icons.more_vert_rounded),
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
                        icon: Icon(Icons.explore_outlined),
                        selectedIcon: Icon(Icons.explore),
                        label: Text('发现'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.bookmark_border_rounded),
                        selectedIcon: Icon(Icons.bookmark_rounded),
                        label: Text('追剧'),
                      ),
                      NavigationRailDestination(
                        icon: Icon(Icons.history_rounded),
                        label: Text('最近观看'),
                      ),
                      if (widget.store.canDownload)
                        NavigationRailDestination(
                          icon: Icon(Icons.download_outlined),
                          selectedIcon: Icon(Icons.download_rounded),
                          label: Text('下载'),
                        ),
                    ],
                  ),
                  const VerticalDivider(width: 1, thickness: 1),
                ],
                Expanded(
                  child: _tab == 0
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
                          bottomInset: floatingNav ? _floatingNavInset : 0,
                          topInset: topInset,
                        )
                      : SavedLibrary(
                          key: ValueKey('saved-tab-$_tab'),
                          repository: widget.repository,
                          store: widget.store,
                          bottomInset: floatingNav ? _floatingNavInset : 0,
                          topInset: topInset,
                          history: _tab == 2,
                          remoteAutofocus: television,
                          onExitLeft: television
                              ? () => _navKey.currentState?.focusCurrent()
                              : null,
                          onOpen: _openDrama,
                          onContinue: (drama) =>
                              _openDrama(drama, resume: true),
                          onDownload:
                              widget.repository.supportsDownloads &&
                                  widget.store.canDownload
                              ? (drama) => _openDrama(drama, download: true)
                              : null,
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
                  destinations: [
                    NavigationDestination(
                      icon: Icon(Icons.explore_outlined),
                      selectedIcon: Icon(Icons.explore),
                      label: '发现',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.bookmark_border_rounded),
                      selectedIcon: Icon(Icons.bookmark_rounded),
                      label: '追剧',
                    ),
                    NavigationDestination(
                      icon: Icon(Icons.history_rounded),
                      label: '最近观看',
                    ),
                    if (widget.store.canDownload)
                      NavigationDestination(
                        icon: Icon(Icons.download_outlined),
                        selectedIcon: Icon(Icons.download_rounded),
                        label: '下载',
                      ),
                  ],
                ),
        );
        if (!television && !_selectionMode) return scaffold;
        return PopScope(
          canPop:
              !_selectionMode &&
              (!television || _tab == 0 && _search.text.isEmpty),
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
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
              autofocus: true,
              hint: _searchHint,
              suggestions: _searchSuggestions
                  ? widget.repository.suggestions
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
                              avatar: const Icon(
                                Icons.history_rounded,
                                size: 16,
                              ),
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
                  icon: const Icon(Icons.delete_outline_rounded, size: 20),
                ),
              ],
            ),
          ),
        Padding(
          padding: EdgeInsets.only(top: topInset),
          child: _catalogFilters(televisionFocus: true),
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
                      icon: Icons.wifi_off_rounded,
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
                                        icon: Icons.expand_more,
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
                        final navInset = constraints.maxWidth >= 840
                            ? 0.0
                            : _floatingNavInset;
                        final searchGroups = _searchGroups;
                        final gridDelegate = dramaGridDelegate(
                          context,
                          constraints.maxWidth - 2 * padding,
                        );
                        return RefreshIndicator(
                          onRefresh: () {
                            // 下拉触发刷新时给一次中档震动（主题同款手感）。
                            HapticFeedback.mediumImpact();
                            return _refreshCatalog();
                          },
                          // anywhere：页面顶部边缘之外（如轮播卡上方空隙）
                          // 起手的下拉也计入刷新，真机手感更宽容。
                          triggerMode: RefreshIndicatorTriggerMode.anywhere,
                          child: CustomScrollView(
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
                                      (_, index) => _catalogTile(items[index]),
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
                                            icon: const Icon(
                                              Icons.expand_more_rounded,
                                            ),
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
    // 轮播消费排序后的前几条：网格跳过这些条目，避免动图与下方剧图重复。
    final carouselIds = !_searchVisible && items.isNotEmpty
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
          child: GestureDetector(
            onHorizontalDragEnd: _swipeCategory,
            child: RefreshIndicator(
              onRefresh: () {
                            // 下拉触发刷新时给一次中档震动（主题同款手感）。
                            HapticFeedback.mediumImpact();
                            return _refreshCatalog();
                          },
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
                  final navInset = constraints.maxWidth >= 840
                      ? 0.0
                      : _floatingNavInset;
                  final gridDelegate = dramaGridDelegate(
                    context,
                    constraints.maxWidth - 2 * padding,
                  );
                  return CustomScrollView(
                    controller: _scroll,
                    // 必须是 clamping 系物理：RefreshIndicator 依赖
                    // OverscrollNotification 触发，bouncing 物理不发该通知
                    // 会导致下拉刷新失效。
                    physics: const AlwaysScrollableScrollPhysics(),
                    slivers: [
                      if (_searchVisible)
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: EdgeInsets.fromLTRB(
                              16,
                              4 + topInset,
                              16,
                              4,
                            ),
                            child: SearchInput(
                              key: ValueKey('search-${_group.id}'),
                              controller: _search,
                              autofocus: true,
                              hint: _searchHint,
                              suggestions: _searchSuggestions
                                  ? widget.repository.suggestions
                                  : null,
                              onChanged: _searchChanged,
                              onCancel: () => unawaited(
                                widget.repository.cancelSuggestions(),
                              ),
                              onSearch: _submitSearch,
                            ),
                          ),
                        ),
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
                                              avatar: const Icon(
                                                Icons.history_rounded,
                                                size: 16,
                                              ),
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
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                    size: 20,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      // 分类条吸顶：固定在顶栏玻璃正下方，不随内容滚走；
                      // 搜索态改随搜索岛一起滚动（见下方滚动分支）。
                      if (!_searchVisible)
                        SliverPersistentHeader(
                          pinned: true,
                          delegate: _PinnedFiltersDelegate(
                            extent: topInset + _filtersExtent,
                            builder: (context) =>
                                _pinnedFiltersBar(context, topInset),
                          ),
                        ),
                      if (_searchVisible)
                        SliverToBoxAdapter(
                          // 搜索岛已避让顶栏，筛选岛紧随其后。
                          child: _catalogFilters(),
                        ),
                      if (!_searchVisible && items.isNotEmpty)
                        SliverToBoxAdapter(
                          child: Padding(
                            // 轮播与下方剧卡流的间距。
                            padding: const EdgeInsets.only(bottom: 14),
                            child: HomeCarousel(
                              items: items,
                              repository: widget.repository,
                              onOpen: _openDrama,
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
                            icon: Icons.wifi_off_rounded,
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
                              (_, index) => _catalogTile(gridItems[index]),
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
                                (_, index) => _catalogTile(entry.value[index]),
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
                                    icon: const Icon(
                                      Icons.expand_more_rounded,
                                    ),
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
        ),
        if (_selectionMode && selectionInBody)
          _selectionBar(safeBottom: false),
      ],
    );
  }

  /// 分类条总高（含上下外边距）：与 CatalogFilters 非 TV 布局保持一致。
  double get _filtersExtent =>
      CatalogFilters.barHeight(context, extra: 12);

  /// 吸顶分类条：不做整条底板/雾面，分类胶囊本身是独立瓷面小岛，
  /// 剧照直接从胶囊间隙与条后穿过，保持「一枚枚胶囊浮在内容上」的形态。
  /// 雾面只覆盖状态栏+顶栏（flexibleSpace 的 TopFog），按需求不渲染到
  /// 左右横滑条——条后是原始滚动内容，胶囊浮在上面。
  /// 分类条构造（TV 列表/搜索岛/吸顶条三处共用）：差异仅在电视焦点
  /// 出口回调，由 [televisionFocus] 开关。
  Widget _catalogFilters({bool televisionFocus = false}) {
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

  Widget _pinnedFiltersBar(BuildContext context, double topInset) {
    return SizedBox(
      height: topInset + _filtersExtent,
      child: Padding(
        padding: EdgeInsets.only(top: topInset),
        child: _catalogFilters(),
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
            topHighlight: true,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            tint: GlassTint.bar,
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

/// 首页分类条吸顶代理：固定在顶栏玻璃正下方，内容从其后方穿过。
class _PinnedFiltersDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedFiltersDelegate({required this.builder, required this.extent});

  final WidgetBuilder builder;
  final double extent;

  @override
  double get maxExtent => extent;

  @override
  double get minExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => builder(context);

  @override
  bool shouldRebuild(covariant _PinnedFiltersDelegate oldDelegate) =>
      oldDelegate.extent != extent || oldDelegate.builder != builder;
}
