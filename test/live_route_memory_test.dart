import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_player_screen.dart';
import 'package:duanju_app/live_route_memory.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'player_fixtures.dart';

LiveChannel _ch(String name, List<String> urls, {String group = '央视'}) =>
    LiveChannel(name: name, group: group, urls: urls);

void _size(WidgetTester tester) {
  tester.view.physicalSize = const Size(800, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Future<ScriptedPlayer> _pump(
  WidgetTester tester,
  List<LiveChannel> channels, {
  int initialIndex = 0,
  String listId = 'xingwei',
}) async {
  final player = ScriptedPlayer();
  await tester.pumpWidget(
    MaterialApp(
      home: LivePlayerScreen(
        channels: channels,
        initialIndex: initialIndex,
        listId: listId,
        playerFactory: () => Player(platformPlayer: player),
        videoBuilder: (controls) => controls,
      ),
    ),
  );
  return player;
}

/// 准备已加载的（空）记忆存储；platform 留给「冷启动重载」用例复用
///（同一 InMemory store = 同一设备，resetStatic + 重挂 = 进程重启）。
Future<(SharedPreferences, SharedPreferencesStorePlatform)> _memory({
  Map<String, Object> initial = const {},
}) async {
  SharedPreferences.resetStatic();
  final platform =
      InMemorySharedPreferencesStore.withData(Map<String, Object>.of(initial));
  SharedPreferencesStorePlatform.instance = platform;
  final prefs = await SharedPreferences.getInstance();
  await LiveRouteMemory.load(prefs);
  return (prefs, platform);
}

/// 模拟冷启动：同一持久层、全新内存缓存。
Future<SharedPreferences> _relaunch(SharedPreferencesStorePlatform platform) async {
  SharedPreferences.resetStatic();
  SharedPreferencesStorePlatform.instance = platform;
  final prefs = await SharedPreferences.getInstance();
  await LiveRouteMemory.load(prefs);
  return prefs;
}

/// 打开阶段错误走 1.2s 延迟确认窗：一帧处理后推进窗口再处理切线。
Future<void> _settleFailure(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1300));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    LiveRouteMemory.resetForTest();
  });

  test('remember / recall round trip, isolation and persistence', () async {
    final (prefs, platform) = await _memory();

    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), isNull);

    await LiveRouteMemory.remember('xingwei', 'CCTV-1', 'http://r2/1.m3u8');
    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), 'http://r2/1.m3u8');
    // 其它列表 / 频道互不串扰。
    expect(LiveRouteMemory.recall('guovin', 'CCTV-1'), isNull);
    expect(LiveRouteMemory.recall('xingwei', 'CCTV-2'), isNull);

    // 覆盖写入取最新。
    await LiveRouteMemory.remember('xingwei', 'CCTV-1', 'http://r3/1.m3u8');
    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), 'http://r3/1.m3u8');

    // 模拟冷启动：同一设备、进程重启后从持久层重载。
    final relaunchPrefs = await _relaunch(platform);
    expect(relaunchPrefs, isNot(same(prefs)));
    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), 'http://r3/1.m3u8');
  });

  test('corrupted storage is treated as empty', () async {
    await _memory(initial: <String, Object>{
      'flutter.${LiveRouteMemory.storageKey}': 'not-json{',
    });

    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), isNull);
    // 仍可正常写入。
    await LiveRouteMemory.remember('xingwei', 'CCTV-1', 'http://r2/1.m3u8');
    expect(LiveRouteMemory.recall('xingwei', 'CCTV-1'), 'http://r2/1.m3u8');
  });

  test('capacity cap keeps newest entries', () async {
    await _memory();
    for (var i = 0; i < LiveRouteMemory.maxEntries + 5; i++) {
      await LiveRouteMemory.remember('xingwei', 'ch$i', 'http://u/$i');
    }
    expect(LiveRouteMemory.recall('xingwei', 'ch0'), isNull);
    expect(
      LiveRouteMemory.recall('xingwei', 'ch${LiveRouteMemory.maxEntries + 4}'),
      'http://u/${LiveRouteMemory.maxEntries + 4}',
    );
  });

  testWidgets('player starts on remembered route', (tester) async {
    _size(tester);
    await _memory();
    await LiveRouteMemory.remember('xingwei', 'CCTV1', 'http://good/2.m3u8');

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    expect(player.opened.single.uri, 'http://good/2.m3u8');
  });

  testWidgets('stale remembered url not in urls falls back to route 1',
      (tester) async {
    _size(tester);
    await _memory();
    await LiveRouteMemory.remember('xingwei', 'CCTV1', 'http://gone/9.m3u8');

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    expect(player.opened.single.uri, 'http://good/1.m3u8');
  });

  testWidgets('manual pick remembers route with OSD and reuses it on reentry',
      (tester) async {
    _size(tester);
    final (_, platform) = await _memory();

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();
    expect(player.opened.single.uri, 'http://good/1.m3u8');

    // 手动选线：写入记忆 + OSD「已记住」。
    await tester.tap(find.byKey(const Key('live-player-routes')));
    await tester.pumpAndSettle();
    expect(find.text('线路 2 · 已记住'), findsNothing); // 尚无记忆
    await tester.tap(find.text('线路 2'));
    await tester.pump();
    expect(find.text('线路 2 · 已记住'), findsOneWidget);
    expect(LiveRouteMemory.recall('xingwei', 'CCTV1'), 'http://good/2.m3u8');

    // 重新进台（模拟进程重启）：从同一持久层重载，记忆仍在。
    await _relaunch(platform);
    expect(LiveRouteMemory.recall('xingwei', 'CCTV1'), 'http://good/2.m3u8');
    // 同型 widget 直接二次 pumpWidget 会复用 State（initState 不重跑），
    // 先卸载旧树再挂新页面。
    await tester.pumpWidget(const SizedBox.shrink());
    final replay = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8', 'http://good/2.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();
    expect(replay.opened.single.uri, 'http://good/2.m3u8');
  });

  testWidgets('auto fallback does not pollute memory and remembered mark '
      'shows on non-current route', (tester) async {
    _size(tester);
    await _memory();
    // 上次手动选了线路 2（当时能看），这次它挂了。
    await LiveRouteMemory.remember('xingwei', 'CCTV1', 'http://broken/2.m3u8');

    final player = await _pump(tester, [
      _ch('CCTV1', [
        'http://good/1.m3u8',
        'http://broken/2.m3u8',
        'http://good/3.m3u8',
      ]),
    ]);
    // 起播落在记忆线路（即便它现在坏了）；确认窗过后按序补试未尝试
    // 的线路 → 回到线路 1（默认线）。
    await tester.pump();
    await _settleFailure(tester);
    expect(player.opened.map((m) => m.uri), [
      'http://broken/2.m3u8',
      'http://good/1.m3u8',
    ]);
    // 自动兜底不写记忆。
    expect(LiveRouteMemory.recall('xingwei', 'CCTV1'), 'http://broken/2.m3u8');

    // 记忆线路（2）不是当前线路（1）：菜单里标「已记住」。
    await tester.tap(find.byKey(const Key('live-player-routes')));
    await tester.pumpAndSettle();
    expect(find.text('线路 2 · 已记住'), findsOneWidget);
  });

  testWidgets('channel switch applies the remembered route of the new channel',
      (tester) async {
    _size(tester);
    await _memory();
    await LiveRouteMemory.remember('xingwei', 'CCTV2', 'http://good/2b.m3u8');

    final player = await _pump(tester, [
      _ch('CCTV1', ['http://good/1.m3u8']),
      _ch('CCTV2', ['http://good/2a.m3u8', 'http://good/2b.m3u8']),
    ]);
    await tester.pump();
    await tester.pump();

    await tester.tap(find.byKey(const Key('live-player-next')));
    await tester.pump();
    expect(player.opened.last.uri, 'http://good/2b.m3u8');
  });
}
