import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'catalog_filters.dart';
import 'core_bridge.dart';
import 'detail_screen.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'ranking_models.dart';
import 'rank_local_boards.dart';
import 'remote_widgets.dart';
import 'widgets.dart';

class RankingsScreen extends StatefulWidget {
  const RankingsScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.initialGroup,
  });
  final AppRepository repository;
  final LocalStore store;
  final String initialGroup;

  @override
  State<RankingsScreen> createState() => _RankingsScreenState();
}

class _RankingsScreenState extends State<RankingsScreen> {
  final _scroll = ScrollController();
  final _localBoardsKey = GlobalKey<RemoteRowState>();
  final _groupsKey = GlobalKey<RemoteRowState>();
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

  /// 跨源本地榜（实时热度 / 排期表）的当前选择，优先于 [_board]。
  LocalBoard? _localBoard;
  /// 拉取到的各站源目录页条目，本地榜的数据原料。
  List<Drama> _localCatalogs = [];
  bool _localLoading = false;
  /// 排期表展平后的行：`_ScheduleHeader` 或 `RankingItem`。
  List<Object> _localRows = [];
  String _localWarning = '';

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
      final boards = (await widget.repository.rankingBoards())
          .where((board) => widget.store.allowsSource(board.source))
          .toList();
      if (!mounted || generation != _generation) return;
      setState(() {
        _boards = boards;
        _board =
            boards
                .where((board) => board.groupId == widget.initialGroup)
                .firstOrNull ??
            boards.firstOrNull;
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

  /// 站源开关与 VIP 过滤，榜内与本地榜共用。
  bool _passes(Drama drama) =>
      widget.store.allowsSource(drama.source) &&
      !(drama.source == 'huangdou' && widget.store.hideVip && drama.vip);

  bool _isFollowing(Drama drama) => widget.store.isFavorite(drama.id);

  void _resetBoardState() {
    _items = [];
    _localRows = [];
    _updated = '';
    _page = 1;
    _hasMore = false;
  }

  void _selectBoardId(String id) {
    if (isLocalBoardId(id)) {
      if (_localBoard?.id == id) return;
      setState(() {
        _localBoard = localBoards.firstWhere((board) => board.id == id);
        _board = null;
        _error = null;
        _resetBoardState();
      });
      if (_scroll.hasClients) _scroll.jumpTo(0);
      _loadLocal();
      return;
    }
    final board = _boards.firstWhere((board) => board.id == id);
    if (_board?.id == board.id) return;
    setState(() {
      _board = board;
      _localBoard = null;
      _error = null;
      _resetBoardState();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  /// 本地榜不请求任何榜单接口：用各站源目录页已有的 heat/views/onlineDate 聚合。
  ///
  /// 原料只在首次或强制刷新时拉取，之后两个本地榜共用同一批目录。
  Future<void> _loadLocal({bool force = false}) async {
    final local = _localBoard;
    if (local == null) return;
    final generation = ++_generation;
    setState(() {
      _localLoading = true;
      _error = null;
    });
    try {
      if (_localCatalogs.isEmpty || force) {
        final sources = {for (final board in _boards) board.source}.toList();
        final pages = await Future.wait([
          for (final source in sources)
            widget.repository
                .catalog(source, force: force)
                .then((page) => page.items)
                .catchError((Object _) => const <Drama>[]),
        ]);
        if (!mounted || generation != _generation) return;
        final dramas = <Drama>[];
        for (final rows in pages) {
          dramas.addAll(rows);
        }
        _localCatalogs = dramas;
        _localWarning = _localCatalogs.isEmpty ? '各站源目录暂无数据。' : '';
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _localRows = local.kind == LocalBoardKind.schedule
            ? _scheduleRows()
            : buildHeatBoard(_visible(_localCatalogs));
        _localLoading = false;
        _error = _localWarning.isEmpty ? null : _localWarning;
      });
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = error.toString();
          _localLoading = false;
        });
      }
    }
  }

  List<Drama> _visible(Iterable<Drama> dramas) =>
      dramas.where(_passes).toList();

  /// 排期表展平为「表头 + 条目」的行序列，手机端与 TV 端共用同一份数据。
  List<Object> _scheduleRows() {
    final groups = buildScheduleGroups(
      _visible(_localCatalogs),
      isFollowing: _isFollowing,
    );
    return [
      for (final group in groups) ...[
        _ScheduleHeader(group.label, group.total),
        ...group.items,
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final groups = SourceGroup.fromSources(
      _boards.map((board) => SourceSite.byId(board.source)).toSet(),
    );
    final boards = _boards
        .where((board) => board.groupId == _board?.groupId)
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
    final localRows = _localRows
        .map(
          (row) => row is RankingItem
              ? RankingItem(
                  row.rank,
                  widget.repository.catalogUpdates.current(row.drama),
                  metric: row.metric,
                )
              : row,
        )
        .toList();
    final rows = _localBoard == null ? items : localRows;
    final busy = _localBoard == null ? _loading || _more : _localLoading;
    return Scaffold(
      appBar: AppBar(
          flexibleSpace: const TopFog(),
        title: const Text('榜单'),
        actions: [
          RefreshAction(
            loading: busy,
            tooltip: '更新榜单',
            onPressed: _localBoard != null
                ? () => _loadLocal(force: true)
                : _board == null
                ? _initialize
                : () => _load(force: true),
          ),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Column(
          children: [
            if (_boards.isNotEmpty)
              CatalogFilters(
                key: const ValueKey('ranking-local-boards'),
                categories: [
                  for (final board in localBoards)
                    CatalogCategory(board.id, board.name),
                ],
                category: _localBoard?.id ?? '',
                remoteKey: _localBoardsKey,
                remoteAutofocus: television,
                onExitDown: television
                    ? () => _groupsKey.currentState?.focusCurrent()
                    : null,
                onCategory: _selectBoardId,
                onRetry: _initialize,
              ),
            if (_localBoard == null && groups.length > 1)
              CatalogFilters(
                key: ValueKey('ranking-groups-${_board?.groupId}'),
                categories: [
                  for (final group in groups)
                    CatalogCategory(group.id, group.name),
                ],
                category: _board?.groupId ?? '',
                remoteKey: _groupsKey,
                remoteAutofocus: television && _boards.isEmpty,
                onExitUp: television && _boards.isNotEmpty
                    ? () => _localBoardsKey.currentState?.focusCurrent()
                    : null,
                onExitDown: television
                    ? () => _boardsKey.currentState?.focusCurrent()
                    : null,
                onCategory: (id) => _selectBoardId(
                  _boards.firstWhere((board) => board.groupId == id).id,
                ),
                onRetry: _initialize,
              ),
            if (_localBoard == null && boards.isNotEmpty)
              CatalogFilters(
                key: ValueKey('ranking-boards-${_board!.groupId}'),
                categories: [
                  for (final board in boards)
                    CatalogCategory(board.id, board.name),
                ],
                category: _board!.id,
                remoteKey: _boardsKey,
                remoteAutofocus: television && groups.length <= 1,
                onExitUp: television && groups.length > 1
                    ? () => _groupsKey.currentState?.focusCurrent()
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
                    _localBoard?.description ?? _board?.description ?? '',
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
                          : _localBoard != null
                          ? () => _loadLocal(force: true)
                          : () => _load(more: _failedMore, force: true),
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            Expanded(
              child: busy && rows.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const CircularProgressIndicator(),
                          if (_board?.source == 'hongguo') ...[
                            const SizedBox(height: 16),
                            const Text('正在获取榜单，数据未完整返回时会自动重试'),
                          ],
                        ],
                      ),
                    )
                  : rows.isEmpty
                  ? StatusPanel(
                      title: _error == null ? '暂无榜单内容' : '榜单暂时无法加载',
                      message:
                          _error ??
                          (_localBoard != null
                              ? '当前没有可聚合的站源目录数据。'
                              : '当前站源暂无可显示的榜单。'),
                      onRetry: _localBoard != null
                          ? () => _loadLocal(force: true)
                          : _board == null
                          ? _initialize
                          : () => _load(force: true),
                    )
                  : television
                  ? RemoteList(
                      key: _listKey,
                      itemKeys: [
                        for (final row in rows)
                          if (row is _ScheduleHeader)
                            'schedule-${row.label}'
                          else if (row is RankingItem)
                            '${row.rank}-${row.drama.id}'
                          else
                            'ranking-row',
                      ],
                      itemExtent: 140,
                      spacing: 10,
                      controller: _scroll,
                      onExitUp: () => _boardsKey.currentState?.focusCurrent(),
                      itemBuilder: (_, index, node, onFocus) {
                        final row = rows[index];
                        if (row is _ScheduleHeader) {
                          return _scheduleHeader(row, tall: true);
                        }
                        if (row is! RankingItem) {
                          return const SizedBox.shrink();
                        }
                        return _rankTile(
                          row,
                          focusNode: node,
                          onFocus: onFocus,
                        );
                      },
                    )
                  : RefreshIndicator(
                      onRefresh: () {
                        HapticFeedback.mediumImpact();
                        return _localBoard != null
                            ? _loadLocal(force: true)
                            : _load(force: true);
                      },
                      child: ListView.builder(
                        key: ValueKey(
                          _localBoard != null
                              ? 'ranking-${_localBoard!.id}'
                              : 'ranking-${_board!.id}',
                        ),
                        controller: _scroll,
                        physics: const AlwaysScrollableScrollPhysics(),
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                        itemCount:
                            rows.length + (_localBoard == null ? 1 : 0),
                        itemBuilder: (context, index) {
                          if (_localBoard == null && index == rows.length) {
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
                          final row = rows[index];
                          if (row is _ScheduleHeader) {
                            return _scheduleHeader(row);
                          }
                          if (row is! RankingItem) {
                            return const SizedBox.shrink();
                          }
                          return _rankTile(row);
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _scheduleHeader(_ScheduleHeader header, {bool tall = false}) {
    final theme = Theme.of(context);
    final total = '更新 ${header.total} 部';
    if (tall) {
      return Card(
        child: SizedBox(
          height: 140,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(header.label, style: theme.textTheme.titleMedium),
                const SizedBox(height: 6),
                Text(total, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Text(header.label, style: theme.textTheme.titleSmall),
          const SizedBox(width: 8),
          Text(total, style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  /// 分类标签 / 集数 / 更新进度 / 追更标记。
  ///
  /// 文案对齐云追条目：`[分类]`（`text_topic_tag_count`）、
  /// 「共 N 部」（`text_topic_count`）、「更新至 N 集」（`text_update_to_episode`）。
  Widget _rankMeta(RankingItem item) {
    final theme = Theme.of(context);
    final tags = categoryTagLabel(item.drama);
    final episodes = episodeCountLabel(item.drama);
    final update = updateLabel(item.drama);
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
    final metric = rankingMetricLabel(item);
    final update = updateLabel(item.drama);
    final following = _isFollowing(item.drama);
    void open() => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          drama: item.drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
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
          const Icon(Icons.chevron_right_rounded),
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

/// 排期表的分组表头（手机端为紧凑标题行，TV 端为等高卡片以便焦点遍历）。
class _ScheduleHeader {
  const _ScheduleHeader(this.label, this.total);

  final String label;
  final int total;
}
