import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'catalog_sort.dart';
import 'glass.dart';
import 'app_icons.dart';

/// TV 端入口：底部玻璃弹层（遥控焦点导航可靠，保留「应用」确认步骤）。
/// 手机端走 [showCatalogFilterMenu] 锚定浮卡，不再占半屏。
/// [supported] 为当前条目集上有效的排序项；null 表示不降级（全部可用）。
/// [areaOptions]/[yearOptions] 为当前条目集上动态聚合的筛选选项；
/// null 或空列表时对应筛选节整体隐藏（源不带该字段，如短剧类）。
/// [releaseOptions] 为有内容的剧集状态键集合（'' 恒含）；null 表示
/// 全部显示，非 null 时无命中的状态不渲染（选中后不会得到空列表）。
Future<CatalogView?> chooseCatalogView(
  BuildContext context,
  CatalogView current, {
  Set<CatalogSort>? supported,
  List<String>? areaOptions,
  List<String>? yearOptions,
  Set<String>? releaseOptions,
}) {
  // 选中态挂在函数级：bottom sheet 的 builder 在 viewInsets/主题变化时会
  // 整体重跑，变量写在 builder 内会被重置回打开时快照（同下浮卡）。
  var selected = current;
  return showModalBottomSheet<CatalogView>(
  context: context,
  backgroundColor: Colors.transparent,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(GlassTokens.radiusBar)),
  ),
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) {
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
                      // 置灰禁用 = 该排序对当前条目集无效（依赖字段全空且
                      // 源站不支持服务端排序），点了也与源站顺序等价。
                      onSelected: supported?.contains(sort) ?? true
                          ? (_) => update(
                              () => selected = selected.copyWith(sort: sort),
                            )
                          : null,
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
                    if (releaseOptions == null ||
                        releaseOptions.contains(entry.key))
                      ChoiceChip(
                        label: Text(entry.value),
                        selected: selected.release == entry.key,
                        onSelected: (_) => update(
                          () => selected = selected.copyWith(
                            release: entry.key,
                          ),
                        ),
                      ),
                ],
              ),
              if (areaOptions != null && areaOptions.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('地区'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final area in ['', ...areaOptions])
                      ChoiceChip(
                        label: Text(area.isEmpty ? '全部' : area),
                        selected: selected.area == area,
                        onSelected: (_) => update(
                          () => selected = selected.copyWith(area: area),
                        ),
                      ),
                  ],
                ),
              ],
              if (yearOptions != null && yearOptions.isNotEmpty) ...[
                const SizedBox(height: 24),
                const Text('年份'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final year in ['', ...yearOptions])
                      ChoiceChip(
                        label: Text(year.isEmpty ? '全部' : year),
                        selected: selected.year == year,
                        onSelected: (_) => update(
                          () => selected = selected.copyWith(year: year),
                        ),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 16),
              Text(
                '排序和筛选作用于已加载的剧集；源站顺序即站点的最新收录与推荐顺序，缺少排序资料的条目排在最后。置灰的排序项当前站源不支持。',
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
}

const _releaseOptions = <String, String>{
  '': '全部',
  'ongoing': '连载中',
  'finished': '已完结',
  'unknown': '状态未知',
};

/// 手机端：锚定 ≡ 岛的轻量筛选浮卡。
/// 与玻璃胶囊菜单同族——每枚选项一片独立玻璃胶囊，无整块面板底、
/// barrier 全透明，点选立即生效且浮层保持打开，点空白处关闭。
/// [releaseOptions] 为有内容的剧集状态键集合（'' 恒含）；null 表示
/// 全部显示，非 null 时无命中的状态不渲染。
Future<void> showCatalogFilterMenu({
  required BuildContext context,
  required GlobalKey anchorKey,
  required CatalogView current,
  required ValueChanged<CatalogView> onChanged,
  Set<CatalogSort>? supported,
  List<String>? areaOptions,
  List<String>? yearOptions,
  Set<String>? releaseOptions,
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

  // 选中态必须挂在函数级：pageBuilder 会在 DuanjuApp 随 store 通知重建
  // MaterialApp 时整体重跑，声明写在 pageBuilder 内会被重置回打开时快照，
  // 表现为点选后胶囊当场不变黑、关掉重开才「追认」新选中。
  var selected = current;

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
                                key: ValueKey('filter-sort-${sort.name}'),
                                context: dialogContext,
                                dark: dark,
                                label: sort.label,
                                checked: selected.sort == sort,
                                // 置灰禁用 = 该排序对当前条目集无效
                                //（依赖字段全空且源站不支持服务端排序）。
                                onTap: supported?.contains(sort) ?? true
                                    ? () {
                                        update(
                                          () => selected = selected.copyWith(
                                            sort: sort,
                                          ),
                                        );
                                        onChanged(selected);
                                      }
                                    : null,
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
                              if (releaseOptions == null ||
                                  releaseOptions.contains(entry.key))
                                _filterChip(
                                  key: ValueKey(
                                    'filter-release-'
                                    '${entry.key.isEmpty ? 'all' : entry.key}',
                                  ),
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
                        if (areaOptions != null && areaOptions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _sectionLabel(dialogContext, '地区'),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final area in ['', ...areaOptions])
                                _filterChip(
                                  key: ValueKey(
                                    'filter-area-'
                                    '${area.isEmpty ? 'all' : area}',
                                  ),
                                  context: dialogContext,
                                  dark: dark,
                                  label: area.isEmpty ? '全部' : area,
                                  checked: selected.area == area,
                                  onTap: () {
                                    update(
                                      () => selected = selected.copyWith(
                                        area: area,
                                      ),
                                    );
                                    onChanged(selected);
                                  },
                                ),
                            ],
                          ),
                        ],
                        if (yearOptions != null && yearOptions.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _sectionLabel(dialogContext, '年份'),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final year in ['', ...yearOptions])
                                _filterChip(
                                  key: ValueKey(
                                    'filter-year-'
                                    '${year.isEmpty ? 'all' : year}',
                                  ),
                                  context: dialogContext,
                                  dark: dark,
                                  label: year.isEmpty ? '全部' : year,
                                  checked: selected.year == year,
                                  onTap: () {
                                    update(
                                      () => selected = selected.copyWith(
                                        year: year,
                                      ),
                                    );
                                    onChanged(selected);
                                  },
                                ),
                            ],
                          ),
                        ],
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
  Key? key,
  required BuildContext context,
  required bool dark,
  required String label,
  required bool checked,
  required VoidCallback? onTap,
}) {
  // 与滑动栏分类胶囊同一实现（GlassChip）：选中黑瓷白字+对勾，
  // 不再走第二套「主色文字+主色对勾」视觉。
  final chip = GlassChip(
    key: key,
    label: label,
    selected: checked,
    onTap: onTap ?? () {},
    trailing: checked
        ? AppIcon(AppIcons.check, size: 16, color: GlassChipTokens.onSelected(dark))
        : null,
  );
  if (onTap != null) return chip;
  // 禁用态：屏蔽命中 + 降透明度（GlassChip.onTap 非空，外包一层处理）。
  return IgnorePointer(child: Opacity(opacity: 0.38, child: chip));
}
