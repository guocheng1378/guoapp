import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 短剧竖屏播放形态回归：手机端短剧（单集 ≤10 分钟）进入即竖屏全屏、
/// 顶栏旋转按钮、横屏视频自动回落、水平 seek 与长剧一致、切集区加宽。
/// 长剧（duration>600）在每条用例里作对照，行为必须保持旧貌。
///
/// 测试宿主是 Windows，因此所有用例 override android 驱动 _mobile：
/// 播放器锁向走 SystemChrome（无插件依赖），swipe 手势才会开启。
/// override 的还原必须在测试体（unmount）内完成——addTearDown 晚于
/// binding 的不变量校验，靠它会报「debug variable was changed」。
void main() {
  const shortDrama = Drama(
    id: 'hongguo:300',
    source: 'hongguo',
    title: '竖屏短剧',
    episodes: 2,
    // 2 分钟 < 600 秒：命中短剧竖屏形态。
    duration: 120,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<({ScriptedPlayer player, RouteRepository repo})> mount(
    WidgetTester tester, {
    Drama drama = shortDrama,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // SystemChannels.platform（锁向/沉浸模式）出站消息在 flutter_tester 里
    // 等不到平台回复：直接 await 会永久挂起（_rotating 因此卡死）。
    // 按标准做法 mock 出站消息，回成功信封让 Future 正常完成。
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.platform.name,
      (ByteData? message) async =>
          const JSONMethodCodec().encodeSuccessEnvelope(null),
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(SystemChannels.platform.name, null));
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    final repo = RouteRepository();
    final detail = await repo.detail(drama);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          initialPosition: 7,
          repository: repo,
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settle(tester);
    return (player: platform, repo: repo);
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await settle(tester);
    expect(player.disposed, isTrue);
    // 必须在测试体内还原（见文件头注释）。
    debugDefaultTargetPlatformOverride = null;
  }

  Rect gestureArea(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('player-gesture-surface')));

  /// 水平拖拽（快进快退手势），起点放在上部空白避让中央按钮。
  Future<void> dragHorizontally(WidgetTester tester) async {
    final area = gestureArea(tester);
    final gesture = await tester.startGesture(
      Offset(area.center.dx - 80, area.top + area.height * .25),
    );
    await gesture.moveBy(const Offset(120, 0));
    await gesture.up();
  }

  /// 竖直拖拽（亮度/音量/切集手势），x 按手势区宽度比例取点。
  /// 起点放在上部 y=25% 避开控制栏，否则 pointerDown 被上层控件截获。
  Future<void> dragVertically(WidgetTester tester, double xRatio) async {
    final area = gestureArea(tester);
    await tester.dragFrom(
      Offset(area.width * xRatio, area.top + area.height * .25),
      const Offset(0, -160),
    );
  }

  testWidgets('短剧进入即竖屏全屏，长剧保持常规形态', (tester) async {
    final session = await mount(tester);
    expect(
      find.byTooltip('旋转到横屏'),
      findsOneWidget,
      reason: '短剧：进入即竖屏全屏，全屏顶栏出现旋转按钮',
    );
    expect(
      tester.widget<PopScope<Object>>(find.byType(PopScope<Object>)).canPop,
      isTrue,
      reason: '短剧竖屏全屏是正常播放态，返回键直接退出播放页',
    );
    await unmount(tester, session.player);

    // 对照：长剧（duration 1200）同条件进入，无旋转按钮。
    final longSession = await mount(tester, drama: FixtureRepository.free);
    expect(find.byTooltip('旋转到横屏'), findsNothing);
    await unmount(tester, longSession.player);
  });

  testWidgets('长剧手动全屏后返回键先退全屏（canPop=false），且无旋转按钮', (tester) async {
    final session = await mount(tester, drama: FixtureRepository.free);
    expect(find.byTooltip('旋转到横屏'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('player-fullscreen-toggle')));
    await settle(tester);
    expect(
      tester.widget<PopScope<Object>>(find.byType(PopScope<Object>)).canPop,
      isFalse,
      reason: '长剧全屏的返回键语义仍是先退全屏',
    );
    expect(
      find.byTooltip('旋转到横屏'),
      findsNothing,
      reason: '旋转按钮只属于短剧竖屏形态',
    );
    await unmount(tester, session.player);
  });

  testWidgets('旋转按钮在竖屏/横屏态间往返切换', (tester) async {
    final session = await mount(tester);
    await tester.tap(find.byTooltip('旋转到横屏'));
    await settle(tester);
    expect(find.byTooltip('转回竖屏'), findsOneWidget);

    await tester.tap(find.byTooltip('转回竖屏'));
    await settle(tester);
    expect(find.byTooltip('旋转到横屏'), findsOneWidget);
    await unmount(tester, session.player);
  });

  testWidgets('横屏视频自动回落常规形态，竖屏视频保持全屏', (tester) async {
    var session = await mount(tester);
    expect(find.byTooltip('旋转到横屏'), findsOneWidget);
    session.player.videoSize(320, 180);
    await settle(tester);
    expect(
      find.byTooltip('旋转到横屏'),
      findsNothing,
      reason: 'contain 模式下横屏视频会上下大黑边，自动退回常规形态',
    );
    await unmount(tester, session.player);

    session = await mount(tester);
    session.player.videoSize(180, 320);
    await settle(tester);
    expect(
      find.byTooltip('旋转到横屏'),
      findsOneWidget,
      reason: '竖屏视频保持竖屏全屏',
    );
    await unmount(tester, session.player);
  });

  testWidgets('手动旋转到横屏后，横屏视频不再自动回落', (tester) async {
    final session = await mount(tester);
    await tester.tap(find.byTooltip('旋转到横屏'));
    await settle(tester);
    session.player.videoSize(320, 180);
    await settle(tester);
    expect(
      find.byTooltip('转回竖屏'),
      findsOneWidget,
      reason: '用户手动旋转过则尊重选择，不自动退全屏',
    );
    await unmount(tester, session.player);
  });

  testWidgets('短剧竖屏全屏支持水平滑动快进快退，与长剧一致', (tester) async {
    var session = await mount(tester);
    expect(
      session.player.state.duration,
      greaterThan(Duration.zero),
      reason: 'open 链已就绪（时长已写入），否则后面的 seek 断言无意义',
    );
    final positionBefore = session.player.state.position;
    await dragHorizontally(tester);
    await settle(tester);
    expect(
      session.player.pauses,
      greaterThanOrEqualTo(1),
      reason: '短剧竖屏全屏水平滑进入 seek 预览（先暂停）',
    );
    expect(
      session.player.state.position,
      isNot(positionBefore),
      reason: '松手后提交 seek，位置变化',
    );
    await unmount(tester, session.player);

    // 对照：长剧水平滑行为一致（先暂停预览，松手提交）。
    session = await mount(tester, drama: FixtureRepository.free);
    expect(
      session.player.state.duration,
      greaterThan(Duration.zero),
      reason: '长剧 open 链同样应就绪',
    );
    final longBefore = session.player.state.position;
    await dragHorizontally(tester);
    await settle(tester);
    expect(
      session.player.pauses,
      greaterThanOrEqualTo(1),
      reason: '长剧水平滑进入 seek 预览（先暂停）',
    );
    expect(session.player.state.position, isNot(longBefore));
    await unmount(tester, session.player);
  });

  testWidgets('切集区加宽到半屏：x=30% 竖滑切集，两侧仍是亮度/音量', (tester) async {
    final session = await mount(tester);
    // x=30%：旧阈值 0.35 会落亮度区，新阈值 0.25~0.75 内应切下一集。
    await dragVertically(tester, .30);
    await settle(tester);
    expect(
      session.repo.requestedEpisodes,
      contains(2),
      reason: 'x=30% 竖滑触发下一集（切集区加宽生效）',
    );

    // x=20%：亮度分支，不切集也不动音量。
    final volumeBefore = session.player.state.volume;
    await dragVertically(tester, .20);
    await settle(tester);
    expect(session.repo.requestedEpisodes, isNot(contains(3)));
    expect(session.player.state.volume, volumeBefore);

    // x=80%：音量分支，上滑加音量。先把音量压低，避开 100 满格 clamp。
    await session.player.setVolume(30);
    await settle(tester);
    await dragVertically(tester, .80);
    await settle(tester);
    expect(
      session.player.state.volume,
      greaterThan(30),
      reason: 'x=80% 竖滑调整音量（上滑加音量）',
    );
    await unmount(tester, session.player);
  });
}
