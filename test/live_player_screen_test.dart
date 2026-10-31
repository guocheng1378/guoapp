import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_player_screen.dart';
import 'package:duanju_app/live_route_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';

LiveChannel _ch(String name, List<String> urls, {String group = '央视'}) =>
    LiveChannel(name: name, group: group, urls: urls);

Future<ScriptedPlayer> _pump(
  WidgetTester tester,
  List<LiveChannel> channels, {
  int initialIndex = 0,
}) async {
  final player = ScriptedPlayer();
  await tester.pumpWidget(
    MaterialApp(
      home: LivePlayerScreen(
        channels: channels,
        initialIndex: initialIndex,
        playerFactory: () => Player(platformPlayer: player),
        videoBuilder: (controls) => controls,
      ),
    ),
  );
  return player;
}

/// 打开阶段错误要等最短观察窗（5s）到点才确认切线：一帧处理后推进窗口
/// 再处理切线。
Future<void> _settleFailure(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(LivePlayerScreen.routeGrace);
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump();
}

void main() {
  // 线路记忆是进程级静态状态：前序用例手动选线写下的记忆会让后续用例
  // （如同名频道）进台即恢复线路，每个用例必须从干净状态起跑。
  setUp(LiveRouteMemory.resetForTest);

  testWidgets('opens initial channel and clears loading', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    expect(player.opened.map((m) => m.uri), ['http://good/1.m3u8']);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });

  testWidgets('falls back to next route on failure', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://broken/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await _settleFailure(tester);

    expect(player.opened.map((m) => m.uri), [
      'http://broken/1.m3u8',
      'http://good/2.m3u8',
    ]);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });

  testWidgets('shows failure card after all routes fail and retries',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://broken/1.m3u8', 'http://broken/2.m3u8']),
    ]);
    await _settleFailure(tester);
    await _settleFailure(tester);
    expect(find.byKey(const Key('live-player-retry')), findsOneWidget);
    expect(player.opened.length, 2);

    await tester.tap(find.byKey(const Key('live-player-retry')));
    await _settleFailure(tester);
    await _settleFailure(tester);
    expect(player.opened.length, 4);
    expect(find.byKey(const Key('live-player-retry')), findsOneWidget);
  });

  testWidgets('auto-hides controls after 3.5s and toggles on tap',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();
    expect(find.byKey(const Key('live-player-back')), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 3600));
    expect(find.byKey(const Key('live-player-back')), findsNothing);

    await tester.tap(find.byKey(const Key('live-player-gesture')));
    await tester.pump();
    expect(find.byKey(const Key('live-player-back')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live-player-gesture')));
    await tester.pump();
    expect(find.byKey(const Key('live-player-back')), findsNothing);
  });

  testWidgets('vertical swipe switches channel with OSD', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
      _ch('CCTV2', ['http://good/2.m3u8'], group: '卫视'),
    ]);
    await tester.pump();
    await tester.pump();

    await tester.drag(
      find.byKey(const Key('live-player-gesture')),
      const Offset(0, -200),
    );
    await tester.pump();
    expect(find.text('2  CCTV2'), findsOneWidget);
    expect(player.opened.last.uri, 'http://good/2.m3u8');

    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('2  CCTV2'), findsNothing);
  });

  testWidgets('bottom bar steps channels', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
      _ch('CCTV2', ['http://good/2.m3u8']),
      _ch('CCTV3', ['http://good/3.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('live-player-next')));
    await tester.pump();
    expect(player.opened.last.uri, 'http://good/2.m3u8');

    await tester.tap(find.byKey(const Key('live-player-prev')));
    await tester.pump();
    expect(player.opened.last.uri, 'http://good/1.m3u8');
  });

  testWidgets('channel panel lists groups and switches channel',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
      _ch('CCTV2', ['http://good/2.m3u8'], group: '卫视'),
      _ch('CCTV3', ['http://good/3.m3u8'], group: '卫视'),
    ]);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('live-player-channels')));
    await tester.pump(); // 面板展开动画在此帧启动
    // 越过 220ms 动画：宽度为 0 时横向 ListView 不构建分组 chip。
    await tester.pump(const Duration(milliseconds: 260));
    expect(find.byKey(const Key('live-panel-list')), findsOneWidget);
    expect(find.byKey(const Key('live-panel-group-央视')), findsOneWidget);
    expect(find.byKey(const Key('live-panel-group-卫视')), findsOneWidget);
    // 面板默认只列当前频道所在分组（央视，仅 item-0），先切到「卫视」。
    await tester.tap(find.byKey(const Key('live-panel-group-卫视')));
    await tester.pump();
    expect(find.byKey(const Key('live-panel-item-1')), findsOneWidget);

    await tester.tap(find.byKey(const Key('live-panel-item-1')));
    await tester.pump();
    expect(player.opened.last.uri, 'http://good/2.m3u8');
    expect(find.byKey(const Key('live-panel-list')), findsNothing);
  });

  testWidgets('route menu switches to selected route', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('live-player-routes')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('线路 2'));
    await tester.pump();
    await tester.pump();

    expect(player.opened.last.uri, 'http://good/2.m3u8');
  });

  testWidgets('loading card shows channel name and route number',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await _pump(tester, [
      _ch('CCTV1', ['http://broken/1.m3u8', 'http://broken/2.m3u8']),
    ]);
    await tester.pump();
    // 拉流黑屏期不再是一片黑：转圈 + 频道名 + 当前线路号。
    expect(find.text('正在加载「CCTV1」 · 线路 1'), findsOneWidget);

    await tester.pump(LivePlayerScreen.routeGrace);
    await tester.pump();
    // 线路 1 确认失败切到线路 2，仍在加载并显示新线路号。
    expect(find.text('正在加载「CCTV1」 · 线路 2'), findsOneWidget);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });

  testWidgets('stale error is dropped when frame lands in confirm window',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://broken/1.m3u8']),
    ]);
    await tester.pump();
    // 确认窗挂起期间出画（stop→open 竞态后真实媒体就绪）：
    // buffering=false 落地即取消切换。
    player.injectBuffering(false);
    await tester.pump();

    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();

    // 窗内出画 → 旧 error 丢弃，不切线不落失败卡。
    expect(player.opened.length, 1);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('slow but healthy route is not skipped by an early error',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://slow/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    // 上一条线路的迟到 error（stop→open 竞态）：旧实现 1.2s 就切走。
    player.fail();
    await tester.pump();
    // 越过旧的 1.2s 窗口，但未到最短观察窗：仍在等线路 1。
    await tester.pump(const Duration(milliseconds: 1500));
    await tester.pump();
    expect(player.opened.map((m) => m.uri), ['http://slow/1.m3u8']);
    expect(find.text('正在加载「CCTV1」 · 线路 1'), findsOneWidget);

    // 3 秒出画——真连接在观察窗内自证，切线被撤销。
    await tester.pump(const Duration(seconds: 2));
    player.injectBuffering(false);
    await tester.pump();
    expect(player.opened.map((m) => m.uri), ['http://slow/1.m3u8']);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 出画后连 12s watchdog 也已撤销，不再打扰。
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(player.opened.length, 1);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });

  testWidgets('transient error while playing recovers without switching',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();
    expect(player.opened.length, 1);

    // 播放途中一次瞬时抖动：旧实现当场切线，把还活着的连接丢掉。
    player.fail();
    await tester.pump();
    expect(player.opened.length, 1);

    // 确认窗内恢复出画 → 丢弃，继续播原线路。
    player.injectBuffering(false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1300));
    await tester.pump();
    expect(player.opened.map((m) => m.uri), ['http://good/1.m3u8']);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });

  testWidgets('stalled route after a frame switches route after watchdog',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();
    // 首帧出画：线路 1 自证可用（12s 无画面兜底随之撤销）。
    expect(player.opened.map((m) => m.uri), ['http://good/1.m3u8']);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 播放途中卡流：出画后再次进入缓冲且长时间不恢复——旧实现永久转圈，
    // 没有任何兜底会切走这条已卡死的线路。
    player.injectBuffering(true);
    await tester.pump();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // 未到卡流超时前仍在原线路等待（12s 无画面兜底已撤销，不再出手）。
    await tester.pump(const Duration(seconds: 6));
    await tester.pump();
    expect(player.opened.map((m) => m.uri), ['http://good/1.m3u8']);

    // 超过卡流超时 → 切下一线路。
    await tester.pump(const Duration(seconds: 7));
    await tester.pump();
    await tester.pump();
    expect(player.opened.map((m) => m.uri).last, 'http://good/2.m3u8');
  });

  testWidgets('timed-out route gets a second chance before failure card',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://dead/1.m3u8', 'http://broken/2.m3u8']),
    ]);
    await tester.pump();
    // 线路 1：连 error 都不发的挂起链 → 12s watchdog 切走（无明确报错）。
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(player.opened.map((m) => m.uri).last, 'http://broken/2.m3u8');

    // 线路 2：明确报错 → 确认失败后先回头重试线路 1，而不是直接落失败卡。
    await _settleFailure(tester);
    expect(player.opened.map((m) => m.uri).last, 'http://dead/1.m3u8');
    expect(find.byKey(const Key('live-player-retry')), findsNothing);

    // 线路 1 仍未出画：再次 watchdog 后所有线路均已用尽配额 → 失败卡。
    await tester.pump(const Duration(seconds: 13));
    await tester.pump();
    expect(find.byKey(const Key('live-player-retry')), findsOneWidget);
  });

  testWidgets('dead link without any events switches route after watchdog',
      (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://dead/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.pump(const Duration(seconds: 13));
    await tester.pump();

    // 12s 无画面兜底强制切线，第二线路正常出画。
    expect(player.opened.map((m) => m.uri).last, 'http://good/2.m3u8');
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byKey(const Key('live-player-retry')), findsNothing);
  });
}
