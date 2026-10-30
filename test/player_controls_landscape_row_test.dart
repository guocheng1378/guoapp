import 'package:duanju_app/player_controls.dart';
import 'package:duanju_app/player_interactions.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';

/// 横屏全屏下行布局回归：右侧按钮组必须贴屏幕右边缘。
///
/// 旧实现里下行按钮行有**三个** flex 参与者（弹幕状态 Flexible + Spacer +
/// 右侧组 Expanded），剩余空间被三方平分，右侧组只拿到 1/3 → 整组按钮悬在
/// 屏幕中段（用户报「下行图标没靠右」），同时线路按钮被反向滚动裁掉
/// （用户报「线路选择找不到」）。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  double viewportWidth(WidgetTester tester) =>
      tester.view.physicalSize.width / tester.view.devicePixelRatio;

  Future<Player> mount(
    WidgetTester tester, {
    Size size = const Size(844, 390),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final platform = ScriptedPlayer();
    final player = Player(platformPlayer: platform);
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayerControls(
            player: player,
            interactions: interactions,
            enabled: true,
            fullscreen: true,
            showOnPlaybackReady: true,
            landscapeChrome: true,
            onBack: () {},
            title: '测试剧',
            onTogglePlayback: () {},
            onEpisodes: () async {},
            onSpeed: () async {},
            onQuality: () async {},
            speed: 1,
            qualityLabel: '1080P',
            onFocusSurface: () {},
            routeLabel: '线路 1/2',
            onRoute: () async {},
            onExitFullscreen: () {},
            hasNext: true,
            onNext: () {},
          ),
        ),
      ),
    );
    await settle(tester);
    return player;
  }

  testWidgets('横屏下行右侧按钮组贴屏幕右边缘', (tester) async {
    final player = await mount(tester);
    final exit = find.byKey(const ValueKey('player-fullscreen-exit'));
    expect(exit, findsOneWidget);
    final rect = tester.getRect(exit);
    expect(
      viewportWidth(tester) - rect.right,
      lessThan(60),
      reason: '「退出全屏」应贴在右边缘；修复前右侧组只拿到 1/3 剩余空间，'
          '差距在 300px 以上',
    );
    await player.dispose();
  });

  testWidgets('线路按钮完整落在视口内（不被反向滚动裁掉）', (tester) async {
    final player = await mount(tester);
    final route = find.byKey(const ValueKey('player-route'));
    expect(route, findsOneWidget);
    final rect = tester.getRect(route);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(viewportWidth(tester)));
    await player.dispose();
  });

  testWidgets('下一集图标在左侧播放键旁（用户定调放回左侧）', (tester) async {
    final player = await mount(tester);
    final next = find.byKey(const ValueKey('player-next-episode'));
    expect(next, findsOneWidget);
    expect(
      tester.getRect(next).center.dx,
      lessThan(viewportWidth(tester) / 3),
      reason: '下一集图标应在左侧播放键旁',
    );
    await player.dispose();
  });
}
