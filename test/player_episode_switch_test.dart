import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 切集两阶段行为回归：点下一集后先「暂停定格」旧画面（不停播、旧帧留屏），
/// 新地址解析就绪后才「停旧换新」。解析期间遮罩要浅（旧画面可见），
/// 修复前是先 stop 再慢慢解析——整段切集都是黑屏。
void main() {
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<({RouteRepository repo, LocalStore store})> mount(
    WidgetTester tester,
    ScriptedPlayer player,
  ) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    final store = LocalStore(await SharedPreferences.getInstance());
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
    return (repo: repo, store: store);
  }

  /// 从加载提示文案向上找纯黑半透明 ColoredBox，读它的不透明度。
  double overlayAlphaOf(WidgetTester tester, String message) {
    for (final element in find
        .ancestor(
          of: find.textContaining(message),
          matching: find.byType(ColoredBox),
        )
        .evaluate()) {
      final color = (element.widget as ColoredBox).color;
      if (color.red == 0 && color.green == 0 && color.blue == 0 && color.a < 1) {
        return color.a;
      }
    }
    return -1;
  }

  testWidgets('切集：解析期间旧画面定格（暂停不停播、浅遮罩），地址就绪才换源', (tester) async {
    final player = ScriptedPlayer();
    final mounted = await mount(tester, player);
    mounted.repo.deferResolve = true;
    expect(player.opened, hasLength(1), reason: '首集已加载');
    final stopsAtStart = player.stops;

    player.finishEpisode();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    expect(find.textContaining('正在准备第'), findsOneWidget,
        reason: '切集时提示「正在准备第 N 集」');
    expect(player.opened, hasLength(1), reason: '新地址未就绪前不换源');
    expect(player.stops, stopsAtStart, reason: '解析期间不能新增 stop——旧画面要定格在屏上');
    expect(player.pauses, greaterThanOrEqualTo(1), reason: '旧画面通过暂停定格');
    final alpha = overlayAlphaOf(tester, '正在准备第');
    expect(alpha, greaterThan(0), reason: '解析期有遮罩提示切集状态');
    expect(alpha, lessThan(0.5), reason: '解析期遮罩要浅，定格画面仍可见');

    mounted.repo.completePendingPlan();
    await settle(tester);

    expect(player.opened, hasLength(2), reason: '新地址就绪后换源开播');
    expect(player.stops, stopsAtStart + 1, reason: '换源时才新增 stop');
    expect(find.textContaining('正在准备第'), findsNothing, reason: '开播后提示撤下');
  });

  testWidgets('切集：旧集进度在解析等待期内就按定格点落盘', (tester) async {
    final player = ScriptedPlayer();
    final mounted = await mount(tester, player);
    mounted.repo.deferResolve = true;

    player.finishEpisode();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));

    // 此刻新地址解析仍挂起（stop 尚未发生）：旧集进度必须已经按定格点保存。
    // 若有人把「存进度」挪到 stop 之后，ScriptedPlayer.stop 会把位置清零、
    // 守卫 position < .1 直接跳过保存——此用例转红。
    final entries = mounted.store.history.where((e) => e.episode == 1).toList();
    expect(entries, isNotEmpty, reason: '解析等待期内旧集进度已落盘');
    expect(entries.first.position, greaterThanOrEqualTo(100),
        reason: '进度保存在定格点（播完=片长 120s），不是换源后的零位');

    mounted.repo.completePendingPlan();
    await settle(tester);
    expect(player.opened, hasLength(2), reason: '换源正常完成');
  });

  testWidgets('键盘 N 触发下一集（电脑端无媒体键时的切集路径）', (tester) async {
    final player = ScriptedPlayer();
    final mounted = await mount(tester, player);
    mounted.repo.deferResolve = true;

    await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
    await settle(tester);

    expect(find.textContaining('正在准备第'), findsOneWidget,
        reason: 'N 键走 onEpisode(+1) 进入两阶段切集');
    expect(player.opened, hasLength(1), reason: '解析挂起期间不换源');

    mounted.repo.completePendingPlan();
    await settle(tester);
    expect(player.opened, hasLength(2), reason: 'N 键切集正常完成');
  });

  testWidgets('键盘 P 在第一集时只提示不切集', (tester) async {
    final player = ScriptedPlayer();
    await mount(tester, player);

    await tester.sendKeyEvent(LogicalKeyboardKey.keyP);
    await settle(tester);

    expect(find.textContaining('已经是第一集'), findsOneWidget,
        reason: '出界方向给提示文案');
    expect(player.opened, hasLength(1), reason: '第一集再上一集不触发播放');
  });
}
