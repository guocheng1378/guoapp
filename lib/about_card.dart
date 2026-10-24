import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'glass.dart';
import 'app_icons.dart';
import 'folme.dart';
import 'remote_notice.dart';

/// 手机端「关于」轻量浮卡：屏幕居中的小玻璃信息面——无 barrier 压暗、
/// 点空白处关闭（与排序筛选浮卡同族，替代居中大玻璃 AboutDialog）。
/// TV 端仍走玻璃弹窗保焦点导航。
///
/// 小屏适配：宽度 min(248, 屏宽-32)、高度上限 屏高-32，内容超限可滚动，
/// 分屏/小窗等任意机型都不溢出视口。
///
/// 「检查更新」入口：复用远程公告链路（[fetchRemoteNoticeConfig] →
/// [RemoteNoticeConfig.tryParse]），线上 build 严格大于本机时关闭本卡并
/// 弹出既有更新卡（[showRemoteNoticeCard]，含去下载）；无更新 / 拉取失败
/// 用 SnackBar 反馈，不打断当前卡。
///
/// 彩蛋：头部（图标/应用名/版本）在 1.6 秒内连点 5 次触发
/// [onActivate]（弹出激活页，验证通过后解锁隐藏站源——由回调方实现），
/// 触发后自动关闭浮卡。
///
/// [anchorKey] 已不参与定位（居中后无需锚点），保留参数仅为兼容旧调用方。
/// [debugFetcher] 仅测试注入：替代真网拉取；测试环境无注入时检查动作
/// 按失败直通，绝不触真网（与 maybeShowRemoteNotice 的 FLUTTER_TEST 守卫同款）。
Future<void> showAboutCard({
  required BuildContext context,
  GlobalKey? anchorKey,
  required String appName,
  required String version,
  VoidCallback? onActivate,
  RemoteConfigFetcher? debugFetcher,
}) async {
  final overlayBox =
      Overlay.of(context, rootOverlay: true).context.findRenderObject();
  if (overlayBox is! RenderBox) return;
  final screenSize = overlayBox.size;

  // 小屏收缩：窄屏（分屏/小窗）下留 16px 边距，常规屏维持 248 设计宽。
  final cardWidth = math.min(248.0, screenSize.width - 32);
  final maxHeight = math.max(160.0, screenSize.height - 32);

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
          alignment: Alignment.center,
          child: child,
        ),
      );
    },
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final scheme = Theme.of(dialogContext).colorScheme;
      var taps = 0;
      Timer? tapTimer;
      var checking = false;
      // StatefulBuilder 的 setter 回填到外层，供 checkUpdate 刷新按钮态。
      void Function(VoidCallback)? setCardState;
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

      Future<void> checkUpdate() async {
        if (checking) return;
        // 测试环境无注入直通失败反馈，绝不触真网（真网在 fake-async 区
        // 永不完成或污染套件，与 maybeShowRemoteNotice 同一坑）。
        if (debugFetcher == null &&
            Platform.environment.containsKey('FLUTTER_TEST')) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            const SnackBar(content: Text('检查更新失败，请稍后重试')),
          );
          return;
        }
        checking = true;
        setCardState?.call(() {});
        var failed = false;
        RemoteNoticeUpdate? update;
        try {
          final body = debugFetcher != null
              ? await debugFetcher()
              : await fetchRemoteNoticeConfig();
          update =
              body == null ? null : RemoteNoticeConfig.tryParse(body)?.update;
        } on Object {
          failed = true;
        }
        if (!dialogContext.mounted) return;
        checking = false;
        setCardState?.call(() {});
        final localBuild = parseBuildNumber(version);
        final hasUpdate =
            !failed && update != null && localBuild != null && update.build > localBuild;
        if (hasUpdate) {
          Navigator.of(dialogContext).pop();
          if (context.mounted) {
            await showRemoteNoticeCard(context, update: update);
          }
          return;
        }
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(
              failed ? '检查更新失败，请检查网络后重试' : '当前已是最新版本',
            ),
          ),
        );
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

      return StatefulBuilder(
        builder: (dialogContext, setter) {
          setCardState = setter;
          return Align(
            alignment: Alignment.center,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxHeight),
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
                    child: SingleChildScrollView(
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
                          Row(
                            children: [
                              FolmePress(
                                child: FilledButton.tonal(
                                  style: FilledButton.styleFrom(
                                    visualDensity: VisualDensity.compact,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                    ),
                                  ),
                                  onPressed: checking ? null : checkUpdate,
                                  child: checking
                                      ? const SizedBox(
                                          width: 14,
                                          height: 14,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                          ),
                                        )
                                      : const Text('检查更新'),
                                ),
                              ),
                              const Spacer(),
                              TextButton(
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
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    },
  );
}
