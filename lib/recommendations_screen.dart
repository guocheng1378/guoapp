import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'catalog_filters.dart';
import 'app_layout.dart';
import 'core_bridge.dart';
import 'featured_catalog.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_launch_screen.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'app_icons.dart';

class RecommendationsScreen extends StatefulWidget {
  const RecommendationsScreen({
    super.key,
    required this.repository,
    required this.store,
    this.embedded = false,
    this.gridKey,
    this.onExitLeft,
  });
  final AppRepository repository;
  final LocalStore store;
  final bool embedded;
  final GlobalKey<RemoteGridState>? gridKey;
  final VoidCallback? onExitLeft;

  @override
  State<RecommendationsScreen> createState() => _RecommendationsScreenState();
}

class _RecommendationsScreenState extends State<RecommendationsScreen> {
  static const _genres = [
    CatalogCategory('short_play', '真人剧'),
    CatalogCategory('comic_series', '漫剧'),
    CatalogCategory('ai_series', 'AI 剧'),
  ];
  final _scroll = ScrollController();
  String _genre = 'short_play';
  List<Drama> _items = [];
  bool _loading = false;
  bool _more = false;
  bool _hasMore = true;
  bool _failedMore = false;
  String? _error;
  int _generation = 0;

  // —— 多源精选卡 ——
  // 数据逻辑见 featured_catalog.dart（按日期确定性轮换源 + 换一换 shift）。
  // 只覆盖桌面/手机 sliver 版；TV 端 RemoteGrid 无 header 位，暂不展示。
  static const double _featuredTileWidth = 150;
  List<Drama> _featured = [];
  String _featuredSource = '';
  int _featuredShift = 0;
  bool _featuredLoading = false;

  String get _featuredName =>
      SourceSite.byId(_featuredSource)?.name ?? _featuredSource;

  Future<void> _loadFeatured() async {
    // 推荐页走红果推荐：锚定当前站源，只在同类源之间轮换精选位；
    // 黄果类锚点不走精选位（pickFeaturedSource 返回空串，直接跳过）。
    // 首页轮播已改豆瓣选片（loadDoubanPicks），精选轮换只剩推荐页用。
    final anchor = SourceSite.byId(widget.store.source) ?? SourceSite.hongguo;
    final source = pickFeaturedSource(
      widget.store,
      anchor,
      shift: _featuredShift,
    );
    if (source.isEmpty) return;
    setState(() => _featuredLoading = true);
    try {
      final items = await loadFeatured(widget.repository, source);
      if (!mounted) return;
      setState(() {
        _featuredSource = source;
        _featured = items;
        _featuredLoading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _featuredSource = source;
        _featured = [];
        _featuredLoading = false;
      });
    }
  }

  void _rotateFeatured() {
    _featuredShift++;
    _loadFeatured();
  }

