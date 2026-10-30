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

/// 播放器线路面板回归：真名显示、菜单列出全部线路、点选按索引切换。
void main() {
  test('PlaybackPlan parses route labels from native payload', () {
    final plan = PlaybackPlan.fromJson(const {
      'url': 'https://media.test/v.mp4',
      'session': 's1',
      'routeIndex': 1,
      'routeCount': 2,
      'routeLabels': ['无水印资源', '索尼资源'],
    });
    expect(plan.routeLabels, ['无水印资源', '索尼资源']);
    expect(plan.routeIndex, 1);
    expect(plan.hasAlternative, isFalse); // index+1 >= count
    // 缺失字段时回退空表（旧核心/本地播放）
    final bare = PlaybackPlan.fromJson(const {
      'url': 'https://media.test/v.mp4',
      'routeCount': 1,
    });
    expect(bare.routeLabels, isEmpty);
    expect(bare.routeCount, 1);
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  Future<(RouteRepository, ScriptedPlayer)> mount(
    WidgetTester tester, {
    RouteRepository? routes,
  }) async {
    // 手机端形态才有竖屏全屏与线路入口：Windows 宿主下 _mobile=false，
    // 播放器是纯内嵌紧凑形态（按现行定调，紧凑行只留播放+进度，三颗大
    // 按钮收进详情页）。这里 override android 走真机路径。
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    // SystemChannels.platform（锁向）出站消息在 flutter_tester 里等不到
    // 平台回复：await 会永久挂起（进全屏要同步锁向）→ mock 回成功信封。
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
    final store = LocalStore(await SharedPreferences.getInstance());
    final platform = ScriptedPlayer();
    final repository = routes ?? RouteRepository();
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
    await settle(tester);
    return (repository, platform);
  }

  Future<void> unmount(WidgetTester tester, ScriptedPlayer player) async {
    await tester.pumpWidget(const SizedBox.shrink());
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await settle(tester);
    expect(player.disposed, isTrue);
    // 必须在测试体内还原：addTearDown 晚于 binding 的不变量校验，
    // 改 debug 变量会报「debug variable was changed」。
    debugDefaultTargetPlatformOverride = null;
  }

  /// 进竖屏全屏：内嵌/紧凑形态按现行定调藏掉线路/倍速/选集三颗大按钮，
  /// 线路入口要进全屏后才在竖屏下行出现。
  Future<void> enterPortraitFullscreen(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey('player-portrait-fullscreen')));
    await settle(tester);
  }

  String routeToolLabel(WidgetTester tester) {
    final routeTool = find.byKey(const ValueKey('player-route'));
    return tester
        .widget<Text>(
          find.descendant(of: routeTool, matching: find.byType(Text)).first,
        )
        .data!;
  }

  testWidgets('route tool opens the side panel and switches line by index', (
    tester,
  ) async {
    final (repository, player) = await mount(tester);

    // 竖屏下行宽度紧张，线路按钮固定显示「播放源」，具体线路名在面板里。
    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    // 进竖屏全屏：内嵌紧凑形态按现行定调藏掉线路/倍速/选集三颗大按钮。
    await enterPortraitFullscreen(tester);
    final routeTool = find.byKey(const ValueKey('player-route'));
    expect(routeTool, findsOneWidget);
    expect(routeToolLabel(tester), '播放源');

    // 点线路按钮从右侧滑出面板：列出全部线路，当前项以主色高亮。
    await tester.tap(routeTool);
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-side-panel')), findsOneWidget);
    expect(find.text('无水印资源'), findsOneWidget); // 仅在面板里
    expect(find.text('索尼资源'), findsOneWidget);
    // 选中项以主题主色高亮（glass_menu 的 checked 语义）
    final primaryColor = ThemeData.dark().colorScheme.primary;
    final highlighted = tester.widgetList<Text>(find.text('无水印资源')).any(
      (text) => text.style?.color == primaryColor,
    );
    expect(highlighted, isTrue);

    // 点选「索尼资源」：先等菜单关闭动画（320ms），再走选链路
    await tester.tap(find.text('索尼资源'));
    // 选线经两阶段加载（解析→定格→换源），等加载遮罩结束、控件再现
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(repository.selectCalls, 1);
    expect(repository.selectedRoutes, [1]);
    // 换源已发生：第二次 open（选线换源），旧会话已释放、只留新会话
    expect(player.opened.length, 2);
    expect(repository.active.length, 1);
    // 真名渲染逻辑（routeLabels[index]）已由初始「无水印资源」断言覆盖；
    // 控制栏在换源加载期不上线，这里不断言其重现。
    expect(repository.active.single, isNot('route-0'));

    await unmount(tester, player);
    expect(repository.active, isEmpty);
  });

  testWidgets('当前线路是最后一条时，线路入口仍在且能切回第一条', (tester) async {
    // 回归：入口可用性旧口径按 hasAlternative（=「当前不是最后一条」）判定，
    // 处在最后一条时线路按钮整个消失，用户再也切不回来。
    final routes = RouteRepository()..initialRouteIndex = 1;
    final (repository, player) = await mount(tester, routes: routes);

    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    await enterPortraitFullscreen(tester);
    expect(
      find.byKey(const ValueKey('player-route')),
      findsOneWidget,
      reason: '线路数 ≥2 时入口必须存在，与当前线路索引无关',
    );

    await tester.tap(find.byKey(const ValueKey('player-route')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-side-panel')), findsOneWidget);

    // 面板列出全部线路，并能切回第一条。
    await tester.tap(find.text('无水印资源'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(repository.selectedRoutes, [0]);
    await unmount(tester, player);
  });

  testWidgets('官方源平铺、第三方源折叠成一条入口', (tester) async {
    final routes = RouteRepository()
      ..routeLabels = const ['官方线甲', '新浪资源', '官方线乙', '豆瓣资源']
      ..routeOfficial = const [true, false, true, false];
    final (repository, player) = await mount(tester, routes: routes);

    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    await enterPortraitFullscreen(tester);
    await tester.tap(find.byKey(const ValueKey('player-route')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);

    // 官方源全部平铺，第三方线折叠成一条入口。
    expect(find.text('官方源 · 2 条'), findsOneWidget);
    expect(find.text('官方线甲'), findsOneWidget);
    expect(find.text('官方线乙'), findsOneWidget);
    expect(find.text('第三方源 · 2 条'), findsOneWidget);
    expect(find.text('新浪资源'), findsNothing);
    expect(find.text('豆瓣资源'), findsNothing);

    // 点折叠入口展开二级列表，再点其中的第三方线才真正切线路。
    await tester.tap(find.text('第三方源 · 2 条'));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);
    expect(find.text('新浪资源'), findsOneWidget);
    expect(find.text('豆瓣资源'), findsOneWidget);

    await tester.tap(find.text('豆瓣资源'));
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    await settle(tester);
    expect(repository.selectCalls, 1);
    expect(repository.selectedRoutes, [3]);

    await unmount(tester, player);
  });

  testWidgets('画面比例与片头尾合在一块面板里，点选当场换档', (tester) async {
    final (repository, player) = await mount(tester);

    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-display')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-display')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);

    expect(find.byKey(const ValueKey('player-side-panel')), findsOneWidget);
    expect(find.text('画面比例'), findsOneWidget);
    expect(find.text('自适应'), findsOneWidget);
    expect(find.text('铺满裁剪'), findsOneWidget);
    // 比例与片头尾同框（用户定调：别再各占一颗按钮）。
    expect(find.text('片头尾'), findsOneWidget);
    expect(find.byKey(const ValueKey('skip-intro-set')), findsOneWidget);

    Color? chipColor(String label) {
      final box = tester.widget<Container>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      return (box.decoration as BoxDecoration?)?.color;
    }

    // 默认「自适应」是选中态：白底黑字。
    expect(chipColor('自适应'), Colors.white);
    expect(chipColor('铺满裁剪'), isNot(Colors.white));

    await tester.tap(find.byKey(const ValueKey('display-fit-cover')));
    await settle(tester);
    expect(chipColor('铺满裁剪'), Colors.white, reason: '点选即换档，面板不关');
    expect(chipColor('自适应'), isNot(Colors.white));

    // 面板退场动画 180ms，多推几帧确保路由真正移除（settle 只走 120ms）。
    await tester.tap(find.byTooltip('关闭菜单'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byKey(const ValueKey('player-side-panel')), findsNothing);
    await unmount(tester, player);
  });
}
