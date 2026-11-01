// 悬浮方框：替代各页面居中的大玻璃弹窗（GlassDialogShell + AlertDialog）。
// 手机端 = 居中小玻璃卡（方形圆角矩形，容器级一律不用胶囊，见胶囊化定调），
// barrier 全透明、点空白关闭，海报透上来不压暗；
// TV 端自动保留 GlassDialogShell + AlertDialog 弹窗，遥控焦点导航可靠。

import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'glass.dart';

/// 手机端悬浮方框 / TV 端玻璃弹窗的统一入口。
///
/// [title]/[content]/[actions] 两种端共用的内容描述；TV 端装进
/// GlassDialogShell + AlertDialog，手机端装进居中小浮卡。
Future<T?> showFloatingDialog<T>({
  required BuildContext context,
  Widget? title,
  Widget? content,
  List<Widget> actions = const [],
  double width = 300,
  String barrierLabel = '弹窗',
}) {
  if (AppLayout.isTelevision(context)) {
    return showDialog<T>(
      context: context,
      builder: (_) => GlassDialogShell(
        child: AlertDialog(title: title, content: content, actions: actions),
      ),
    );
  }
  final overlayBox =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (overlayBox is! RenderBox) {
    return showDialog<T>(
      context: context,
      builder: (_) => GlassDialogShell(
        child: AlertDialog(title: title, content: content, actions: actions),
      ),
    );
  }
  final screenSize = overlayBox.size;
  final cardWidth = math.min(width, screenSize.width - 32);
  final maxHeight = math.max(160.0, screenSize.height - 32);

  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: barrierLabel,
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
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final textTheme = Theme.of(dialogContext).textTheme;
      Widget? titleWidget = title;
      if (titleWidget != null) {
        titleWidget = DefaultTextStyle(
          style: (textTheme.titleMedium ?? const TextStyle(fontSize: 16))
              .copyWith(fontWeight: FontWeight.w700),
          child: titleWidget,
        );
      }
      // 键盘弹出时上移让位（与 AlertDialog 行为一致），否则输入会被键盘盖住。
      return AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(dialogContext).bottom,
        ),
        child: Align(
          alignment: Alignment.center,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: SizedBox(
              width: cardWidth,
              child: GlassSurface(
                radius: 20,
                topHighlight: true,
                // 确认/输入卡是连续文字面：实档底色，海报透不上来（同关于卡）。
                tint: GlassTint.card,
                child: Material(
                  type: MaterialType.transparency,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (titleWidget != null) titleWidget,
                        if (content != null) ...[
                          if (titleWidget != null) const SizedBox(height: 10),
                          content,
                        ],
                        if (actions.isNotEmpty) ...[
                          const SizedBox(height: 16),
                          Align(
                            alignment: AlignmentDirectional.centerEnd,
                            child: Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: actions,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 悬浮方框内的单选行：与胶囊菜单同语义（勾选态 + 点选即关闭）。
class FloatingOptionRow extends StatelessWidget {
  const FloatingOptionRow({
    super.key,
    required this.label,
    this.subtitle,
    this.leading,
    this.selected = false,
    required this.onTap,
  });

  final String label;
  final String? subtitle;
  final Widget? leading;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 9),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label),
                  if (subtitle != null)
                    Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
            ),
            if (selected)
              Icon(Icons.check_rounded, size: 18, color: theme.colorScheme.primary),
          ],
        ),
      ),
    );
  }
}
