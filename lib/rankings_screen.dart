import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'catalog_filters.dart';
import 'core_bridge.dart';
import 'detail_screen.dart';
import 'featured_catalog.dart';
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
    _initialize();
  }

  @override
  void dispose() {
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
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
      // 未解锁时黄果类/成人类榜不入 _boards：分类行、类型行、榜行与
      // 选中回落全部基于过滤后的列表（initialCategory 命中隐藏类时
      // 自动回落到第一个可见分类）。
      final boards = fetched.where(_boardVisible).toList();
      final categories = _categoriesOf(boards);
      final category = categories.any(
            (category) => category.id == widget.initialCategory,
          )
          ? widget.initialCategory
          : (categories.firstOrNull?.id ?? '');
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
      // 豆瓣榜条目不走站源开关（榜单专用源，无播放链路，仅参考展示）。
      SourceSite.isRankingOnly(drama.source) ||
      widget.store.allowsSource(drama.source);

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
    return Scaffold(
      appBar: AppBar(
        flexibleSpace: const TopFog(),
        title: const Text('榜单'),
        actions: [
          RefreshAction(
            loading: busy,
            tooltip: '更新榜单',
            onPressed: _board == null ? _initialize : () => _load(force: true),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (categoryRowVisible)
              CatalogFilters(
                key: const ValueKey('ranking-categories'),
                categories: categories,
                category: _category,
                remoteKey: _categoriesKey,
                remoteAutofocus: television,
                onExitDown: television
                    ? () => (kindRowVisible
                                ? _kindsKey
                                : _boardsKey)
                            .currentState
                            ?.focusCurrent()
                    : null,
                onCategory: _selectCategory,
                onRetry: _initialize,
              ),
            if (kindRowVisible)
              CatalogFilters(
                key: ValueKey('ranking-kinds-$_category'),
                categories: [
                  for (final kind in kinds) CatalogCategory(kind, kind),
                ],
                category: _kind,
                remoteKey: _kindsKey,
                remoteAutofocus: television && !categoryRowVisible,
                onExitUp: television && categoryRowVisible
                    ? () => _categoriesKey.currentState?.focusCurrent()
                    : null,
                onExitDown: television
                    ? () => _boardsKey.currentState?.focusCurrent()
                    : null,
                onCategory: _selectKind,
                onRetry: _initialize,
              ),
            if (boards.isNotEmpty)
              CatalogFilters(
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
                onExitUp: television && (categoryRowVisible || kindRowVisible)
                    ? () => (kindRowVisible
                                ? _kindsKey
                                : _categoriesKey)
                            .currentState
                            ?.focusCurrent()
                    : null,
                onExitDown: television
                    ? () => _listKey.currentState?.focusCurrent()
                    : null,
                onCategory: (id) => _selectBoardId(id),
                onRetry: () => _load(force: true),
              ),
            Padding(
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
            ),
            if (busy && rows.isNotEmpty)
              const LinearProgressIndicator(minHeight: 2),
            if (_error != null && rows.isNotEmpty)
              Padding(
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
              ),
            Expanded(
              child: busy && rows.isEmpty
                  ? const Center(child: CircularProgressIndicator())
                  : rows.isEmpty
                  ? StatusPanel(
                      title: _error == null ? '暂无榜单内容' : '榜单暂时无法加载',
                      message: _error ?? '当前榜单暂无可显示的内容。',
                      onRetry: _board == null
                          ? _initialize
                          : () => _load(force: true),
                    )
                  : television
                  ? RemoteList(
                      key: _listKey,
                      itemKeys: [
                        for (final row in rows) '${row.rank}-${row.drama.id}',
                      ],
                      itemExtent: 140,
                      spacing: 10,
                      controller: _scroll,
                      onExitUp: () => _boardsKey.currentState?.focusCurrent(),
                      itemBuilder: (_, index, node, onFocus) {
                        return _rankTile(
                          rows[index],
                          focusNode: node,
                          onFocus: onFocus,
                        );
                      },
                    )
                  : RefreshIndicator(
                      onRefresh: () {
                        HapticFeedback.mediumImpact();
                        return _load(force: true);
                      },
                      child: ListView.builder(
                        key: ValueKey('ranking-${_board!.id}'),
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
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
