// 玻璃质感弹出菜单：替代 PopupMenuButton 的 Material 实底菜单。
// showGeneralDialog + GlassSurface 定位面板，模糊层真正透出背后内容；
// 手机端使用，TV 端保留实底 PopupMenuButton 保证焦点导航可靠。

import 'package:flutter/material.dart';

import 'glass.dart';
import 'app_icons.dart';
import 'soft_glass.dart';

class GlassMenuEntry<T> {
  const GlassMenuEntry(
    this.value,
    this.label, {
    this.checked = false,
    this.enabled = true,
    this.header = false,
  });
  final T value;
  final String label;
  final bool checked;
  final bool enabled;
  /// 分组标题项：不可点，仅用作分类区间说明（如「短剧类」）。
  final bool header;
}

/// 菜单条目文字样式：测宽与绘制共用同一份，保证胶囊宽度贴合文字。
const _menuLabelStyle = TextStyle(fontSize: 15, fontWeight: FontWeight.w600);

/// 在 [anchorKey]/[anchor] 所在控件下方弹出玻璃菜单；空间不足时自动贴边。
Future<T?> showGlassMenu<T>({
  required BuildContext context,
  GlobalKey? anchorKey,
  BuildContext? anchor,
  required List<GlassMenuEntry<T>> entries,
}) {
  if (entries.isEmpty) return Future<T?>.value();
  final overlayBox =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (overlayBox is! RenderBox) return Future<T?>.value();
  final screenSize = overlayBox.size;
  final anchorBox = (anchorKey?.currentContext ?? anchor)?.findRenderObject();
  final RenderBox? anchorRender =
      anchorBox is RenderBox && anchorBox.hasSize ? anchorBox : null;
  // 锚点缺失或未布局（调用方漏传、或锚控件未挂载——如电视模式 ⋮ 是
  // PopupMenuButton 时 _moreMenuKey 不在树上）：不再静默返回，那会让
  // 「点了菜单项什么都没发生」变成死局；退化为居中偏上展示，barrier
  // 仍可点关闭，与正常路径同一套交互。
  final topLeft =
      anchorRender?.localToGlobal(Offset.zero, ancestor: overlayBox) ??
      Offset((screenSize.width - 220) / 2, screenSize.height * 0.3);
  final anchorSize = anchorRender?.size ?? Size.zero;

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '菜单',
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
          alignment: Alignment.topLeft,
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      // 胶囊宽度随最长条目的文字自适应（含字体缩放），不再硬性规定；
      // 只保留最小可点宽度，超长文字由省略号兜底。
      final scaler = MediaQuery.textScalerOf(dialogContext);
      final textDirection = Directionality.of(dialogContext);
      var labelWidth = 0.0;
      for (final entry in entries) {
        final painter = TextPainter(
          text: TextSpan(text: entry.label, style: _menuLabelStyle),
          textDirection: textDirection,
          textScaler: scaler,
        )..layout();
        if (painter.width > labelWidth) labelWidth = painter.width;
        painter.dispose();
      }
      // 任一条目带对勾时，右侧预留对勾图标位。
      final checkSpace = entries.any((entry) => entry.checked) ? 26.0 : 0.0;
      // +32 = 条目左右内边距；另留 10px 余量：宽度与文字宽正好相等时，
      // 像素取整会让文字溢出触发 ellipsis（真机「设置与备份」被截成
      // 「设置与 …」）。余量后文字完整显示。
      final menuWidth = (labelWidth + 42 + checkSpace).clamp(96.0, 280.0);
      var left = topLeft.dx;
      if (left + menuWidth > screenSize.width - 12) {
        left = (topLeft.dx + anchorSize.width - menuWidth).clamp(
          12.0,
          screenSize.width - menuWidth - 12,
        );
      }
      final top = (topLeft.dy + anchorSize.height + 6).clamp(
        0.0,
        screenSize.height - 64,
      );
      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: menuWidth,
                maxHeight: screenSize.height - top - 24,
              ),
              // 每个菜单项一枚独立玻璃胶囊，项间留缝露穿透内容，
              // 无整块面板底，barrier 本身全透明。
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (index, entry) in entries.indexed) ...[
                      if (index > 0) const SizedBox(height: 6),
                      if (entry.header)
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          // header 标为语义标题：读屏不会当成可点项；
                          // 0.55→0.75 把微透白瓷上的对比度拉到 AA 以上。
                          child: Semantics(
                            header: true,
                            child: Text(
                              entry.label,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.6,
                                color: Theme.of(dialogContext)
                                    .colorScheme
                                    .onSurface
                                    .withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                        )
                      else
                        GlassSurface(
                        radius: 24,
                        // 双态玻璃胶囊材质：与分类条/底栏同源（pill 档）。
                        tint: GlassTint.pill,
                        child: _GlassMenuTile(
                          entry: entry,
                          onTap: entry.enabled
                              ? () => Navigator.of(
                                  dialogContext,
                                ).pop(entry.value)
                              : null,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      );
    },
  );
}

class _GlassMenuTile extends StatelessWidget {
  const _GlassMenuTile({required this.entry, this.onTap});

  final GlassMenuEntry<dynamic> entry;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final foreground = entry.enabled
        ? scheme.onSurface
        : scheme.onSurface.withValues(alpha: 0.38);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(24),
          // 「点按有光，操作有回应」：跟随指针的局部高光 + 全区轻微增亮
          // （对齐官方 InteractiveHighlight）。
          child: SoftGlassPressHighlight(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      entry.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: _menuLabelStyle.copyWith(
                        color: entry.checked ? scheme.primary : foreground,
                      ),
                    ),
                  ),
                  if (entry.checked) ...[
                    const SizedBox(width: 6),
                    AppIcon(AppIcons.check, size: 20, color: scheme.primary),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
