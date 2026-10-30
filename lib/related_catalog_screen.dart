import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'app_scaffold.dart';
import 'detail_screen.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';

/// 站点目录接口的 kind 要的是 content_kind 原文（short_drama/series/...），
/// 而 Drama.category 已经是中文标签（Go 侧 dongpiandiKindLabel 翻过的），
/// 这里反查回去；拿不到 id 的站源返回空串，调用方改用关键词搜索。
String kindIdForCategory(String source, String category) {
  if (source != 'dongpiandi') return '';
  return const <String, String>{
    '短剧': 'short_drama',
    '电视剧': 'series',
    '电影': 'movie',
    '动画': 'anime',
    '综艺': 'variety',
  }[category.trim()] ??
      '';
}

/// 打开「某部剧的分类/标签」相关结果页。
///
/// 详情页（detail_screen）与播放器简介 tab（player_screen）共用同一套跳转。
Future<void> openRelatedCatalog(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required Drama drama,
  required String label,
}) async {
  final kind = kindIdForCategory(drama.source, label);
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RelatedCatalogScreen(
        repository: repository,
        store: store,
        source: drama.source,
        label: label,
        sourceName: SourceSite.byId(drama.source)?.name ?? '',
        query: kind.isEmpty ? label : '',
        category: kind,
      ),
    ),
  );
}

/// 打开「某部剧所属站源的全部作品」：不带 query、不带 category。
Future<void> openSourceCatalog(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required Drama drama,
  required String sourceName,
}) async {
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => RelatedCatalogScreen(
        repository: repository,
        store: store,
        source: drama.source,
        label: '全部',
        sourceName: sourceName,
      ),
    ),
  );
}

/// 可点的元信息文字：视觉上仍是元信息，但着色 + 水波纹提示可点。
class MetaLink extends StatelessWidget {
  const MetaLink({
    super.key,
    required this.label,
    required this.tooltip,
    required this.onTap,
  });
  final String label;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(4),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
            child: Text(
              label,
              style: TextStyle(
                color: colors.primary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 简介页二次导航的落地页：按「站源 + 关键词」或「站源 + 分类」拉取结果网格，
/// 点条目进它的简介页。
///
/// 为什么要它：简介页的站源名/分类/标签此前全是纯 Text，看着像能点其实点不动
/// （2026-10-25 用户反馈「简介页的东西都不能点击跳转」）。App 里没有可复用的
/// 「搜索结果页」（HomeScreen 的 CatalogBrowser 与首页状态强耦合），所以这里做
/// 一个只读结果页，数据来源沿用 repository.catalog。
class RelatedCatalogScreen extends StatefulWidget {
  const RelatedCatalogScreen({
    super.key,
    required this.repository,
    required this.store,
    required this.source,
    required this.label,
    this.sourceName = '',
    this.query = '',
    this.category = '',
  });

  final AppRepository repository;
  final LocalStore store;
  final String source;
  final String label;
  final String sourceName;
  final String query;
  final String category;

  @override
  State<RelatedCatalogScreen> createState() => _RelatedCatalogScreenState();
}

class _RelatedCatalogScreenState extends State<RelatedCatalogScreen> {
  final _scroll = ScrollController();
  final _items = <Drama>[];
  final _seen = <String>{};
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _page = 0;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    _load(reset: true);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    if (position.pixels < position.maxScrollExtent - 600) return;
    if (_hasMore && !_loading && !_loadingMore) _load();
  }

  Future<void> _load({bool reset = false}) async {
    final request = ++_generation;
    setState(() {
      if (reset) {
        _loading = true;
        _page = 0;
        _items.clear();
        _seen.clear();
        _hasMore = true;
      }
      _error = null;
      _loadingMore = !reset;
    });
    final next = _page + 1;
    try {
      final page = await widget.repository.catalog(
        widget.source,
        page: next,
        query: widget.query,
        category: widget.category,
      );
      if (!mounted || request != _generation) return;
      setState(() {
        _page = page.page > 0 ? page.page : next;
        _hasMore = page.hasMore;
        for (final drama in page.items) {
          if (drama.source != widget.source || drama.id.isEmpty) continue;
          if (_seen.add(drama.id)) _items.add(drama);
        }
        _loading = false;
        _loadingMore = false;
        if (_items.isEmpty && page.warning.isNotEmpty) _error = page.warning;
      });
    } catch (error) {
      if (!mounted || request != _generation) return;
      setState(() {
        _error = '$error';
        _loading = false;
        _loadingMore = false;
      });
    }
  }

  Future<void> _open(Drama drama) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = widget.sourceName.isEmpty
        ? widget.label
        : '${widget.sourceName} · ${widget.label}';
    return AppScaffold(
      titleWidget: Text(subtitle),
      actions: [
        IconButton(
          tooltip: '重新加载',
          icon: const Icon(Icons.refresh),
          onPressed: () => _load(reset: true),
        ),
      ],
      body: _buildBody(colors),
    );
  }

  Widget _buildBody(ColorScheme colors) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      final failure = _error;
      final message = (failure != null && failure.isNotEmpty)
          ? failure
          : '暂时没有找到和「${widget.label}」相关的内容';
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, size: 48, color: colors.onSurfaceVariant),
              const SizedBox(height: 12),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => _load(reset: true),
      child: GridView.builder(
        controller: _scroll,
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 140,
          // 格子高度 = 宽/0.52：封面（宽/0.74）+ 间距 + 两行文字，留一点余量，
          // 否则窄 column 下 RenderFlex 会溢出不足 1px 也算错误。
          childAspectRatio: 0.52,
          crossAxisSpacing: 12,
          mainAxisSpacing: 16,
        ),
        itemCount: _items.length + (_hasMore ? 1 : 0),
        itemBuilder: (context, index) {
          if (index >= _items.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Center(
                child: _error != null
                    ? IconButton(
                        tooltip: '重试',
                        icon: const Icon(Icons.refresh),
                        onPressed: () => _load(),
                      )
                    : const CircularProgressIndicator(),
              ),
            );
          }
          final drama = _items[index];
          return InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => _open(drama),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 封面内部是 Stack，必须有界高度：网格给的是高度无限的外框。
                AspectRatio(
                  aspectRatio: 0.74,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: DramaCover(
                      drama: drama,
                      repository: widget.repository,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  drama.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (drama.episodeLabel.isNotEmpty)
                  Text(
                    drama.episodeLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}
