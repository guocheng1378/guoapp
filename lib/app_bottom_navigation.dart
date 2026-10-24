import 'package:flutter/material.dart';

import 'glass.dart';

/// 悬浮玻璃胶囊底栏：整条是未选态白玻璃胶囊（分类条 pill 材质），
/// 内部每枚导航项等宽分布，选中态以选中态深/白玻璃小胶囊高亮
/// （双态语言与分类条一致）；
/// 大字号/窄屏下文字自动缩略，不产生溢出。
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.compact = false,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  /// 手机横屏紧凑档：底边距/项内边距/图标/字号整体降一档（49 → 37px）。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(10, 0, 10, compact ? 6 : 12),
        // 整条一枚双态玻璃胶囊（未选态白玻璃+σ18 磨砂+白描边），
        // 内部选中项再浮选中态小胶囊——与分类条同材质语言。
        child: GlassSurface(
          variant: GlassVariant.surface,
          radius: GlassTokens.radiusBar,
          tint: GlassTint.pill,
          child: Row(
            children: [
              for (final (index, destination) in destinations.indexed)
                Expanded(
                  child: _Pill(
                    navKey: ValueKey('bottom-nav-$index'),
                    destination: destination,
                    selected: index == selectedIndex,
                    colors: colors,
                    dark: dark,
                    compact: compact,
                    onTap: () => onDestinationSelected(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.navKey,
    required this.destination,
    required this.selected,
    required this.colors,
    required this.dark,
    required this.onTap,
    this.compact = false,
  });

  final Key navKey;
  final NavigationDestination destination;
  final bool selected;
  final ColorScheme colors;
  final bool dark;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        key: navKey,
        onTap: onTap,
        borderRadius: BorderRadius.circular(24),
        child: Semantics(
          container: true,
          button: true,
          selected: selected,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOutCubic,
            padding: EdgeInsets.symmetric(
              horizontal: 10,
              vertical: compact ? 7 : 14,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              // 与分类胶囊同一套双态材质：选中=深玻璃小胶囊（暗色反转
              // 白玻璃）+白描边；未选项透明无底（直接坐在胶囊底栏上）。
              color: selected
                  ? GlassChipTokens.pillSelected(dark)
                  : Colors.transparent,
              border: selected
                  ? Border.all(
                      color: GlassChipTokens.pillEdge(dark, selected: true),
                    )
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconTheme(
                  data: IconThemeData(
                    size: compact ? 18 : 21,
                    color: selected
                        ? GlassChipTokens.onSelected(dark)
                        : colors.onSurfaceVariant,
                  ),
                  child: selected
                      ? (destination.selectedIcon ?? destination.icon)
                      : destination.icon,
                ),
                SizedBox(width: compact ? 4 : 6),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: compact ? 11.5 : 12.5,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? GlassChipTokens.onSelected(dark)
                          : colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
