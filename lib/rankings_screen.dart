import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'catalog_filters.dart';
import 'core_bridge.dart';
import 'detail_screen.dart';
import 'featured_catalog.dart';
import 'fog_tint_sampler.dart';
import 'fog_tuning.dart';
import 'folme.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'app_icons.dart';

/// 「共 N 部」，对齐云追 `text_topic_count`。
String _episodeCountLabel(Drama drama) =>
    drama.episodes > 0 ? '共 ${drama.episodes} 部' : '';

/// 「更新至 N 集」，对齐云追 `text_update_to_episode`。
String _updateLabel(Drama drama) =>
    drama.episodes > 0 ? '更新至 ${drama.episodes} 集' : '';

/// 分类标签 `[分类]`，对齐云追 `text_topic_tag_count`。
String _categoryTagLabel(Drama drama) =>
    drama.category.isEmpty ? '' : '[${drama.category}]';

/// 榜单指标：豆瓣条目已由内核生成（评分 / 年份兜底），直接透传。
String _rankingMetricLabel(RankingItem item) => item.metric.trim();

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialCategory = '',
  });
  final AppRepository repository;
  final LocalStore store;

  /// 初始四分类（首页当前源的归属：shortDrama/video/huangguo/adult）。
  final String initialCategory;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scroll = ScrollController();
  final _categoriesKey = GlobalKey<RemoteRowState>();
  final _kindsKey = GlobalKey<RemoteRowState>();
  final _boardsKey = GlobalKey<RemoteRowState>();
  final _listKey = GlobalKey<RemoteListState>();
  List<RankingBoard> _boards = [];
  RankingBoard? _board;
  List<RankingItem> _items = [];
  bool _loading = true;
  bool _more = false;
  bool _hasMore = false;
  bool _failedMore = false;
  int _page = 1;
  int _generation = 0;
  String? _error;
  String _updated = '';

  /// 接近度信号（主页同款真值）：滚动距离/50 clamp 0..1，驱动顶栏雾玻璃
  /// 岛白描边亮起；滚回顶部熄灭。同值不通知，滚动稳态零开销。
  final ValueNotifier<double> _prox = ValueNotifier<double>(0);

  /// 雾面动态取色采样色（null=纯白雾）：FogTintSampler 节流采样内容区
  /// 像素平均色，驱动顶部雾带染色（调参台 tintMix 控制浓度，与主页同源）。
  final ValueNotifier<Color?> _fogTint = ValueNotifier<Color?>(null);

  /// 调参台「雾面高度」延伸量：雾面挂点高度随之增减（0=现状）。仅此
  /// 参数需要整页 rebuild（挂点高度变化），其余维度由 TopFog 内部监听
  /// 自行重建。初值直接读 store 对齐——主页以 0 起步靠后续变化通知
  /// 补同步，榜单页冷启动即取真值，不丢首帧。
  double _fogHeight = FogTuningStore.state.value.fogHeight;

  /// 当前豆瓣榜内部分组（电影 / 剧集 / 综艺 / 站源），空 = 无需分组。
  String _kind = '';

  /// 当前四分类（shortDrama / video / huangguo / adult）。榜单按站源四分类
  /// 归属，各类只显示自己的榜：短剧类→红果等，视频类→豆瓣官方榜+影视类
  /// 站源榜，黄果类→黄豆/黄果系/剧果/野果等；无榜的分类不进分类行。
  String _category = '';

  static const _categoryOrder = ['shortDrama', 'video', 'huangguo', 'adult'];

  String _categoryOf(RankingBoard board) =>
      SourceSite.byId(board.source)?.classKey ?? 'video';

  /// 豆瓣榜内部分组（按合集 id 前缀）：电影 / 剧集 / 综艺；站源榜归「站源」。
  /// 每个分组下只显示自己的榜，避免视频类下十几枚榜 chips 混排。
  static const _kindOrder = ['电影', '剧集', '综艺', '站源'];

  String _kindOf(RankingBoard board) {
    if (!board.id.startsWith('douban-')) return '站源';
    if (board.id.startsWith('douban-tv-')) return '剧集';
    if (board.id.startsWith('douban-show-')) return '综艺';
    return '电影';
  }

  List<String> _kindsOf(List<RankingBoard> boards, String category) => [
    for (final kind in _kindOrder)
      if (boards.any(
        (board) => _categoryOf(board) == category && _kindOf(board) == kind,
      ))
        kind,
  ];

  List<CatalogCategory> _categoriesOf(List<RankingBoard> boards) => [
    for (final id in _categoryOrder)
      if (boards.any((board) => _categoryOf(board) == id))
        CatalogCategory(id, SourceSite.classLabel(id)),
  ];

  /// 黄果类/成人类榜单整组隐藏，与站源菜单/管理页同口径：仅在「关于」
  /// 浮卡连点 5 次解锁（restrictedUnlocked）后显示。
  static const _restrictedCategories = {'huangguo', 'adult'};

  bool _boardVisible(RankingBoard board) =>
      widget.store.restrictedUnlocked ||
      !_restrictedCategories.contains(_categoryOf(board));

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    FogTuningStore.state.addListener(_onFogTuning);
    _initialize();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    FogTuningStore.state.removeListener(_onFogTuning);
    _generation++;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _prox.dispose();
    _fogTint.dispose();
    super.dispose();
  }

  /// 调参台「雾面高度」变化回调：值变了才 setState（雾面挂点高度需
  /// 整页 rebuild）；拖动其它滑块零开销（主页同款）。
  void _onFogTuning() {
    final h = FogTuningStore.state.value.fogHeight;
    if (h != _fogHeight && mounted) setState(() => _fogHeight = h);
  }

  /// 雾面挂点实际高度：负档收窄（底缘上移，最少收到 0），正档向下
  /// 延伸盖住列表顶部；clamp≥0 防负高度断言（主页同款）。
  double _fogBandHeight(double base) {
    final h = base + _fogHeight;
    return h < 0 ? 0 : h;
  }

  /// 接近度信号更新（主页同款）：滚动距离/50 clamp 0..1。走
  /// ScrollNotification 冒泡，横滑通知过滤掉。
  bool _onBodyScroll(ScrollNotification n) {
    if (n.metrics.axis != Axis.vertical) return false;
    _prox.value = (n.metrics.pixels / 50).clamp(0.0, 1.0);
    return false;
  }

  /// 主页同款雾化 body（手机/桌面）：沉浸延伸 + 动态取色 + 接近度监
  /// 听；TV 走原样 SafeArea（遥控焦点链不动）。
  ///
  /// 雾带挂在吸顶筛选头内（_pinnedFiltersBar，与主页 tab0 同构）：整
  /// 条盖住状态栏→顶栏→筛选行，内容滚动穿到其后方时被糊化提亮、色跟
  /// 内容走——这正是 flexibleSpace 挂法在无沉浸延伸页面上做不到的
  ///（雾面背后没有内容可采样，只剩死白蒙）。
  Widget _fogBody({
    required bool floatingFog,
    required double topInset,
    required Widget child,
  }) {
    if (!floatingFog) return SafeArea(top: false, child: child);
    return FogTintSampler(
      tint: _fogTint,
      // 采样行带避开顶部雾带自身（防反馈循环），与首页接线同参。
      sampleBandStart: 0.30,
      sampleBandEnd: 0.62,
      child: NotificationListener<ScrollNotification>(
        onNotification: _onBodyScroll,
        child: Stack(
          children: [
            // 主页铁律（home_screen._catalogFloating）：滚动视口必须从
            // 屏幕顶端 y=0 铺满，内容上滑才能穿进雾带后方被糊化；初始
            // 下移交给吸顶头自身 extent。视口压在 topInset 处会被上边
            // 缘裁剪成「雾面背后只有背景色」的假透（糊一块死背景堵在
            // 顶上）。雾带在吸顶头内（pinned 首位 sliver），不再外挂。
            Positioned.fill(child: SafeArea(top: false, child: child)),
          ],
        ),
      ),
    );
  }

  /// 吸顶筛选头（主页 _pinnedFiltersBar 同构）：雾面整条盖住吸顶头
  /// （状态栏→顶栏→筛选行均匀一块，底缘硬切），筛选行浮在雾面之上。
  /// 布局高度只随正档雾延伸增长（负档只缩雾，不裁筛选行）。
  Widget _pinnedFiltersBar(
    BuildContext context, {
    required double topInset,
    required double rowsExtent,
    required List<Widget> rows,
  }) {
    return SizedBox(
      height: topInset + rowsExtent + (_fogHeight > 0 ? _fogHeight : 0),
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            height: _fogBandHeight(topInset + rowsExtent),
            child: ValueListenableBuilder<Color?>(
              valueListenable: _fogTint,
              builder: (_, tint, _) => TopFog(tint: tint),
            ),
          ),
          Padding(
            padding: EdgeInsets.only(top: topInset),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [for (final row in rows) row],
            ),
          ),
        ],
      ),
    );
  }

  void _onScroll() {
    if (!mounted || !_hasMore || _loading || _more || !_scroll.hasClients) {
      return;
    }
    final position = _scroll.position;
    final threshold = (position.viewportDimension * 1.2).clamp(260.0, 720.0);
    if (position.extentAfter <= threshold) {
      _load(more: true);
    }
  }

  void _metadataChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _initialize() async {
    final generation = ++_generation;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final fetched = await widget.repository.rankingBoards();
      if (!mounted || generation != _generation) return;
      // 强隔离：榜单页只展示主页当前大类（initialCategory）的主榜，其他类
      // 一律不出现、也不提供切换入口。受限类（黄果/成人）未解锁时由
      // _boardVisible 过滤掉，当前类无榜则走空态渲染（不回落其它类）。
      final category = widget.initialCategory;
      final boards = fetched
          .where(_boardVisible)
          .where((board) => _categoryOf(board) == category)
          .toList();
      final kind = _kindsOf(boards, category).firstOrNull ?? '';
      setState(() {
        _boards = boards;
        _category = category;
        _kind = kind;
        _board = boards
            .where(
              (board) =>
                  _categoryOf(board) == category &&
                  (kind.isEmpty || _kindOf(board) == kind),
            )
            .firstOrNull;
        _loading = false;
      });
      if (_board != null) await _load();
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = error.toString();
        });
      }
    }
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    final board = _board;
    if (board == null || more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = false;
    });
    try {
      final result = await widget.repository.rankings(
        board.id,
        page: more ? _page + 1 : 1,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        final rows = <String, RankingItem>{
          if (more)
            for (final item in _items) item.drama.id: item,
          for (final item in result.items) item.drama.id: item,
        };
        _items = rows.values.toList()..sort((a, b) => a.rank.compareTo(b.rank));
        _page = result.page;
        _hasMore = result.hasMore;
        _updated = result.updatedText;
        _error = result.warning.isEmpty ? null : result.warning;
        _loading = false;
        _more = false;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString();
          _failedMore = more;
          _loading = false;
          _more = false;
        });
      }
    }
  }

  bool _passes(Drama drama) =>
      // 榜单条目是只读参考数据（不涉及播放/下载授权），仅按变体白名单放行，
      // 不走站源开关：关闭某源不影响其榜单展示。
      SourceSite.isRankingOnly(drama.source) ||
      SourceSite.isAvailable(drama.source);

  bool _isFollowing(Drama drama) => widget.store.isFavorite(drama.id);

  void _resetBoardState() {
    _items = [];
    _updated = '';
    _page = 1;
    _hasMore = false;
  }

  void _selectCategory(String id) {
    if (_category == id) return;
    final kind = _kindsOf(_boards, id).firstOrNull ?? '';
    final board = _boards
        .where(
          (board) =>
              _categoryOf(board) == id &&
              (kind.isEmpty || _kindOf(board) == kind),
        )
        .firstOrNull;
    if (board == null) return;
    setState(() {
      _category = id;
      _kind = kind;
      _board = board;
      _error = null;
      _resetBoardState();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _selectKind(String kind) {
    if (_kind == kind) return;
    final board = _boards
        .where(
          (board) => _categoryOf(board) == _category && _kindOf(board) == kind,
        )
        .firstOrNull;
    if (board == null) return;
    setState(() {
      _kind = kind;
      _board = board;
      _error = null;
      _resetBoardState();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  void _selectBoardId(String id) {
    final board = _boards.firstWhere((board) => board.id == id);
    if (_board?.id == board.id) return;
    setState(() {
      _board = board;
      _error = null;
      _resetBoardState();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final categories = _categoriesOf(_boards);
    // 分类行仅在有多个分类时出现；单分类直接展示榜行。
    final categoryRowVisible = categories.length > 1;
    final kinds = _kindsOf(_boards, _category);
    // 豆瓣榜按电影/剧集/综艺分组（站源榜归「站源」）；仅一组时无需类型行。
    final kindRowVisible = kinds.length > 1;
    final boards = _boards
        .where(
          (board) =>
              _categoryOf(board) == _category &&
              (!kindRowVisible || _kindOf(board) == _kind),
        )
        .toList();
    final items = _items
        .map(
          (item) => RankingItem(
            item.rank,
            widget.repository.catalogUpdates.current(item.drama),
            metric: item.metric,
          ),
        )
        .where((item) => _passes(item.drama))
        .toList();
    final rows = items;
    final busy = _loading || _more;
    // 主页同款雾化（手机/桌面）：沉浸顶栏 + 定高雾带（「雾面高度」
    // 参数响应）+ 动态取色 + 雾玻璃岛顶栏 + 接近度描边；TV 保持原
    // AppBar（遥控焦点链不动，雾面沿用 flexibleSpace TopFog）。
    final floatingFog = !television;
    final topInset = MediaQuery.paddingOf(context).top + 56.0;
    final refresh = RefreshAction(
      loading: busy,
      tooltip: '更新榜单',
      onPressed: _board == null ? _initialize : () => _load(force: true),
    );
    // 三条筛选行 / 描述 / 进度与错误行：TV（Column）与手机/桌面雾化
    //（全屏 slivers）两个容器共用同一组行组件，只构造一次。
    final categoryRow = categoryRowVisible
        ? CatalogFilters(
            key: const ValueKey('ranking-categories'),
            categories: categories,
            category: _category,
            remoteKey: _categoriesKey,
            remoteAutofocus: television,
            proxListenable: floatingFog ? _prox : null,
            onExitDown: television
                ? () => (kindRowVisible ? _kindsKey : _boardsKey)
                    .currentState
                    ?.focusCurrent()
                : null,
            onCategory: _selectCategory,
            onRetry: _initialize,
          )
        : null;
    final kindRow = kindRowVisible
        ? CatalogFilters(
            key: ValueKey('ranking-kinds-$_category'),
            categories: [
              for (final kind in kinds) CatalogCategory(kind, kind),
            ],
            category: _kind,
            remoteKey: _kindsKey,
            remoteAutofocus: television && !categoryRowVisible,
            proxListenable: floatingFog ? _prox : null,
            onExitUp: television && categoryRowVisible
                ? () => _categoriesKey.currentState?.focusCurrent()
                : null,
            onExitDown: television
                ? () => _boardsKey.currentState?.focusCurrent()
                : null,
            onCategory: _selectKind,
            onRetry: _initialize,
          )
        : null;
    final boardRow = boards.isNotEmpty
        ? CatalogFilters(
            key: ValueKey(
              kindRowVisible
                  ? 'ranking-boards-$_category-$_kind'
                  : categoryRowVisible
                  ? 'ranking-boards-$_category'
                  : 'ranking-boards',
            ),
            categories: [
              for (final board in boards)
                CatalogCategory(board.id, board.name),
            ],
            category: _board!.id,
            remoteKey: _boardsKey,
            remoteAutofocus:
                television && !categoryRowVisible && !kindRowVisible,
            proxListenable: floatingFog ? _prox : null,
            onExitUp: television && (categoryRowVisible || kindRowVisible)
                ? () => (kindRowVisible ? _kindsKey : _categoriesKey)
                    .currentState
                    ?.focusCurrent()
                : null,
            onExitDown: television
                ? () => _listKey.currentState?.focusCurrent()
                : null,
            onCategory: (id) => _selectBoardId(id),
            onRetry: () => _load(force: true),
          )
        : null;
    // 吸顶筛选行集合（手机/桌面钉在顶栏正下方，TV 保持原 Column）：
    // 主页吸顶分类条同构——雾面整条盖住吸顶头，描述行与榜单条目上滑
    // 从其后方穿过被糊化（「让界面穿过去」）。
    final pinnedRows = [
      ?categoryRow,
      ?kindRow,
      ?boardRow,
    ];
    // 吸顶头内容高度：可见行高之和 + 末行与内容的呼吸；行高单一来源
    // CatalogFilters.barHeight（与主页同口径，含系统字号缩放）。
    final pinnedRowsExtent = floatingFog && pinnedRows.isNotEmpty
        ? pinnedRows.length * CatalogFilters.barHeight(context) + 10.0
        : 0.0;
    final descriptionRow = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          [
            _board?.description ?? '',
            if (_updated.isNotEmpty) _updated,
          ].join(' ').trim(),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ),
    );
    final progressRow = busy && rows.isNotEmpty
        ? const LinearProgressIndicator(minHeight: 2)
        : null;
    final errorRow = _error != null && rows.isNotEmpty
        ? Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: busy
                      ? null
                      : () => _load(more: _failedMore, force: true),
                  child: const Text('重试'),
                ),
              ],
            ),
          )
        : null;
    return Scaffold(
      extendBodyBehindAppBar: floatingFog,
      appBar: AppBar(
        // 手机/桌面：雾面由 body 定高雾带承担（与主页 tab1-3 同构），
        // flexibleSpace 不再重复挂；TV 保持原样。
        flexibleSpace: floatingFog ? null : const TopFog(),
        title: floatingFog
            ? FogPill(
                prox: _prox,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: const Text('榜单'),
                ),
              )
            : const Text('榜单'),
        actions: [
          if (floatingFog) FogPill(prox: _prox, child: refresh) else refresh,
        ],
      ),
      body: _fogBody(
        floatingFog: floatingFog,
        topInset: topInset,
        child: floatingFog
            // 手机/桌面雾化：单一全屏 CustomScrollView（主页
            // _catalogFloating 同构）——视口从 y=0 铺满，筛选行吸顶、
            // 描述与榜单条目上滑穿进雾带后方被糊化。TV 分支（else）
            // 保持原 Column，遥控焦点链不动。
            ? FogRefresh(
                // 胶囊停在吸顶筛选行下方：顶栏+吸顶筛选行总高再留 8px
                // 间隙，雾面胶囊不罩到筛选行（与主页悬浮视图同构）。
                displacement: topInset + pinnedRowsExtent + 8,
                // 筛选行吸顶层：钉在原位不随下拉平移（与主页悬浮视图
                // 同构，真机定调「分组不跟着下来，刷新图标在白区」）。
                header: _pinnedFiltersBar(
                  context,
                  topInset: topInset,
                  rowsExtent: pinnedRowsExtent,
                  rows: pinnedRows,
                ),
                headerExtent:
                    topInset +
                    pinnedRowsExtent +
                    (_fogHeight > 0 ? _fogHeight : 0),
                onRefresh: () {
                  HapticFeedback.mediumImpact();
                  return _load(force: true);
                },
                child: CustomScrollView(
                  controller: _scroll,
                  physics: const AlwaysScrollableScrollPhysics(),
                  slivers: [
                    // 吸顶筛选头已挪到 FogRefresh.header 吸顶层（钉在
                    // 原位不随下拉平移）；视口内留等高占位，描述行/榜单
                    // 条目仍从其下方起排、上滑从雾面后方穿过，滚动语义
                    // 不变。
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            topInset +
                            pinnedRowsExtent +
                            (_fogHeight > 0 ? _fogHeight : 0),
                      ),
                    ),
                    SliverToBoxAdapter(child: descriptionRow),
                    if (progressRow != null)
                      SliverToBoxAdapter(child: progressRow),
                    if (errorRow != null) SliverToBoxAdapter(child: errorRow),
                    if (busy && rows.isEmpty)
                      const SliverFillRemaining(
                        hasScrollBody: false,
                        child: Center(child: CircularProgressIndicator()),
                      )
                    else if (rows.isEmpty)
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: StatusPanel(
                          title: _error == null
                              ? '暂无榜单内容'
                              : '榜单暂时无法加载',
                          message: _error ?? '当前榜单暂无可显示的内容。',
                          onRetry: _board == null
                              ? _initialize
                              : () => _load(force: true),
                        ),
                      )
                    else
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        sliver: SliverList.builder(
                          key: ValueKey('ranking-${_board!.id}'),
                          itemCount: rows.length + 1,
                          itemBuilder: (context, index) {
                            if (index == rows.length) {
                              return Center(
                                child: _more
                                    ? const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: CircularProgressIndicator(),
                                      )
                                    : _hasMore
                                    ? OutlinedButton(
                                        onPressed: () => _load(more: true),
                                        child: const Text('加载更多'),
                                      )
                                    : const Padding(
                                        padding: EdgeInsets.all(16),
                                        child: Text('已显示全部榜单'),
                                      ),
                              );
                            }
                            return _rankTile(rows[index]);
                          },
                        ),
                      ),
                  ],
                ),
              )
            : Column(
                children: [
                  ?categoryRow,
                  ?kindRow,
                  ?boardRow,
                  descriptionRow,
                  ?progressRow,
                  ?errorRow,
                  Expanded(
                    child: busy && rows.isEmpty
                        ? const Center(child: CircularProgressIndicator())
                        : rows.isEmpty
                        ? StatusPanel(
                            title: _error == null
                                ? '暂无榜单内容'
                                : '榜单暂时无法加载',
                            message: _error ?? '当前榜单暂无可显示的内容。',
                            onRetry: _board == null
                                ? _initialize
                                : () => _load(force: true),
                          )
                        // floatingFog=false 只可能是 TV（floatingFog=
                        // !television），列表固定 RemoteList 保焦点链。
                        : RemoteList(
                            key: _listKey,
                            itemKeys: [
                              for (final row in rows)
                                '${row.rank}-${row.drama.id}',
                            ],
                            itemExtent: 140,
                            spacing: 10,
                            controller: _scroll,
                            onExitUp:
                                () => _boardsKey.currentState?.focusCurrent(),
                            itemBuilder: (_, index, node, onFocus) {
                              return _rankTile(
                                rows[index],
                                focusNode: node,
                                onFocus: onFocus,
                              );
                            },
                          ),
                  ),
                ],
              ),
      ),
    );
  }

  /// 分类标签 / 集数 / 更新进度 / 追更标记。
  Widget _rankMeta(RankingItem item) {
    final theme = Theme.of(context);
    final tags = _categoryTagLabel(item.drama);
    final episodes = _episodeCountLabel(item.drama);
    final update = _updateLabel(item.drama);
    final following = _isFollowing(item.drama);
    if (tags.isEmpty && episodes.isEmpty && update.isEmpty && !following) {
      return const SizedBox.shrink();
    }
    final style = theme.textTheme.bodySmall?.copyWith(fontSize: 12);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Wrap(
        spacing: 8,
        runSpacing: 4,
        children: [
          for (final text in [tags, episodes, update])
            if (text.isNotEmpty)
              Text(
                text,
                style: style,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          if (following)
            Text(
              '追更中',
              style: style?.copyWith(
                color: theme.colorScheme.primary,
                fontWeight: FontWeight.w700,
              ),
            ),
        ],
      ),
    );
  }

  Widget _rankTile(
    RankingItem item, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final theme = Theme.of(context);
    final metric = _rankingMetricLabel(item);
    final update = _updateLabel(item.drama);
    final following = _isFollowing(item.drama);
    void open() {
      if (item.drama.source == SourceSite.douban.id) {
        openDoubanReferral(
          context,
          repository: widget.repository,
          store: widget.store,
          drama: item.drama,
        );
        return;
      }
      Navigator.push<void>(
        context,
        MaterialPageRoute(
          builder: (_) => DetailScreen(
            drama: item.drama,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
    }
    final body = Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 36,
            child: Text(
              '${item.rank}',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.w800,
                color: item.rank <= 3
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          SizedBox(
            width: 72,
            height: 108,
            child: DramaCover(
              drama: item.drama,
              repository: widget.repository,
              radius: 8,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(height: 2),
                _rankMeta(item),
                if (metric.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primaryContainer,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        metric,
                        style: TextStyle(
                          color: theme.colorScheme.onPrimaryContainer,
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          AppIcon(AppIcons.chevronRight),
        ],
      ),
    );
    if (focusNode == null && onFocus == null) {
      return Builder(
        builder: (itemContext) => Card(
          child: InkWell(
            key: ValueKey('rank-${item.rank}-${item.drama.id}'),
            borderRadius: BorderRadius.circular(12),
            onFocusChange: (focused) {
              if (focused) {
                Scrollable.ensureVisible(itemContext, alignment: .4);
              }
            },
            onTap: open,
            child: body,
          ),
        ),
      );
    }
    return RemoteTarget(
      key: ValueKey('rank-${item.rank}-${item.drama.id}'),
      focusNode: focusNode,
      onFocus: onFocus,
      outlined: true,
      borderWidth: 2,
      radius: 12,
      padding: EdgeInsets.zero,
      onPressed: open,
      label: [
        '第 ${item.rank} 名',
        item.drama.title,
        if (update.isNotEmpty) update,
        if (metric.isNotEmpty) metric,
        if (following) '追更中',
      ].join('，'),
      child: Card(margin: EdgeInsets.zero, child: body),
    );
  }
}


