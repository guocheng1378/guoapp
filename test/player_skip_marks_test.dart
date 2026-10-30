import 'dart:convert';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/player_skip_marks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 片头/片尾跳过回归：标记按剧持久化（同剧所有集共享），
/// 播到标记点自动跳过，且一次播放里每段只生效一次。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<({RouteRepository repo, LocalStore store, ScriptedPlayer player})>
      mount(
    WidgetTester tester,
    ScriptedPlayer player, {
    EpisodeSkipMarks? marks,
  }) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final store = LocalStore(await SharedPreferences.getInstance());
    final seed = marks ?? const EpisodeSkipMarks();
    if (!seed.isEmpty) await store.setSkipMarks(FixtureRepository.free.id, seed);
    final detail = await RouteRepository().detail(FixtureRepository.free);
    final repo = RouteRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          initialPosition: 7,
          repository: repo,
          store: store,
          playerFactory: () => Player(platformPlayer: player),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settle(tester);
    return (repo: repo, store: store, player: player);
  }

  /// 把脚本播放器的位置推到 [seconds]（内部同步 state 并广播事件）。
  void driveTo(ScriptedPlayer player, int seconds) =>
      player.pushPosition(Duration(seconds: seconds));

  group('EpisodeSkipMarks', () {
    test('JSON 往返', () {
      const marks = EpisodeSkipMarks(introEnd: 45.5, outroStart: 1330);
      final decoded = EpisodeSkipMarks.fromJson(
        jsonDecode(jsonEncode(marks.toJson())) as Map<String, dynamic>,
      );
      expect(decoded.introEnd, 45.5);
      expect(decoded.outroStart, 1330);
      expect(decoded, marks);
    });

    test('缺省与非法值归零', () {
      expect(EpisodeSkipMarks.fromJson(const {}).isEmpty, isTrue);
      expect(
        EpisodeSkipMarks.fromJson(const {'introEnd': 'x'}).hasIntro,
        isFalse,
      );
      expect(
        EpisodeSkipMarks.fromJson(const {'outroStart': '20'}).outroStart,
        20,
      );
    });

    test('copyWith 传 0 即清除', () {
      const marks = EpisodeSkipMarks(introEnd: 45, outroStart: 1330);
      expect(marks.copyWith(introEnd: 0).hasIntro, isFalse);
      expect(marks.copyWith(introEnd: 0).outroStart, 1330);
    });
  });

  group('resolveSkipAction', () {
    const marks = EpisodeSkipMarks(introEnd: 45, outroStart: 1330);
    const duration = 1400.0;

    test('片头内 -> 跳过片头', () {
      expect(
        resolveSkipAction(
          position: 3,
          duration: duration,
          marks: marks,
          introApplied: false,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.skipIntro,
      );
    });

    test('正片中 -> 不动作', () {
      expect(
        resolveSkipAction(
          position: 600,
          duration: duration,
          marks: marks,
          introApplied: true,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
      );
    });

    test('片尾 -> 接下一集；最后一集不跳', () {
      expect(
        resolveSkipAction(
          position: 1340,
          duration: duration,
          marks: marks,
          introApplied: true,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.skipOutro,
      );
      expect(
        resolveSkipAction(
          position: 1340,
          duration: duration,
          marks: marks,
          introApplied: true,
          outroApplied: false,
          hasNextEpisode: false,
        ),
        SkipMarkAction.none,
      );
    });

    test('一段播放里每段只生效一次（手动拖回不拽走）', () {
      expect(
        resolveSkipAction(
          position: 10,
          duration: duration,
          marks: marks,
          introApplied: true,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
        reason: '片头已跳过过，用户拖回去重看不该被拽走',
      );
      expect(
        resolveSkipAction(
          position: 1350,
          duration: duration,
          marks: marks,
          introApplied: true,
          outroApplied: true,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
      );
    });

    test('标记点落在片长之外则作废该段', () {
      expect(
        resolveSkipAction(
          position: 3,
          duration: 30,
          marks: marks,
          introApplied: false,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
      );
      expect(
        resolveSkipAction(
          position: 3,
          duration: 30,
          marks: const EpisodeSkipMarks(outroStart: 20),
          introApplied: false,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
        reason: 'outroStart 20 距末尾不足 1 秒容差，同样作废',
      );
    });

    test('片尾起点不晚于片头终点时只保留片头', () {
      expect(
        resolveSkipAction(
          position: 1340,
          duration: duration,
          marks: const EpisodeSkipMarks(introEnd: 45, outroStart: 30),
          introApplied: true,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
        reason: '两个标记打架时不自动跳集，避免用户刚起播就被切走',
      );
    });

    test('片长未知（0）时一律不跳', () {
      expect(
        resolveSkipAction(
          position: 3,
          duration: 0,
          marks: marks,
          introApplied: false,
          outroApplied: false,
          hasNextEpisode: true,
        ),
        SkipMarkAction.none,
      );
    });
  });

  group('片头尾持久化', () {
    test('按剧保存、互不干扰、可清除', () async {
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.skipMarksOf('d1').isEmpty, isTrue);

      await store.setSkipMarks(
        'd1',
        const EpisodeSkipMarks(introEnd: 45, outroStart: 1330),
      );
      await store.setSkipMarks('d2', const EpisodeSkipMarks(outroStart: 600));

      expect(store.skipMarksOf('d1').introEnd, 45);
      expect(store.skipMarksOf('d1').outroStart, 1330);
      expect(store.skipMarksOf('d2').introEnd, 0, reason: '另一部剧不受影响');
      expect(store.skipMarksOf('d2').outroStart, 600);

      await store.setSkipMarks('d1', const EpisodeSkipMarks());
      expect(store.skipMarksOf('d1').isEmpty, isTrue);
      expect(store.skipMarksOf('d2').outroStart, 600, reason: '清除只影响本部剧');
    });

    test('脏 JSON 不抛，回落空标记', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('localSnapshot.v1', 'not-json');
      final store = LocalStore(prefs);
      expect(store.skipMarksOf('d1').isEmpty, isTrue);
    });
  });

  testWidgets('控制栏入口 -> 把当前位置标为片头/片尾 -> 落盘并点亮', (tester) async {
    final player = ScriptedPlayer();
    final mounted = await mount(tester, player);
    final dramaId = FixtureRepository.free.id;

    // 1) 入口在控制栏上（「画面比例与片头尾」合成钮），未标定时不点亮
    expect(find.byKey(const ValueKey('player-display')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-display')));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-side-panel')), findsOneWidget);
    expect(find.text('未设置'), findsNWidgets(2));

    // 2) 播到 45 秒 ->「标定」片头结束
    driveTo(player, 45);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('skip-intro-set')));
    await settle(tester);
    expect(mounted.store.skipMarksOf(dramaId).introEnd, 45);

    // 3) 播到 1330 秒 -> 标定片尾开始。
    //    面板内容比一屏略高：标定片头后行高变长，把「标定」按钮推到视口外，
    //    但按钮仍在 ListView cacheExtent 内（元素已在树里，scrollUntilVisible
    //    因 finder 非空一次也不会拖），必须用 ensureVisible 按真实几何滚动。
    driveTo(player, 1330);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('skip-outro-set')));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.tap(find.byKey(const ValueKey('skip-outro-set')));
    await settle(tester);
    expect(mounted.store.skipMarksOf(dramaId).outroStart, 1330);

    // 4) 清除片头：只剩片尾，入口仍点亮
    await tester.tap(find.byKey(const ValueKey('skip-intro-clear')));
    await settle(tester);
    expect(mounted.store.skipMarksOf(dramaId).hasIntro, isFalse);
    expect(mounted.store.skipMarksOf(dramaId).outroStart, 1330);
  });

  testWidgets('标定过片头后：落在片头区间内会被自动跳过', (tester) async {
    final player = ScriptedPlayer();
    final mounted = await mount(
      tester,
      player,
      marks: const EpisodeSkipMarks(introEnd: 45),
    );
    expect(player.opened, hasLength(1), reason: '首集已加载');

    // 片头内（脚本播放器片长 2 分钟，45 秒仍在有效范围内）
    driveTo(player, 12);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    expect(mounted.store.skipMarksOf(FixtureRepository.free.id).introEnd, 45);
    expect(
      player.state.position,
      const Duration(seconds: 45),
      reason: '落在片头区间内应直接跳到片头结束点',
    );

    // 只生效一次：再拖回 20 秒不应被再次拽走
    driveTo(player, 20);
    await tester.pump(const Duration(milliseconds: 30));
    expect(player.state.position, const Duration(seconds: 20));
  });

  testWidgets('标定过片尾后：播到标记点自动接下一集', (tester) async {
    final player = ScriptedPlayer();
    await mount(
      tester,
      player,
      marks: const EpisodeSkipMarks(outroStart: 100),
    );
    expect(player.opened, hasLength(1));

    driveTo(player, 110);
    await settle(tester);

    expect(player.opened, hasLength(2), reason: '走到片尾标记点自动播下一集');
  });
}
