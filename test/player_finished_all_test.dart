import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

/// 最后一集播完不该只是「停住」：给明确收尾与重播/返回出口。
void main() {
  testWidgets('最后一集播完：全剧已看完卡片给重播/返回出口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    // FixtureRepository.free 固定返回 2 集，initialIndex=1 即最后一集。
    final detail = await RouteRepository().detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 1,
          repository: RouteRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    platform.finishEpisode();
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('player-finished-all')), findsOneWidget);
    expect(find.text('全剧已看完'), findsOneWidget);
    expect(find.text('重播'), findsOneWidget);
    expect(find.text('返回'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('player-finished-replay')));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(find.byKey(const ValueKey('player-finished-all')), findsNothing);
  });

  testWidgets('首集播完仍立即连播，不出现终点卡', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    final detail = await RouteRepository().detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          repository: RouteRepository(),
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }

    final openedBefore = platform.opened.length;
    platform.finishEpisode();
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
    expect(platform.opened.length, greaterThan(openedBefore));
    expect(find.byKey(const ValueKey('player-finished-all')), findsNothing);
  });
}
