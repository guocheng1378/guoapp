import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'player_fixtures.dart';

void main() {
  Future<void> settleOperations(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<void> mount(
    WidgetTester tester,
    RouteRepository repository,
    ScriptedPlayer platform, {
    Size? size,
    FakeViewPadding? padding,
  }) async {
    SharedPreferences.setMockInitialValues({});
    if (size != null) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
    }
    if (padding != null) {
      tester.view.padding = padding;
    }
    final store = LocalStore(await SharedPreferences.getInstance());
    final detail = await repository.detail(FixtureRepository.free);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData.dark(),
        home: PlayerScreen(
          detail: detail,
          initialIndex: 0,
          initialPosition: 7,
          repository: repository,
          store: store,
          playerFactory: () => Player(platformPlayer: platform),
          videoBuilder: (controls) => controls,
        ),
      ),
    );
    await settleOperations(tester);
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.view.resetPadding();
    await settleOperations(tester);
    expect(player.disposed, isTrue);
    expect(tester.takeException(), isNull);
  }

  testWidgets(
    'duplicate errors switch once while keeping progress, rate and pause state',
    (tester) async {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      await tester.tap(find.byKey(const ValueKey('player-speed')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('1.5x').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('关闭菜单'));
      await tester.pumpAndSettle();
      await player.seek(const Duration(seconds: 28));
      await tester.pump();
      await tester.tap(find.byTooltip('暂停播放'));
      await settleOperations(tester);
      player.fail();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await settleOperations(tester);
      // 首次恢复是「原地重开」：沿用同一地址与会话重开播放器，不消耗备用
      // 线路，也不动解析进度。
      expect(repository.fallbackCalls, 0);
      expect(repository.primaryCalls, 1);
      expect(player.opened.last.start, const Duration(seconds: 28));
      expect(player.state.rate, 1.5);
      expect(player.played.last, isFalse);
      expect(repository.active.length, 1);
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'recovery exhaustion releases sessions and manual retry keeps the saved position',
    (tester) async {
      final repository = RouteRepository()..broken = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      // 恢复链：reuse → alternative → refresh → alternative → stop。
      // 初次挂载算一次 primary，之后 refresh 一次、alternative 两次。
      for (var i = 0; i < 7; i++) {
        await tester.pump(const Duration(seconds: 1));
        await settleOperations(tester);
      }
      expect(repository.primaryCalls, 2);
      expect(repository.fallbackCalls, 2);
      expect(find.text('暂时无法播放'), findsOneWidget);
      expect(repository.active, isEmpty);
      // 卡顿看门狗阈值 45 秒：越过它也不应再发起新的解析/换线路。
      await tester.pump(const Duration(seconds: 50));
      expect(repository.primaryCalls + repository.fallbackCalls, 4);
      repository.broken = false;
      await tester.tap(find.text('重试播放'));
      await settleOperations(tester);
      expect(player.opened.last.start, const Duration(seconds: 7));
      expect(find.text('暂时无法播放'), findsNothing);
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets(
    'switching episodes ignores a delayed fallback and frees both old plans',
    (tester) async {
      // broken=true 让「原地重开」也立刻失败，恢复链才会继续走到换线路，
      // 从而制造出一个迟到的 fallback。
      final repository = RouteRepository()
        ..deferFallback = true
        ..broken = true;
      final player = ScriptedPlayer();
      await mount(tester, repository, player);
      for (var i = 0; i < 2; i++) {
        player.fail();
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await settleOperations(tester);
      }
      expect(repository.pending, isNotNull);
      await tester.tap(find.byKey(const ValueKey('play-episode-2')));
      await settleOperations(tester);
      final currentURL = player.opened.last.uri;
      final late = PlaybackPlan(
        url: 'https://media.test/late.mp4',
        session: 'late',
      );
      repository.active.add(late.session);
      repository.pending!.complete(late);
      await settleOperations(tester);
      expect(player.opened.last.uri, currentURL);
      expect(repository.active.length, 1);
      expect(repository.active, isNot(contains('late')));
      await unmount(tester, player);
      expect(repository.active, isEmpty);
    },
  );

  testWidgets('picture-in-picture hides app overlay controls', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      switch (call.method) {
        case 'pictureInPictureStatus':
          return {'supported': true, 'active': false};
        case 'enterPictureInPicture':
          return {'supported': true, 'active': true, 'requested': true};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsOneWidget,
      );
      expect(find.text('选集'), findsOneWidget);
      expect(find.text('简介'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('player-picture-in-picture')));
      await tester.pump();
      await tester.pump();
      await settleOperations(tester);
      expect(
        find.byKey(const ValueKey('player-picture-in-picture')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('player-speed')), findsNothing);
      expect(find.byKey(const ValueKey('player-quality')), findsNothing);
      expect(find.byKey(const ValueKey('player-progress')), findsNothing);
      expect(find.text('选集'), findsNothing);
      expect(find.text('简介'), findsNothing);
      expect(find.text('下载'), findsNothing);
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('mobile player pane starts below the system status area', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        size: const Size(390, 844),
        padding: const FakeViewPadding(top: 32),
      );
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      expect(surface.top, greaterThanOrEqualTo(32));
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });

  testWidgets('mobile landscape player fills the screen without status bar gap', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(
        tester,
        repository,
        player,
        size: const Size(844, 390),
        padding: const FakeViewPadding(top: 32),
      );
      // 竖屏片源在横屏里不会自动进全屏（走宽屏布局），画面仍要铺到顶边。
      player.videoSize(320, 480);
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 10));
      }
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      expect(surface.top, 0);
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });

  testWidgets('compact player tools stay clustered instead of evenly spread', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AppDevice.channel, (call) async {
      if (call.method == 'pictureInPictureStatus') {
        return {'supported': true, 'active': false};
      }
      return null;
    });
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      await mount(tester, repository, player, size: const Size(390, 844));
      final speed = tester.getRect(find.byKey(const ValueKey('player-speed')));
      final quality = tester.getRect(
        find.byKey(const ValueKey('player-quality')),
      );
      final pip = tester.getRect(
        find.byKey(const ValueKey('player-picture-in-picture')),
      );
      // 线路键（plan 带备用线路时显示）与画面比例键插在清晰度与画中画之间，
      // 仍需保持聚类（不铺满整行）。
      final route = tester.getRect(find.byKey(const ValueKey('player-route')));
      final display = tester.getRect(
        find.byKey(const ValueKey('player-display')),
      );
      expect(quality.left - speed.right, lessThan(8));
      expect(route.left - quality.right, lessThan(8));
      expect(display.left - route.right, lessThan(8));
      expect(pip.left - display.right, lessThan(8));
      expect(pip.right, greaterThan(330));
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
