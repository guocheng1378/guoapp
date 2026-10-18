import 'dart:math';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'glass.dart';
import 'models.dart';
import 'remote_widgets.dart';

class CatalogFilters extends StatefulWidget {
  const CatalogFilters({
    super.key,
    required this.categories,
    required this.category,
    required this.onCategory,
    required this.onRetry,
    this.error,
    this.trailing,
    this.remoteKey,
    this.remoteAutofocus = false,
    this.onExitUp,
    this.onExitDown,
  });

  final List<CatalogCategory> categories;
  final String category;
  final String? error;
  final ValueChanged<String> onCategory;
  final VoidCallback onRetry;
  final Widget? trailing;
  final GlobalKey<RemoteRowState>? remoteKey;
  final bool remoteAutofocus;
  final VoidCallback? onExitUp;
  final VoidCallback? onExitDown;

  /// 分类条高度（单一来源）：条内公式 extra=4；首页吸顶 pinned header
  /// 传 extra=12，避免两处魔法数漂移。
  static double barHeight(BuildContext context, {double extra = 4}) {
    final scaled = MediaQuery.textScalerOf(context).scale(14);
    return max(52, scaled + 28) + extra;
  }

  @override
  State<CatalogFilters> createState() => _CatalogFiltersState();
}

class _CatalogFiltersState extends State<CatalogFilters> {
  final _anchors = <String, GlobalKey>{};

  /// anchor key 在 initState/didUpdateWidget 维护，不在 build 里
  /// putIfAbsent——build 期副作用会让失效分类的 key 一直留在表里
  /// （泄漏 + GlobalKey 复用风险）。
  void _syncAnchors() {
    final ids = widget.categories.map((entry) => entry.id).toSet();
    _anchors.removeWhere((id, _) => !ids.contains(id));
    for (final id in ids) {
      _anchors.putIfAbsent(id, GlobalKey.new);
    }
  }

  @override
  void initState() {
    super.initState();
    _syncAnchors();
  }

  int get _selectedIndex {
    final index = widget.categories.indexWhere(
      (entry) => entry.id == widget.category,
    );
    return index < 0 ? 0 : index;
  }

  @override
  void didUpdateWidget(covariant CatalogFilters oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncAnchors();
    if (oldWidget.category != widget.category) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final anchor = _anchors[widget.category]?.currentContext;
        if (mounted && anchor != null) {
          Scrollable.ensureVisible(
            anchor,
            alignment: .4,
            duration: const Duration(milliseconds: 180),
          );
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final television = AppLayout.isTelevision(context);
    final bar = Row(
      children: [
        Expanded(
          child: television
              ? RemoteRow(
                  key: widget.remoteKey,
                  itemKeys: [
                    for (final entry in widget.categories) entry.id,
                  ],
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  initialIndex: _selectedIndex,
                  autofocus: widget.remoteAutofocus,
                  onExitUp: widget.onExitUp,
                  onExitDown: widget.onExitDown,
                  itemBuilder: (_, index, node, onFocus) {
                    final entry = widget.categories[index];
                    return KeyedSubtree(
                      key: _anchors[entry.id],
                      child: RemoteButton(
                        key: ValueKey('category-${entry.id}'),
                        label: entry.name,
                        selected: entry.id == widget.category,
                        focusNode: node,
                        onFocus: onFocus,
                        onPressed: () => widget.onCategory(entry.id),
                      ),
                    );
                  },
                )
              : SingleChildScrollView(
                  key: const ValueKey('catalog-categories'),
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Row(
                    children: [
                      for (final entry in widget.categories)
                        Padding(
                          key: _anchors[entry.id],
                          padding: const EdgeInsets.only(right: 6),
                          child: GlassChip(
                            key: ValueKey('category-${entry.id}'),
                            label: entry.name,
                            selected: entry.id == widget.category,
                            onTap: () => widget.onCategory(entry.id),
                            // 胶囊视觉保持小米 ~32px，命中区撑到 48px。
                            hitTarget: 48,
                          ),
                        ),
                    ],
                  ),
                ),
        ),
        if (widget.error != null)
          IconButton(
            tooltip: widget.error,
            onPressed: widget.onRetry,
            icon: Icon(
              Icons.refresh_rounded,
              color: Theme.of(context).colorScheme.error,
            ),
          ),
        if (widget.trailing != null) widget.trailing!,
      ],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: SizedBox(
        height: television
            ? 60
            : CatalogFilters.barHeight(context),
        // 手机/桌面去掉椭圆玻璃底板：分类胶囊直接浮在页面背景上
        // （首页吸顶时由调用方提供渐隐雾面）；TV 保留玻璃栏，
        // 保证遥控焦点在电视大屏上的对比度。
        child: television
            ? GlassSurface(
                variant: GlassVariant.surface,
                radius: GlassTokens.radiusBar,
                elevated: false,
                topHighlight: true,
                tint: GlassTint.bar,
                child: bar,
              )
            : bar,
      ),
    );
  }
}


