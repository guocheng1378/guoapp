import 'package:flutter/material.dart';

import 'glass.dart';

/// 悬浮瓷面底栏：整条是一个微透白瓷胶囊（小米主题商店底栏同款），
/// 内部每枚导航项等宽分布，选中态以主色淡底小胶囊高亮；
/// 大字号/窄屏下文字自动缩略，不产生溢出。
class AppBottomNavigation extends StatelessWidget {
  const AppBottomNavigation({
    super.key,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
  });

  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
        // 整条一个瓷面胶囊（小米同款），内部选中项再浮主色小胶囊；
        // 不再每项各自瓷面——合体后雾面/内容透出一整条柔光。
        child: GlassSurface(
          variant: GlassVariant.surface,
          radius: GlassTokens.radiusBar,
          topHighlight: true,
          // 横向长条档：浅色与滑动栏胶囊同档（0.72），暗色 0.30 保可读。
          tint: GlassTint.bar,
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
  });

  final Key navKey;
  final NavigationDestination destination;
  final bool selected;
  final ColorScheme colors;
  final bool dark;
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
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              // 与滑动栏/排序面板同一套：选中=黑瓷小胶囊（暗色反转白瓷）。
              color: selected
                  ? GlassChipTokens.selected(dark)
                  : Colors.transparent,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconTheme(
                  data: IconThemeData(
                    size: 21,
                    color: selected
                        ? GlassChipTokens.onSelected(dark)
                        : colors.onSurfaceVariant,
                  ),
                  child: selected
                      ? (destination.selectedIcon ?? destination.icon)
                      : destination.icon,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    destination.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
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