  Widget _buildFeatured() {
    if (!_featuredLoading && _featuredSource.isEmpty) {
      return const SizedBox.shrink();
    }
    final sourceName = _featuredName;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '多源精选 · $sourceName',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ),
              TextButton.icon(
                onPressed: _featuredLoading ? null : _rotateFeatured,
                icon: AppIcon(AppIcons.refresh),
                label: const Text('换一换'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_featuredLoading)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(18),
                child: CircularProgressIndicator(),
              ),
            )
          else if (_featured.isEmpty)
            Text(
              '精选内容暂时拉取失败，可点击「换一换」试试其他站源。',
              style: Theme.of(context).textTheme.bodySmall,
            )
          else
            SizedBox(
              height: DramaTile.extentFor(context, _featuredTileWidth),
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _featured.length,
                separatorBuilder: (_, _) => const SizedBox(width: 12),
                itemBuilder: (context, index) {
                  final drama = _featured[index];
                  return SizedBox(
                    width: _featuredTileWidth,
                    child: DramaTile(
                      key: ValueKey('featured-${drama.id}'),
                      drama: drama,
                      repository: widget.repository,
                      onTap: () => unawaited(
                        openPlaybackDirectly(
                          context,
                          drama: drama,
                          repository: widget.repository,
                          store: widget.store,
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    _load();
  }

  @override
  void dispose() {
    _generation++;
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    unawaited(widget.repository.cancelRecommendations());
    _scroll.dispose();
    super.dispose();
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null) return;
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
  }

  Future<void> _load({bool more = false, bool force = false}) async {
    if (more && (_loading || _more || !_hasMore)) return;
    final generation = ++_generation;
    final genre = _genre;
    setState(() {
      _loading = !more;
      _more = more;
      _error = null;
      _failedMore = more;
    });
    try {
      await widget.repository.cancelRecommendations();
      if (!mounted || generation != _generation) return;
      final page = await widget.repository.recommendations(
        genre,
        more: more,
        force: force,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = page.items;
        _hasMore = page.hasMore;
        _error = page.warning.isEmpty ? null : page.warning;
        _loading = _more = false;
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = _more = false;
        _error = error.toString();
      });
    }
  }

  void _select(String genre) {
    if (_genre == genre) return;
    setState(() {
      _genre = genre;
      _items = [];
      _hasMore = true;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final content = Column(
      children: [
        CatalogFilters(
          categories: _genres,
          category: _genre,
          onCategory: _select,
          onRetry: () => _load(force: true),
          onExitDown: () => widget.gridKey?.currentState?.focusCurrent(),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '公开推荐 · 已加载 ${_items.length} 部',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
        if (_loading && _items.isNotEmpty)
          const LinearProgressIndicator(minHeight: 2),
        if (_error != null && _items.isNotEmpty)
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
                  onPressed: _loading || _more
                      ? null
                      : () => _load(more: _failedMore, force: !_failedMore),
                  child: const Text('重试'),
                ),
              ],
            ),
          ),
        Expanded(
          child: !widget.store.allowsSource('hongguo')
              ? const StatusPanel(title: '当前用户未开放红果', message: '可在用户管理中调整站源权限。')
              : _loading && _items.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _items.isEmpty
              ? StatusPanel(
                  title: _error == null ? '暂无推荐' : '推荐暂时无法加载',
                  message: _error ?? '稍后刷新可获取新的推荐。',
                  onRetry: () => _load(force: true),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    if (AppLayout.isTelevision(context)) {
                      final columns = ((constraints.maxWidth - 36) / 150)
                          .floor()
                          .clamp(1, 8);
                      final tileWidth =
                          (constraints.maxWidth - 36 - (columns - 1) * 14) /
                          columns;
                      return RemoteGrid(
                        key: widget.gridKey,
                        itemKeys: _items.map((item) => item.id).toList(),
                        columns: columns,
                        itemExtent:
                            DramaTile.extentFor(context, tileWidth - 14) + 14,
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
                        onExitLeft: widget.onExitLeft,
                        footer: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                          child: Center(
                            child: _more
                                ? const CircularProgressIndicator()
                                : _hasMore
                                ? RemoteButton(
                                    label: '继续推荐',
                                    icon: AppIcon(AppIcons.autoAwesome),
                                    onPressed: () => _load(more: true),
                                  )
                                : RemoteButton(
                                    label: '刷新获取新推荐',
                                    icon: AppIcon(AppIcons.refresh),
                                    onPressed: () => _load(force: true),
                                  ),
                          ),
                        ),
                        itemBuilder: (_, index, node, onFocus) {
                          final drama = _items[index];
                          return DramaTile(
                            key: ValueKey(drama.id),
                            drama: drama,
                            repository: widget.repository,
                            focusNode: node,
                            onFocus: onFocus,
                            onTap: () => unawaited(
                              openPlaybackDirectly(
                                context,
                                drama: drama,
                                repository: widget.repository,
                                store: widget.store,
                              ),
                            ),
                          );
                        },
                      );
                    }
                    return RefreshIndicator(
                    onRefresh: () {
                      HapticFeedback.mediumImpact();
                      return _load(force: true);
                    },
                    // anywhere：与首页下拉手感一致（顶部边缘之外起手也计刷新）。
                    triggerMode: RefreshIndicatorTriggerMode.anywhere,
                    child: CustomScrollView(
                      controller: _scroll,
                      physics: const AlwaysScrollableScrollPhysics(),
                      slivers: [
                        SliverToBoxAdapter(child: _buildFeatured()),
                        SliverPadding(
                          padding: const EdgeInsets.all(16),
                          sliver: SliverGrid(
                            gridDelegate: dramaGridDelegate(
                              context,
                              constraints.maxWidth - 32,
                            ),
                            delegate: SliverChildBuilderDelegate((
                              context,
                              index,
                            ) {
                              final drama = _items[index];
                              return DramaTile(
                                key: ValueKey(drama.id),
                                drama: drama,
                                repository: widget.repository,
                                onTap: () => unawaited(
                                  openPlaybackDirectly(
                                    context,
                                    drama: drama,
                                    repository: widget.repository,
                                    store: widget.store,
                                  ),
                                ),
                              );
                            }, childCount: _items.length),
                          ),
                        ),
                        SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                            child: Center(
                              child: _more
                                  ? const CircularProgressIndicator()
                                  : _hasMore
                                  ? OutlinedButton.icon(
                                      onPressed: () => _load(more: true),
                                      icon: AppIcon(AppIcons.autoAwesome),
                                      label: const Text('继续推荐'),
                                    )
                                  : TextButton(
                                      onPressed: () => _load(force: true),
                                      child: const Text('本轮推荐已看完，刷新获取新推荐'),
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
      ],
    );
    if (widget.embedded) return content;
    return Scaffold(
      appBar: AppBar(
          title: const Text('红果推荐'),
          flexibleSpace: const TopFog(),
        ),
      body: SafeArea(top: false, child: content),
    );
  }
}
