import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'core_bridge.dart';
import 'drama_actions.dart';
import 'follow_state.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'app_icons.dart';

class SavedLibrary extends StatefulWidget {
  const SavedLibrary({
    super.key,
    required this.repository,
    required this.store,
    required this.history,
    required this.onOpen,
    required this.onContinue,
    this.onDownload,
    this.onFindSource,
    this.remoteAutofocus = false,
    this.onExitLeft,
    this.onExitUp,
    this.bottomInset = 0,
    this.topInset = 0,
  });

  final AppRepository repository;
  final LocalStore store;
  final bool history;
  final ValueChanged<Drama> onOpen;
  final ValueChanged<Drama> onContinue;
  final ValueChanged<Drama>? onDownload;

  /// 追剧/最近卡 ⋯ 菜单「换个源找」：回发现页用剧名触发全源搜索；
  /// 单源变体不传该回调，菜单项自然消失。
  final ValueChanged<String>? onFindSource;
  final bool remoteAutofocus;
  final VoidCallback? onExitLeft;
  final VoidCallback? onExitUp;

  /// 悬浮玻璃底栏出现时的内容底部避让高度。
  final double bottomInset;

  /// 悬浮玻璃顶栏的避让高度（手机端 > 0）。
  final double topInset;

  @override
  State<SavedLibrary> createState() => _SavedLibraryState();
}

class _SavedLibraryState extends State<SavedLibrary> {
  final _search = TextEditingController();
  String _filter = '';

  @override
  void initState() {
    super.initState();
    _healEpisodeCounts();
    // 打开追剧/最近即预取条目详情（≤12 部）：配合 30 分钟详情缓存，
    // 用户再点开任何一部都是零网络等待。基类 no-op，测试天然安全。
    widget.repository.prefetchDetails([
      ...widget.store.favorites,
      for (final entry in widget.store.history) entry.drama,
    ].take(12));
  }

