import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'follow_state.dart';
import 'glass.dart';
import 'glass_menu.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';
import 'app_icons.dart';

Future<void> showDramaActions(
  BuildContext context, {
  required Drama drama,
  required LocalStore store,
  VoidCallback? onContinue,
  VoidCallback? onDownload,
  VoidCallback? onSelect,
  VoidCallback? onFindSource,
  bool history = false,
  GlobalKey? anchorKey,
}) async {
  final epoch = store.profileEpoch;
  final following = store.following(drama.id);
  final choices = <(String, String, Widget)>[
    if (onContinue != null && store.watched(drama.id) != null)
      ('continue', '继续观看', AppIcon(AppIcons.play, size: 22)),
    ('favorite', following == null ? '加入追剧' : '取消追剧', AppIcon(AppIcons.bookmark, size: 22)),
    for (final status in FollowStatus.values)
      (
        'status:${status.name}',
        '标记${status.label}',
        switch (status) {
          FollowStatus.planned => AppIcon(AppIcons.bookmarkAdd, size: 22),
          FollowStatus.watching => AppIcon(AppIcons.playCircle, size: 22),
          FollowStatus.watched => AppIcon(AppIcons.checkCircle, size: 22),
        },
      ),
    if (following != null && following.hasUpdates)
      ('read', '标记 ${following.updateLabel}已读', AppIcon(AppIcons.emailRead, size: 22)),
    if (onFindSource != null)
      ('findSource', '换个源找', AppIcon(AppIcons.search, size: 22)),
    if (onDownload != null && store.canDownload)
      ('download', '下载选集', AppIcon(AppIcons.download, size: 22)),
    if (onSelect != null && store.canDownload)
      ('select', '多选下载', AppIcon(AppIcons.checklist, size: 22)),
    if (history && store.watched(drama.id) != null)
      ('removeHistory', '删除这条观看记录', AppIcon(AppIcons.historyToggle, size: 22)),
  ];
  final String? choice;
  final anchorContext = anchorKey?.currentContext;
  if (anchorContext != null && !AppLayout.isTelevision(context)) {
    // 手机端：锚定在剧卡右上角按钮正下方，一枚枚独立玻璃胶囊逐条弹出，
    // 替代整块玻璃弹窗（太突兀）。
    choice = await showGlassMenu<String>(
      context: context,
      anchorKey: anchorKey,
      entries: [
        for (final (id, label, _) in choices)
          GlassMenuEntry(
            id,
            label,
            checked: id == 'status:${following?.status.name}',
          ),
      ],
    );
  } else {
    // TV/无锚点（长按、右键、遥控菜单键）：保留玻璃弹窗，焦点导航可靠。
    choice = await showDialog<String>(
      context: context,
      builder: (context) => GlassDialogShell(
        child: SimpleDialog(
          title: Text(drama.title, maxLines: 2, overflow: TextOverflow.ellipsis),
          children: [
            for (final entry in choices.indexed)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, entry.$2.$1),
                child: Row(
                  children: [
                    entry.$2.$3,
                    const SizedBox(width: 14),
                    Expanded(child: Text(entry.$2.$2)),
                    if (entry.$2.$1 == 'status:${following?.status.name}')
                      AppIcon(AppIcons.check, size: 20),
                  ],
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 10, 24, 8),
              child: Text(
                '手动标记已看会保留真实播放进度。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
  if (choice == null ||
      !context.mounted ||
      epoch != store.profileEpoch ||
      !store.allowsSource(drama.source)) {
    return;
  }
  if (choice.startsWith('status:')) {
    final status = FollowStatus.values.firstWhere(
      (value) => choice == 'status:${value.name}',
    );
    await saveUserChange(context, () => store.setFollowStatus(drama, status));
    return;
  }
  switch (choice) {
    case 'continue':
      onContinue?.call();
    case 'favorite':
      await saveUserChange(context, () => store.toggleFavorite(drama));
    case 'read':
      await saveUserChange(context, () => store.markUpdatesRead(drama.id));
    case 'download':
      if (store.canDownload) onDownload?.call();
    case 'select':
      if (store.canDownload) onSelect?.call();
    case 'findSource':
      onFindSource?.call();
    case 'removeHistory':
      await saveUserChange(context, () => store.removeHistory(drama.id));
  }
}

/// 剧卡右上角"更多"按钮：自带锚点，按下后在按钮正下方弹玻璃胶囊菜单
/// （手机端）；TV 与长按/右键路径仍走 [showDramaActions] 的玻璃弹窗。
class DramaActionButton extends StatefulWidget {
  const DramaActionButton({
    super.key,
    required this.drama,
    required this.store,
    this.onContinue,
    this.onDownload,
    this.onSelect,
    this.onFindSource,
    this.history = false,
  });
  final Drama drama;
  final LocalStore store;
  final VoidCallback? onContinue;
  final VoidCallback? onDownload;
  final VoidCallback? onSelect;
  final VoidCallback? onFindSource;
  final bool history;

  @override
  State<DramaActionButton> createState() => _DramaActionButtonState();
}

class _DramaActionButtonState extends State<DramaActionButton> {
  final GlobalKey _anchorKey = GlobalKey(debugLabel: 'drama-actions-anchor');

  void _open() => showDramaActions(
    context,
    drama: widget.drama,
    store: widget.store,
    onContinue: widget.onContinue,
    onDownload: widget.onDownload,
    onSelect: widget.onSelect,
    onFindSource: widget.onFindSource,
    history: widget.history,
    anchorKey: _anchorKey,
  );

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: _anchorKey,
    child: IconButton.filledTonal(
      key: ValueKey('drama-actions-${widget.drama.id}'),
      tooltip: '${widget.drama.title} · 更多操作',
      onPressed: _open,
      icon: AppIcon(AppIcons.moreHoriz, size: 20),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: .64),
        foregroundColor: Colors.white,
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.all(8),
        visualDensity: VisualDensity.compact,
      ),
    ),
  );
}
