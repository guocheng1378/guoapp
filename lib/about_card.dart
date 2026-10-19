import 'dart:async';

import 'package:flutter/material.dart';

import 'glass.dart';
import 'app_icons.dart';

/// 手机端「关于」轻量浮卡：锚定顶栏 ⋯ 岛，无 barrier 压暗、
/// 小玻璃面贴锚点下方，点空白处关闭（与排序筛选浮卡同族，
/// 替代居中大玻璃 AboutDialog）。TV 端仍走玻璃弹窗保焦点导航。
///
/// 彩蛋：头部（图标/应用名/版本）在 1.6 秒内连点 5 次触发
/// [onActivate]（弹出激活页，验证通过后解锁隐藏站源——由回调方实现），
/// 触发后自动关闭浮卡。
Future<void> showAboutCard({
  required BuildContext context,
  required GlobalKey anchorKey,
  required String appName,
  required String version,
  VoidCallback? onActivate,
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

  const cardWidth = 248.0;
  var left = topLeft.dx + anchorSize.width - cardWidth;
  left = left.clamp(12.0, screenSize.width - cardWidth - 12);
  final top = (topLeft.dy + anchorSize.height + 8).clamp(
    0.0,
    screenSize.height - 64,
  );

  await showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关于$appName',
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
      final scheme = Theme.of(dialogContext).colorScheme;
      var taps = 0;
      Timer? tapTimer;
      void registerTap() {
        taps++;
        tapTimer?.cancel();
        tapTimer = Timer(const Duration(milliseconds: 1600), () => taps = 0);
        if (taps < 5) return;
        tapTimer?.cancel();
        taps = 0;
        onActivate?.call();
        Navigator.of(dialogContext).pop();
      }

      final header = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: registerTap,
        child: Row(
          children: [
            AppIcon(AppIcons.playCircleFilled, size: 32, color: Color(0xFFFF765F)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    appName,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .titleMedium
                        ?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                    version,
                    style: Theme.of(dialogContext)
                        .textTheme
                        .bodySmall
                        ?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

      return Stack(
        children: [
          Positioned(
            left: left,
            top: top,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: screenSize.height - top - 24,
              ),
              child: SizedBox(
                width: cardWidth,
                child: GlassSurface(
                  radius: 20,
                  topHighlight: true,
                  // 信息卡是连续文字面（不同于短标签的胶囊菜单），
                  // 底色要实一档：海报透上来会让小字糊掉。
                  tint: GlassTint.card,
                  child: Material(
                    type: MaterialType.transparency,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          header,
                          const SizedBox(height: 12),
                          Text(
                            '独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。',
                            style: Theme.of(dialogContext).textTheme.bodySmall
                                ?.copyWith(color: scheme.onSurfaceVariant),
                          ),
                          const SizedBox(height: 8),
                          Align(
                            alignment: Alignment.centerRight,
                            child: TextButton(
                              onPressed: () {
                                Navigator.of(dialogContext).pop();
                                showLicensePage(
                                  context: context,
                                  applicationName: appName,
                                  applicationVersion: version,
                                );
                              },
                              child: const Text('查看许可'),
                            ),
                          ),
                        ],
                      ),
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
