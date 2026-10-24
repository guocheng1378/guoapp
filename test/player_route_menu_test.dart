import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
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
  }

  String routeToolLabel(WidgetTester tester) {
    final routeTool = find.byKey(const ValueKey('player-route'));
    return tester
        .widget<Text>(
          find.descendant(of: routeTool, matching: find.byType(Text)).first,
        )
        .data!;
  }

  testWidgets('route tool shows the real line name and the menu switches by index', (
    tester,
  ) async {
    final (repository, player) = await mount(tester);

    // 控制栏唤出后线路按钮显示当前线路真名（routeIndex=0 → 无水印资源）
    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    final routeTool = find.byKey(const ValueKey('player-route'));
    expect(routeTool, findsOneWidget);
    expect(routeToolLabel(tester), '无水印资源');

    // 点线路按钮弹玻璃菜单：列出全部线路，当前项带对勾
    await tester.tap(routeTool);
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    expect(find.text('无水印资源'), findsNWidgets(2)); // 按钮 + 菜单
    expect(find.text('索尼资源'), findsOneWidget); // 仅菜单
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

  testWidgets('官方源平铺、第三方源折叠成一条入口', (tester) async {
    final routes = RouteRepository()
      ..routeLabels = const ['官方线甲', '新浪资源', '官方线乙', '豆瓣资源']
      ..routeOfficial = const [true, false, true, false];
    final (repository, player) = await mount(tester, routes: routes);

    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    await tester.tap(find.byKey(const ValueKey('player-route')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);

    // 官方源全部平铺（官方线甲既是按钮文字也是菜单项），第三方线折叠。
    expect(find.text('官方源 · 2 条'), findsOneWidget);
    expect(find.text('官方线甲'), findsNWidgets(2));
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

  testWidgets('画面比例可切换，选中项在菜单里高亮打勾', (tester) async {
    final (repository, player) = await mount(tester);

    await tester.tap(find.byKey(const ValueKey('player-gesture-surface')));
    await settle(tester);
    expect(find.byKey(const ValueKey('player-display')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('player-display')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);

    expect(find.text('画面比例'), findsOneWidget);
    expect(find.text('自适应'), findsOneWidget);
    expect(find.text('铺满裁剪'), findsOneWidget);
    // 默认档位「自适应」是选中态（主色文字 + 对勾）。
    final primary = Theme.of(
      tester.element(find.text('自适应')),
    ).colorScheme.primary;
    expect(tester.widget<Text>(find.text('自适应')).style?.color, primary);

    await tester.tap(find.text('铺满裁剪'));
    await tester.pump(const Duration(milliseconds: 400));
    await settle(tester);

    // 重开菜单：选中态已经跟到「铺满裁剪」。
    await tester.tap(find.byKey(const ValueKey('player-display')));
    await tester.pump(const Duration(milliseconds: 250));
    await settle(tester);
    final primaryAfter = Theme.of(
      tester.element(find.text('铺满裁剪')),
    ).colorScheme.primary;
    expect(tester.widget<Text>(find.text('铺满裁剪')).style?.color, primaryAfter);
    expect(
      tester.widget<Text>(find.text('自适应')).style?.color,
      isNot(primaryAfter),
    );

    await tester.tapAt(const Offset(200, 820));
    await settle(tester);
    await unmount(tester, player);
  });
}
