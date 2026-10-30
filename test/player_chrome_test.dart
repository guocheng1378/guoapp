import 'package:duanju_app/app_layout.dart';
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

/// 新版播放器控制层的三件结构性改动：
/// 1) 横屏锁定（控制栏不再出现、点画面不唤出、只留左中锁钮）；
/// 2) 状态区电池 + 时间（取不到就整颗隐藏）；
/// 3) 倍速/选集从右侧滑出面板，点选即生效并自动关闭。
void main() {
  const shortDrama = Drama(
    id: 'hongguo:300',
    source: 'hongguo',
    title: '竖屏短剧',
    episodes: 3,
    duration: 120,
  );

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<ScriptedPlayer> mount(
    WidgetTester tester, {
    Size size = const Size(390, 844),
    Drama drama = shortDrama,
    Map<String, Object?>? battery,
  }) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // SystemChannels.platform 出站消息在 flutter_tester 里等不到回复，
    // 不 mock 会让锁向 await 永久挂起（页面卡在 _rotating）。
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.platform.name,
      (ByteData? message) async =>
          const JSONMethodCodec().encodeSuccessEnvelope(null),
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.platform.name,
        null,
      ),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'battery') return battery;
      return null;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(AppDevice.channel, null));
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
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
    return platform;
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await settle(tester);
    expect(player.disposed, isTrue);
    // 必须在测试体内还原（addTearDown 晚于 binding 的不变量校验）。
    debugDefaultTargetPlatformOverride = null;
  }

  Rect gestureArea(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('player-gesture-surface')));

  /// 点画面中央。onTap 与 onDoubleTap 同存时单击要等双击仲裁（300ms）才触发，
  /// 所以必须 pump 过 400ms，否则会被误判成「没反应」。
  Future<void> tapScreen(WidgetTester tester) async {
    await tester.tapAt(gestureArea(tester).center);
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
  }

  /// 控制栏是否可交互：控制层用 IgnorePointer(ignoring: !visible) 包着。
  bool chromeVisible(WidgetTester tester, String anchorKey) {
    final anchor = find.byKey(ValueKey(anchorKey));
    if (anchor.evaluate().isEmpty) return false;
    final blockers = find.ancestor(
      of: anchor,
      matching: find.byType(IgnorePointer),
    );
    for (final element in blockers.evaluate()) {
      if ((element.widget as IgnorePointer).ignoring) return false;
    }
    return true;
  }

  testWidgets('横屏锁定：控制栏不再出现、点画面不唤出、只留左中锁钮', (tester) async {
    // 短剧进入即竖屏全屏，再点竖屏下行的「横屏全屏」切到横屏版式
    //（原顶栏「转横屏」已随清理移除）。
    final player = await mount(tester);
    await tester.tap(find.byKey(const ValueKey('player-landscape-fullscreen')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      find.byKey(const ValueKey('player-lock')),
      findsOneWidget,
      reason: '横屏版式才有锁定钮',
    );
    expect(
      chromeVisible(tester, 'player-fullscreen-exit'),
      isTrue,
      reason: '横屏全屏版式：下行最右有「退出全屏」键',
    );
    // 锁钮缩小到 44dp（用户要求「再小一点」），但仍要好点得中。
    final lock = tester.getRect(find.byKey(const ValueKey('player-lock')));
    expect(lock.width, lessThanOrEqualTo(44));
    expect(lock.height, lessThanOrEqualTo(44));

    await tester.tap(find.byKey(const ValueKey('player-lock')));
    await settle(tester);
    expect(
      chromeVisible(tester, 'player-fullscreen-exit'),
      isFalse,
      reason: '锁定后控制栏立即收起',
    );
    expect(
      find.byKey(const ValueKey('player-lock')),
      findsOneWidget,
      reason: '锁钮常驻，否则锁了就解不开',
    );

    await tapScreen(tester);
    expect(
      chromeVisible(tester, 'player-fullscreen-exit'),
      isFalse,
      reason: '锁定期间点画面不再唤出控制栏',
    );

    await tester.tap(find.byKey(const ValueKey('player-lock')));
    await settle(tester);
    expect(
      chromeVisible(tester, 'player-fullscreen-exit'),
      isTrue,
      reason: '解锁后控制栏立刻恢复',
    );

    // 恢复后的单击语义也回来了：点一下收起、再点一下唤出。
    await tapScreen(tester);
    expect(chromeVisible(tester, 'player-fullscreen-exit'), isFalse);
    await tapScreen(tester);
    expect(
      chromeVisible(tester, 'player-fullscreen-exit'),
      isTrue,
      reason: '解锁后单击恢复正常切换',
    );
    await unmount(tester, player);
  });

  testWidgets('状态区电量：取到就显示百分比，取不到整颗隐藏', (tester) async {
    var player = await mount(
      tester,
      battery: {'level': 87, 'charging': false},
    );
    expect(
      find.byTooltip('87%'),
      findsOneWidget,
      reason: '电量图标 tooltip 给出百分比',
    );
    await unmount(tester, player);

    player = await mount(tester, battery: null);
    expect(
      find.byTooltip('87%'),
      findsNothing,
      reason: '原生端读不到电量时整颗电池不渲染',
    );
    await unmount(tester, player);
  });

  testWidgets('倍速与选集走右侧面板：点选即生效并自动关闭', (tester) async {
    final player = await mount(tester);

    await tester.tap(find.byKey(const ValueKey('player-speed')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      find.byKey(const ValueKey('player-side-panel')),
      findsOneWidget,
      reason: '二级功能从右侧滑出面板',
    );
    await tester.tap(find.byKey(const ValueKey('side-speed-1.5')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(player.state.rate, 1.5);
    expect(
      find.byKey(const ValueKey('player-side-panel')),
      findsNothing,
      reason: '选中即生效并关闭面板',
    );

    await tester.tap(find.byKey(const ValueKey('player-episodes')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    // 竖屏全屏的选集改成底部推挤面板（红果同款），不再是右侧浮层。
    expect(
      find.byKey(const ValueKey('player-side-panel')),
      findsNothing,
      reason: '竖屏全屏选集不再走右侧滑出面板',
    );
    expect(find.byKey(const ValueKey('sheet-episode-2')), findsOneWidget);
    // 视频被顶成顶部小窗（推挤），而不是浮层盖在画面上。
    final video = tester.getRect(
      find.byKey(const ValueKey('player-push-video')),
    );
    expect(
      video.height,
      lessThan(844 * .5),
      reason: '视频区被底部选集面板顶上去了',
    );
    final episodeTile = tester.getSize(
      find.byKey(const ValueKey('sheet-episode-1')),
    );
    expect(
      episodeTile.height,
      lessThanOrEqualTo(44),
      reason: '选集用小格子密度档（原来 56 高的大格子）',
    );
    expect(
      episodeTile.width,
      lessThan(60),
      reason: '按多列排，不再 3 列宽格',
    );
    await tester.tap(find.byKey(const ValueKey('sheet-episode-2')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      player.opened.length,
      greaterThan(1),
      reason: '点第 2 集立即切集',
    );
    expect(
      find.byKey(const ValueKey('player-episode-sheet-close')),
      findsNothing,
      reason: '切集后底部面板自动收起',
    );
    await unmount(tester, player);
  });

  testWidgets('窄屏（320 逻辑宽）上行仍留出剧名宽度', (tester) async {
    final player = await mount(tester, size: const Size(320, 844));
    // 状态钮 + 电池挤满上行时，Expanded 会被压到 0，剧名整条消失。
    final title = find.textContaining('· 第');
    expect(title, findsOneWidget);
    expect(
      tester.getSize(title).width,
      greaterThan(60),
      reason: '窄屏也不能把剧名压没',
    );
    // 电池/时间在窄屏只留图标，时间文字让位给标题。
    expect(find.byKey(const ValueKey('player-lock')), findsNothing);
    await unmount(tester, player);
  });
}
