import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'glass.dart';

/// TV 端入口：底部玻璃弹层（遥控焦点导航可靠，保留「应用」确认步骤）。
/// 手机端走 [showCatalogFilterMenu] 锚定浮卡，不再占半屏。
Future<CatalogView?> chooseCatalogView(
  BuildContext context,
  CatalogView current,
) => showModalBottomSheet<CatalogView>(
  context: context,
  backgroundColor: Colors.transparent,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(GlassTokens.radiusBar)),
  ),
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) {
    var selected = current;
    return GlassSurface(
      variant: GlassVariant.surface,
      radius: GlassTokens.radiusBar,
      topHighlight: true,
      // 底部大面板横跨全宽，默认 surface 档（浅色 0.34）太透，
      // 背后剧卡海报的浓色会模糊成一条脏带衬在标题上方；
      // 底部 sheet 比「悬浮条」更实一档，透出感弱、文字对比稳。
      tint: GlassTint.sheet,
      child: StatefulBuilder(
        builder: (context, update) => SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            20,
            0,
            20,
            20 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 自绘拖拽提示条，替代框架句柄以贴合玻璃表面。
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 16),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.onSurfaceVariant.withValues(alpha: .35),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Text('排序与筛选', style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 16),
              Text('排序', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final sort in CatalogSort.values)
                    ChoiceChip(
                      autofocus:
                          AppLayout.isTelevision(context) &&
                          sort == CatalogSort.values.first,
                      label: Text(sort.label),
                      selected: selected.sort == sort,
                      onSelected: (_) => update(
                        () => selected = selected.copyWith(sort: sort),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 24),
              const Text('剧集状态'),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final entry in _releaseOptions.entries)
                    ChoiceChip(
                      label: Text(entry.value),
                      selected: selected.release == entry.key,
                      onSelected: (_) => update(
                        () => selected = selected.copyWith(release: entry.key),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                '排序和筛选作用于已加载的剧集；源站顺序即站点的最新收录与推荐顺序，缺少排序资料的条目排在最后。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context, selected),
                  child: const Text('应用'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  },
);

const _releaseOptions = <String, String>{
  '': '全部',
  'ongoing': '连载中',
  'finished': '已完结',
  'unknown': '状态未知',
};

/// 手机端：锚定 ≡ 岛的轻量筛选浮卡。
/// 与玻璃胶囊菜单同族——每枚选项一片独立玻璃胶囊，无整块面板底、
/// barrier 全透明，点选立即生效且浮层保持打开，点空白处关闭。
Future<void> showCatalogFilterMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required CatalogView current,
  required ValueChanged<CatalogView> onChanged,
}) async {
  final anchorContext = anchorKey.currentContext;
  final overlayBox =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (anchorContext == null || overlayBox is! RenderBox) return;
  final anchorBox = anchorContext.findRenderObject();
  if (anchorBox is! RenderBox) return;
  final topLeft = anchorBox.localToGlobal(Offset.zero, ancestor: overlayBox);
  final anchorSize = anchorBox.size;
  final screenSize = overlayBox.size;

  final dark = Theme.of(context).brightness == Brightness.dark;
  // 卡宽按「两枚四字胶囊并排 + 余量」取定，两节 chips 对齐流动。
  const cardWidth = 236.0;
  var left = topLeft.dx + anchorSize.width - cardWidth;
  left = left.clamp(12.0, screenSize.width - cardWidth - 12);
  final top = (topLeft.dy + anchorSize.height + 8).clamp(
    0.0,
    screenSize.height - 64,
  );

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '排序与筛选',
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 170),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          alignment: Alignment.topRight,
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      var selected = current;
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: screenSize.height - top - 24,
              ),
              child: StatefulBuilder(
                builder: (context, update) => SingleChildScrollView(
                  child: SizedBox(
                    width: cardWidth,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _sectionLabel(dialogContext, '排序'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final sort in CatalogSort.values)
                              _filterChip(
                                context: dialogContext,
                                dark: dark,
                                label: sort.label,
                                checked: selected.sort == sort,
                                onTap: () {
                                  update(
                                    () => selected = selected.copyWith(
                                      sort: sort,
                                    ),
                                  );
                                  onChanged(selected);
                                },
                              ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        _sectionLabel(dialogContext, '剧集状态'),
                        const SizedBox(height: 6),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final entry in _releaseOptions.entries)
                              _filterChip(
                                context: dialogContext,
                                dark: dark,
                                label: entry.value,
                                checked: selected.release == entry.key,
                                onTap: () {
                                  update(
                                    () => selected = selected.copyWith(
                                      release: entry.key,
                                    ),
                                  );
                                  onChanged(selected);
                                },
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

Widget _sectionLabel(BuildContext context, String text) => Padding(
  padding: const EdgeInsets.only(left: 4),
  child: Text(
    text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(
      color: Theme.of(context).colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w600,
    ),
  ),
);

Widget _filterChip({
  required BuildContext context,
  required bool dark,
  required String label,
  required bool checked,
  required VoidCallback onTap,
}) {
  // 与滑动栏分类胶囊同一实现（GlassChip）：选中黑瓷白字+对勾，
  // 不再走第二套「主色文字+主色对勾」视觉。
  return GlassChip(
    label: label,
    selected: checked,
    onTap: onTap,
    trailing: checked
        ? Icon(
            Icons.check_rounded,
            size: 16,
            color: GlassChipTokens.onSelected(dark),
          )
        : null,
  );
}
