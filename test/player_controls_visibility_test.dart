import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 播放器控制栏可见性回归：这些都是实机反馈「很突兀 / 不该弹」的问题，
/// 用测试钉住，避免以后又被改回去。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<ScriptedPlayer> mount(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    final detail = await RouteRepository().detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          initialPosition: 7,
          repository: RouteRepository(),
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
  }

  /// 控制栏是否可交互：控件层用 IgnorePointer(ignoring: !visible) 包着，
  /// 只要祖先链上有任意一个 IgnorePointer 在忽略，就认为不可见。
  bool controlsVisible(WidgetTester tester) {
    final tool = find.byKey(const ValueKey('player-fullscreen-toggle'));
    if (tool.evaluate().isEmpty) return false;
    final blockers = find.ancestor(
      of: tool,
      matching: find.byType(IgnorePointer),
    );
    for (final element in blockers.evaluate()) {
      if ((element.widget as IgnorePointer).ignoring) return false;
    }
    return true;
  }

  Rect gestureArea(WidgetTester tester) =>
      tester.getRect(find.byKey(const ValueKey('player-gesture-surface')));

  /// 顶部剧集信息行是否可见：用返回键作锚点，看它外层的 IgnorePointer
  bool topBarVisible(WidgetTester tester) {
    final back = find.byTooltip('返回');
    if (back.evaluate().isEmpty) return false;
    for (final element in find
        .ancestor(of: back, matching: find.byType(IgnorePointer))
        .evaluate()) {
      if ((element.widget as IgnorePointer).ignoring) return false;
    }
    return true;
  }

  /// 单击要等双击仲裁（300ms）才生效，测试里必须推进足够时间
  Future<void> tapScreen(WidgetTester tester, Offset at) async {
    await tester.tapAt(at);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('控制栏只在主动唤出时出现，2.5 秒后自动收起（播放中）', (tester) async {
    final player = await mount(tester);
    expect(controlsVisible(tester), isTrue, reason: '进入播放器先亮一次');

    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isFalse, reason: '播放中 2.5 秒后自动收起');

    await tapScreen(tester, gestureArea(tester).center);
    expect(controlsVisible(tester), isTrue, reason: '点画面能唤出');

    await unmount(tester, player);
  });

  testWidgets('暂停后中央按钮不再常驻，2.5 秒后收起', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isFalse);

    await tapScreen(tester, gestureArea(tester).center);
    final pauseButton = find.byTooltip('暂停播放');
    expect(pauseButton, findsOneWidget, reason: '暂停前中央按钮可见');
    await tester.tap(pauseButton);
    await tester.pump();
    expect(player.state.playing, isFalse);

    await tester.pump(const Duration(seconds: 5));
    expect(
      controlsVisible(tester),
      isFalse,
      reason: '暂停后中央按钮必须自动收起，不能长期杵在画面上',
    );
    await unmount(tester, player);
  });

  testWidgets('中间 HUD 只留播放/暂停按钮，且比上下控制栏先收起', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 3));
    expect(controlsVisible(tester), isFalse);

    await tapScreen(tester, gestureArea(tester).center);
    final pauseButton = find.byTooltip('暂停播放');
    expect(pauseButton, findsOneWidget);
    expect(
      find.byTooltip('上一集'),
      findsNothing,
      reason: '切集走竖滑手势和选集面板，中间不再摆上一集按钮',
    );
    expect(find.byTooltip('下一集'), findsNothing);

    // tapScreen 自带 400ms 双击仲裁等待；中间 HUD 1.5s 收起 + 200ms 淡出下线，
    // 拆两段泵避开 1.7s 的边界
    await tester.pump(const Duration(milliseconds: 1200));
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      pauseButton,
      findsNothing,
      reason: '中间按钮 1.5 秒先收，不能拖到控制栏之后',
    );
    expect(
      controlsVisible(tester),
      isTrue,
      reason: '上下控制栏 2.5 秒才收，比中间晚',
    );

    await tester.pump(const Duration(milliseconds: 1000));
    expect(controlsVisible(tester), isFalse, reason: '累计 2.9 秒后上下也收起');
    await unmount(tester, player);
  });

  testWidgets('长按倍速中控制栏不弹出也不常驻', (tester) async {
    final player = await mount(tester);
    final area = gestureArea(tester);
    final spot = Offset(area.center.dx, area.top + area.height * .25);
    await tester.pump(const Duration(seconds: 3));
    expect(controlsVisible(tester), isFalse);

    // 长按 600ms（超过 350ms 判定阈值）进入 2 倍速
    final gesture = await tester.startGesture(spot);
    await tester.pump(const Duration(milliseconds: 600));
    expect(player.rates, contains(2.0), reason: '长按进入倍速');
    expect(
      controlsVisible(tester),
      isFalse,
      reason: '倍速提示只弹胶囊，不能把控制栏顶出来挡画面',
    );

    await gesture.up();
    await tester.pump();
    expect(
      controlsVisible(tester),
      isFalse,
      reason: '松手后的恢复提示也不该把控制栏弹回来',
    );
    await unmount(tester, player);
  });

  testWidgets('外部直接暂停不会把控制栏顶出来', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isFalse);

    await player.pause();
    await tester.pump();
    await tester.pump(const Duration(seconds: 2));
    expect(
      controlsVisible(tester),
      isFalse,
      reason: '暂停本身不该触发控制栏显示',
    );
    await unmount(tester, player);
  });

  testWidgets('滑动调进度松手后不弹工具栏', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isFalse);

    final area = gestureArea(tester);
    await tapScreen(tester, area.center);

    // 水平滑动调进度：放在上部空白，避开中央按钮与底部控制区
    final start = Offset(area.center.dx - 80, area.top + area.height * .25);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(120, 0));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    expect(
      controlsVisible(tester),
      isFalse,
      reason: '滑动快进松手后应直接继续播放，不把工具栏顶出来',
    );
    await unmount(tester, player);
  });

  testWidgets('控制栏隐藏时整屏上下滑都能调音量（含画面下部）', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    expect(controlsVisible(tester), isFalse);

    final area = gestureArea(tester);
    // 先把音量降到中段，否则满音量下上滑看不出变化
    await player.setVolume(50);
    await tester.pump();
    // 右侧靠边但要避开系统返回手势禁区（最边缘 24px 内滑动本就不响应）
    final start = Offset(area.right - 40, area.top + area.height * .55);
    final before = player.state.volume;
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -90));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump(const Duration(milliseconds: 60));
    await gesture.up();
    await tester.pump();

    expect(
      player.state.volume,
      greaterThan(before),
      reason: '控制栏隐藏时，画面下部向上滑也必须能加音量',
    );
    await unmount(tester, player);
  });

  testWidgets('单击画面可反复切换控制栏显隐', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    final area = gestureArea(tester);
    // 点上部空白：中央是播放/上下集按钮，底部是进度条，都会被控件吃掉
    final spot = Offset(area.center.dx, area.top + area.height * .25);

    await tapScreen(tester, spot);
    expect(controlsVisible(tester), isTrue);

    await tapScreen(tester, spot);
    expect(controlsVisible(tester), isFalse);
    await unmount(tester, player);
  });

  testWidgets('HUD：滑动亮度松手后 1 秒内自动消失', (tester) async {
    final player = await mount(tester);
    final area = gestureArea(tester);

    // 左侧向上滑（亮度区），滑到一半停住看 HUD 是否出现
    final start = Offset(area.left + 60, area.top + area.height * .6);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 60));
    expect(
      find.textContaining('%'),
      findsWidgets,
      reason: '滑动调亮度时 HUD 应显示百分比',
    );

    // 保持按住：HUD 不该消失（手指还在屏幕上）
    await tester.pump(const Duration(milliseconds: 900));
    expect(find.textContaining('%'), findsWidgets, reason: '按住时 HUD 常驻');

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(
      find.textContaining('%'),
      findsNothing,
      reason: '松手后 HUD 必须自动隐藏',
    );
    await unmount(tester, player);
  });

  testWidgets('HUD：滑动音量松手后自动消失', (tester) async {
    final player = await mount(tester);
    final area = gestureArea(tester);
    await player.setVolume(40);
    await tester.pump();

    final start = Offset(area.right - 40, area.top + area.height * .6);
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, -120));
    await tester.pump(const Duration(milliseconds: 60));
    expect(find.textContaining('%'), findsWidgets);

    await gesture.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1400));
    expect(find.textContaining('%'), findsNothing, reason: '松手后音量 HUD 必须消失');
    await unmount(tester, player);
  });

  testWidgets('HUD：长按倍速提示在松手后自动消失', (tester) async {
    final player = await mount(tester);
    final area = gestureArea(tester);
    final spot = Offset(area.center.dx, area.top + area.height * .25);

    // 长按 500ms（超过 350ms 判定阈值）
    final gesture = await tester.startGesture(spot);
    await tester.pump(const Duration(milliseconds: 500));
    await gesture.up();
    await tester.pump();

    await tester.pump(const Duration(seconds: 3));
    expect(
      find.textContaining('松开恢复'),
      findsNothing,
      reason: '长按提示在松手后必须自动消失，不能一直压在画面上',
    );
    await unmount(tester, player);
  });

  testWidgets('顶部剧集信息行跟随控制栏一起隐藏', (tester) async {
    final player = await mount(tester);
    expect(topBarVisible(tester), isTrue, reason: '顶部信息行默认亮着');

    await tester.pump(const Duration(seconds: 5));
    expect(
      topBarVisible(tester),
      isFalse,
      reason: '控制栏收起时顶部信息行也必须一起隐藏，不能一直占着画面',
    );

    final area = gestureArea(tester);
    await tapScreen(tester, Offset(area.center.dx, area.top + area.height * .25));
    expect(topBarVisible(tester), isTrue, reason: '点画面时顶部信息行一起回来');
    await unmount(tester, player);
  });

  testWidgets('生命周期：下拉通知栏（inactive）不打断播放', (tester) async {
    final player = await mount(tester);
    expect(player.state.playing, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(
      player.state.playing,
      isTrue,
      reason: '下拉通知栏只是短暂 inactive，不能把视频停掉',
    );

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(player.state.playing, isTrue);
    await unmount(tester, player);
  });

  testWidgets('生命周期：切后台暂停后回到前台自动续播', (tester) async {
    final player = await mount(tester);
    expect(player.state.playing, isTrue);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(player.state.playing, isFalse, reason: '真正进后台应暂停');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      player.state.playing,
      isTrue,
      reason: '回到前台必须自动续播，否则用户得手动点一下播放',
    );
    await unmount(tester, player);
  });

  testWidgets('生命周期：用户自己按过暂停的，回前台不该被自动播', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));
    await tapScreen(tester, Offset(
      gestureArea(tester).center.dx,
      gestureArea(tester).top + gestureArea(tester).height * .25,
    ));
    await tester.tap(find.byTooltip('暂停播放'));
    await tester.pump();
    expect(player.state.playing, isFalse);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(
      player.state.playing,
      isFalse,
      reason: '用户主动暂停的，回来后必须保持暂停，不能擅自继续播',
    );
    await unmount(tester, player);
  });

  testWidgets('HUD：一集播完立即连播，不出现倒计时提示', (tester) async {
    final player = await mount(tester);
    await tester.pump(const Duration(seconds: 5));

    var completedSeen = false;
    player.stream.completed.listen((_) => completedSeen = true);
    player.finishEpisode();
    await tester.pump();
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(completedSeen, isTrue, reason: '播完事件应送达播放页');
    expect(
      find.byKey(const ValueKey('player-advance-countdown')),
      findsNothing,
      reason: '连播不等待，倒计时提示不该出现',
    );
    expect(player.opened.length, 2, reason: '播完应立即打开下一集');
    await unmount(tester, player);
  });
}
