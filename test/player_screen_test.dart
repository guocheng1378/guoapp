import 'package:duanju_app/app_icons.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:duanju_app/related_catalog_screen.dart';
import 'package:duanju_app/related_dramas.dart';
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
    int preferredQuality = 0,
    Drama? drama,
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
    if (preferredQuality > 0) {
      await store.setPlaybackPreferences(
        PlaybackPreferences(quality: preferredQuality),
      );
    }
    final detail = await repository.detail(drama ?? FixtureRepository.free);
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
      // 半屏（内嵌）把倍速等三颗大按钮收进了下方详情页，这里直接用播放器
      // 接口设倍速：要验证的是恢复重开时倍速状态被保留。
      await player.setRate(1.5);
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
      // 下行工具行有一枚「选集」文字钮，下方详情面板还有一个选集 tab，
      // 所以这里是多个而不是一个（PiP 隐藏后应全部消失，见下方断言）。
      expect(find.text('选集'), findsWidgets);
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

  testWidgets('mobile landscape player is not pushed right by the display cutout', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final player = ScriptedPlayer();
      // 本机横屏时挖孔在左边缘占 144px（dumpsys：displayCutout frame [0,0][144,1200]）。
      await mount(
        tester,
        repository,
        player,
        size: const Size(844, 390),
        padding: const FakeViewPadding(left: 144, top: 32),
      );
      final surface = tester.getRect(
        find.byKey(const ValueKey('player-gesture-surface')),
      );
      // 画面层不能被挖孔推走（改前这里是 144），也不能被状态栏压下去。
      expect(surface.left, 0);
      expect(surface.top, 0);
      await unmount(tester, player);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });

  testWidgets('半屏控制层合并单行：进度条与两颗全屏键同行、状态钮贴右', (
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
      final quality = tester.getRect(
        find.byKey(const ValueKey('player-quality')),
      );
      final pip = tester.getRect(
        find.byKey(const ValueKey('player-picture-in-picture')),
      );
      final display = tester.getRect(
        find.byKey(const ValueKey('player-display')),
      );
      final toggle = tester.getRect(
        find.byKey(const ValueKey('player-portrait-fullscreen')),
      );
      final landscapeToggle = tester.getRect(
        find.byKey(const ValueKey('player-landscape-fullscreen')),
      );
      final progress = tester.getRect(
        find.byKey(const ValueKey('player-progress')),
      );

      // 半屏（内嵌）把三颗大按钮收进下方详情页，视频区只留播放与两颗全屏键。
      expect(find.byKey(const ValueKey('player-route')), findsNothing);
      expect(find.byKey(const ValueKey('player-speed')), findsNothing);
      expect(find.byKey(const ValueKey('player-episodes')), findsNothing);

      // 上行：画质标签与「画面（比例+片头尾）」/投屏/画中画同在标题行。
      expect(pip.center.dy, closeTo(quality.center.dy, 14));
      expect(display.center.dy, closeTo(quality.center.dy, 14));
      expect(pip.right, greaterThan(330));

      // 半屏单行（本次改版定调：单行更矮更干净，两栏版式只保留在全屏态）：
      // 进度条与两颗全屏键合并成一条 44 高的行，垂直居中对齐。
      expect(progress.center.dy, closeTo(toggle.center.dy, 10));
      expect(progress.bottom, greaterThanOrEqualTo(toggle.top));

      // 两颗全屏键并排贴右下：竖屏全屏 ⇄ 横屏全屏（相邻，不留空隙）。
      expect(landscapeToggle.left, greaterThanOrEqualTo(toggle.right));
      expect(landscapeToggle.right, greaterThan(330));
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('narrow portrait player keeps every tool inside the screen', (
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
      // 320 宽（窄屏/竖屏短剧）：工具项总宽超过屏宽时必须整行等比缩，
      // 而不是让右侧全屏键溢出屏幕（红果竖屏实机现象）。修复前这里是
      // RenderFlex overflow，umount 的 takeException 断言会红。
      await mount(tester, repository, player, size: const Size(320, 844));
      // 半屏只剩两颗全屏键，右边缘仍要贴住屏幕内侧（不溢出）。
      final toggle = tester.getRect(
        find.byKey(const ValueKey('player-landscape-fullscreen')),
      );
      expect(toggle.left, greaterThanOrEqualTo(0));
      expect(toggle.right, lessThanOrEqualTo(320));
      expect(toggle.right, greaterThan(300));
      await unmount(tester, player);
    } finally {
      messenger.setMockMethodCallHandler(AppDevice.channel, null);
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('quality tool shows the actual played tier, never 自动', (
    tester,
  ) async {
    final repository = RouteRepository()..quality = 720;
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    expect(find.byKey(const ValueKey('player-quality')), findsOneWidget);
    expect(find.text('720P'), findsOneWidget);
    expect(find.text('自动'), findsNothing);
    await unmount(tester, player);
  });

  testWidgets('quality tool hides itself when the site has no quality tiers', (
    tester,
  ) async {
    // 站点只给一条直链、没有任何画质档位：以前会硬塞一个「高清」标签，
    // 点开是空面板——纯属误导，现在整颗按钮不渲染。
    final repository = RouteRepository()
      ..quality = 0
      ..qualities = const [];
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    expect(find.byKey(const ValueKey('player-quality')), findsNothing);
    expect(find.text('高清'), findsNothing);
    // 半屏（内嵌）下其余可见工具键不受影响：两颗全屏键仍在原位。
    expect(
      find.byKey(const ValueKey('player-portrait-fullscreen')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('player-landscape-fullscreen')),
      findsOneWidget,
    );
    await unmount(tester, player);
  });

  testWidgets('quality tool prefers the actual tier over a stale preference', (
    tester,
  ) async {
    // 偏好里存着 1080P，但这个源只有 720P：后端（nativePlaybackChoices）
    // 找不到该档就退到实际可播的最高档，标签必须跟着实际走。
    final repository = RouteRepository()
      ..quality = 720
      ..qualities = const [720];
    final player = ScriptedPlayer();
    await mount(tester, repository, player, preferredQuality: 1080);
    expect(find.text('720P'), findsOneWidget);
    expect(find.text('1080P'), findsNothing);
    await unmount(tester, player);
  });

  testWidgets('quality panel lists the tiers the site actually offers', (
    tester,
  ) async {
    final repository = RouteRepository();
    final player = ScriptedPlayer();
    await mount(tester, repository, player);
    await tester.tap(find.byKey(const ValueKey('player-quality')));
    await tester.pumpAndSettle();
    // 移动端面板已是侧栏形态（showPlayerSidePanel + SideChoiceList）：
    // 面板标题「清晰度」+ 每档一行（side-quality-*）。
    expect(find.text('清晰度'), findsWidgets);
    expect(find.byKey(const ValueKey('side-quality-1080')), findsOneWidget);
    expect(find.byKey(const ValueKey('side-quality-720')), findsOneWidget);
    // 没存过画质偏好时，勾选落在本集实际播放的档（fixture 实际 1080P），
    // 而不是整排全未选中：选中行带 check 图标，未选行没有。
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('side-quality-1080')),
        matching: find.byType(AppIcon),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('side-quality-720')),
        matching: find.byType(AppIcon),
      ),
      findsNothing,
    );
    // 面板里同样不存在「自动」档。
    expect(find.text('自动'), findsNothing);
    await tester.tap(find.byTooltip('关闭菜单'));
    await tester.pumpAndSettle();
    await unmount(tester, player);
  });

  // 播放器「简介」tab 是详情页信息区的第二份实现：站源名/分类/标签同样
  // 要能点出结果页（2026-10-25 用户反馈「简介页的东西都不能点击跳转」）。
  // hongguo 源在两个变体下都可见，本用例不依赖 ALL_SOURCES。
  const linked = Drama(
    id: 'hongguo:player-synopsis',
    source: 'hongguo',
    title: '播放器简介剧',
    episodes: 12,
    category: '都市',
    tags: ['甜宠', '逆袭'],
    releaseStatus: 'ongoing',
    // 显式定性长剧：短剧会走竖屏全屏形态，播放面板（含简介 tab）根本不
    // 渲染，用例看到的是全屏播放器而不是下方的功能面板。
    contentKind: 'long',
    duration: 1200,
  );

  testWidgets('player synopsis tab links to related results', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      final repository = RouteRepository();
      final platform = ScriptedPlayer();
      await mount(
        tester,
        repository,
        platform,
        // 高机身：简介是 ListView，窄机身下标签排在视口外没法点。
        size: const Size(390, 1400),
        padding: const FakeViewPadding(top: 32),
        drama: linked,
      );

      await tester.tap(find.text('简介'));
      await settleOperations(tester);

      // 播放器里的「相关推荐」与详情页是同一组件（2026-10-25 用户反馈
      // 「简介页没有推荐的剧」指的就是这里）。
      expect(find.byType(RelatedDramaRail), findsOneWidget);

      // 简介 tab 里的「相关推荐」会自己拉一次同源目录：清掉这条自动请求，
      // 下面的断言才只看用户点击产生的。
      repository.queries.clear();

      // 分类「都市」不是 dongpiandi 的 content_kind，落不到站点 kind，走关键词搜索。
      await tester.tap(find.text('都市'));
      await settleOperations(tester);
      expect(find.byType(RelatedCatalogScreen), findsOneWidget);
      expect(repository.queries, <String>['都市']);

      await tester.pageBack();
      await settleOperations(tester);

      await tester.tap(find.text('甜宠'));
      await settleOperations(tester);
      expect(find.byType(RelatedCatalogScreen), findsOneWidget);
      expect(repository.queries, <String>['都市', '甜宠']);
      await unmount(tester, platform);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      tester.view.resetPadding();
    }
  });
}