  /// 存量自愈：早期版本把部分站源的「总条目/播放量」误当集数存进了追剧
  /// 快照（卡片显示「共数万集」）。对可疑条目（episodes > 500）后台拉一次
  /// 详情，用真实分集数覆盖；失败静默，不影响列表展示。
  Future<void> _healEpisodeCounts() async {
    final suspects = {
      for (final drama in widget.store.favorites) drama.id: drama,
      for (final entry in widget.store.history) entry.drama.id: entry.drama,
    }.values.where((drama) => drama.episodes > 500).toList();
    for (final drama in suspects) {
      if (!mounted) return;
      try {
        final detail = await widget.repository.detail(drama);
        if (!mounted) return;
        if (detail.drama.episodes > 0) {
          await widget.store.refreshDrama(detail.drama);
        }
      } catch (_) {
        // 源不可用/受限等：静默跳过，用户打开详情时 merge 仍会修正。
      }
    }
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _clearHistory() async {
    final epoch = widget.store.profileEpoch;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => GlassDialogShell(
        child: AlertDialog(
          title: const Text('清空观看记录？'),
          content: const Text('这会删除当前用户的观看进度，追剧状态和手动已看标记会保留。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('清空'),
            ),
          ],
        ),
      ),
    );
    if (accepted == true && mounted && epoch == widget.store.profileEpoch) {
      await saveUserChange(context, widget.store.clearHistory);
    }
  }

  void _actions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    history: widget.history,
    onContinue: () => widget.onContinue(drama),
    onDownload: widget.onDownload == null
        ? null
        : () => widget.onDownload!(drama),
    onFindSource: widget.onFindSource == null
        ? null
        : () => widget.onFindSource!(drama.title),
  );

  Widget _tile(Drama drama, {FocusNode? focusNode, VoidCallback? onFocus}) {
    final watched = widget.store.watched(drama.id);
    final state = widget.store.following(drama.id);
    final badge = state == null
        ? null
        : '${state.label}${state.hasUpdates ? ' · ${state.updateLabel}' : ''}';
    return DramaTile(
      key: ValueKey('saved-${drama.id}'),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => widget.onOpen(drama),
      onMore: () => _actions(drama),
      actions: DramaActionButton(
        drama: drama,
        store: widget.store,
        history: widget.history,
        onContinue: () => widget.onContinue(drama),
        onDownload: widget.onDownload == null
            ? null
            : () => widget.onDownload!(drama),
        onFindSource: widget.onFindSource == null
            ? null
            : () => widget.onFindSource!(drama.title),
      ),
      badge: badge,
      subtitle: watched == null
          ? (SourceSite.byId(drama.source)?.name ?? '未知源')
          : '第 ${watched.episode} 集 · ${formatPosition(watched.position)}',
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final history = widget.store.history;
      final all = widget.history
          ? history.map((entry) => entry.drama).toList()
          : widget.store.favorites;
      final items = all.where((drama) {
        if (!matchesDramaQuery(drama, _search.text)) return false;
        final state = widget.store.following(drama.id);
        return widget.history ||
            _filter.isEmpty ||
            (_filter == 'updates'
                ? state?.hasUpdates == true
                : state?.status.name == _filter);
      }).toList();
      final ids = items.map((drama) => drama.id).toSet();
      final resume = history
          .where(
            (entry) =>
                ids.contains(entry.drama.id) &&
                (!entry.finished ||
                    entry.drama.episodes <= 0 ||
                    entry.episode < entry.drama.episodes),
          )
          .firstOrNull;
      final header = [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 12, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '${widget.history ? '最近观看' : '我的追剧'} · ${all.length}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              if (widget.history && all.isNotEmpty)
                IconButton(
                  tooltip: '清空观看记录',
                  onPressed: _clearHistory,
                  icon: AppIcon(AppIcons.delete),
                ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: RemoteTextInput(
            child: TextField(
              key: ValueKey(
                widget.history ? 'history-search' : 'favorites-search',
              ),
              controller: _search,
              onChanged: (_) => setState(() {}),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: widget.history ? '搜索观看记录' : '搜索追剧',
                prefixIcon: AppIcon(AppIcons.search),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清空搜索',
                        onPressed: () => setState(_search.clear),
                        icon: AppIcon(AppIcons.close),
                      ),
              ),
            ),
          ),
        ),
        if (!widget.history)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                for (final filter in [
                  ('', '全部'),
                  for (final status in FollowStatus.values)
                    (status.name, status.label),
                  ('updates', '有更新'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      key: ValueKey('follow-filter-${filter.$1}'),
                      label: Text(filter.$2),
                      selected: _filter == filter.$1,
                      onSelected: (_) => setState(() => _filter = filter.$1),
                    ),
                  ),
              ],
            ),
          ),
        if (resume != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Card(
              margin: EdgeInsets.zero,
              child: ListTile(
                key: const ValueKey('continue-watching'),
                leading: AppIcon(AppIcons.playCircle),
                title: Text(
                  '继续观看 · ${resume.drama.title}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '第 ${resume.episode} 集 · ${formatPosition(resume.position)}',
                ),
                onTap: () => widget.onContinue(resume.drama),
              ),
            ),
          ),
      ];
      final empty = StatusPanel(
        title: all.isEmpty
            ? widget.history
                  ? '还没有观看记录'
                  : '还没有追剧'
            : '没有匹配的记录',
        message: all.isEmpty ? '去发现页，挑一部喜欢的短剧。' : '可以更换搜索词或筛选条件。',
        icon: widget.history
            ? AppIcon(AppIcons.history)
            : AppIcon(AppIcons.bookmark),
      );
      return LayoutBuilder(
        builder: (context, constraints) {
          if (AppLayout.isTelevision(context)) {
            final columns = ((constraints.maxWidth - 36) / 150).floor().clamp(
              1,
              8,
            );
            final tileWidth =
                (constraints.maxWidth - 36 - (columns - 1) * 14) / columns;
            return Column(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .5,
                  ),
                  child: SingleChildScrollView(child: Column(children: header)),
                ),
                Expanded(
                  child: items.isEmpty
                      ? empty
                      : RemoteGrid(
                          key: ValueKey(
                            'saved-tv-${widget.history}-$_filter-${_search.text}',
                          ),
                          itemKeys: items.map((item) => item.id).toList(),
                          columns: columns,
                          itemExtent:
                              DramaTile.extentFor(context, tileWidth - 14) + 14,
                          autofocus: widget.remoteAutofocus,
                          onExitLeft: widget.onExitLeft,
                          onExitUp: widget.onExitUp,
                          itemBuilder: (_, index, node, onFocus) => _tile(
                            items[index],
                            focusNode: node,
                            onFocus: onFocus,
                          ),
                        ),
                ),
              ],
            );
          }
          final padding = constraints.maxWidth < 600 ? 16.0 : 24.0;
          return CustomScrollView(
            key: PageStorageKey(
              'saved-${widget.history}-$_filter-${_search.text}',
            ),
            slivers: [
              SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.only(top: widget.topInset),
                  child: Column(children: header),
                ),
              ),
              if (items.isEmpty)
                SliverFillRemaining(hasScrollBody: false, child: empty)
              else
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    padding,
                    0,
                    padding,
                    20 + widget.bottomInset,
                  ),
                  sliver: SliverGrid(
                    gridDelegate: dramaGridDelegate(
                      context,
                      constraints.maxWidth - 2 * padding,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (_, index) => _tile(items[index]),
                      childCount: items.length,
                    ),
                  ),
                ),
            ],
          );
        },
      );
    },
  );
}
