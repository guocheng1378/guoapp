import 'package:duanju_app/fog_tuning.dart';
import 'package:duanju_app/glass.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 覆盖视频类（豆瓣）/黄果类（黄豆）/成人类（zy155）/短剧类（红果）榜，
/// 验证榜单页强隔离：只展示主页当前大类（initialCategory）的主榜，其他类
/// 一律不出现、也不提供切换入口；黄果类/成人类未解锁时整组隐藏，且不回落。
class HiddenBoardsRepository extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'douban-realtime', source: 'douban', name: '实时热门电影'),
    RankingBoard(id: 'huangdou-hot', source: 'huangdou', name: '黄豆热播榜'),
    RankingBoard(id: 'zy155-hot', source: 'zy155', name: '成人精选榜'),
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '红果热播榜'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage(
    items: [
      RankingItem(
        1,
        Drama(id: '$board:1', source: board.split('-').first, title: '榜单条目'),
      ),
    ],
    page: 1,
    hasMore: false,
  );
}

void main() {
  Future<LocalStore> mount(
    WidgetTester tester, {
    bool unlocked = false,
    String initialCategory = 'video',
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    if (unlocked) {
      await store.setRestrictedUnlocked(true);
    }
    await tester.pumpWidget(
      MaterialApp(
        home: RankingsScreen(
          repository: HiddenBoardsRepository(),
          store: store,
          initialCategory: initialCategory,
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('从视频类进只显示视频类榜，不出现其他类', (tester) async {
    await mount(tester, initialCategory: 'video');
    // 当前类（视频类）主榜照常展示。
    expect(find.text('实时热门电影'), findsOneWidget);
    expect(find.text('榜单条目'), findsOneWidget);
    // 强隔离：其他类榜一律不出现，也不提供切换入口（分类行单类隐藏）。
    expect(find.text('黄豆热播榜'), findsNothing);
    expect(find.text('成人精选榜'), findsNothing);
    expect(find.text('红果热播榜'), findsNothing);
    expect(find.text('黄果类'), findsNothing);
  });

  testWidgets('从短剧类进只显示短剧类榜，不混入视频/黄果类', (tester) async {
    await mount(tester, initialCategory: 'shortDrama');
    expect(find.text('红果热播榜'), findsOneWidget);
    expect(find.text('榜单条目'), findsOneWidget);
    // 视频类/黄果类榜不出现。
    expect(find.text('实时热门电影'), findsNothing);
    expect(find.text('黄豆热播榜'), findsNothing);
  });

  testWidgets('未解锁时黄果类/成人类不暴露', (tester) async {
    await mount(tester, initialCategory: 'video');
    expect(find.text('黄果类'), findsNothing);
    expect(find.text('成人类'), findsNothing);
    expect(find.text('黄豆热播榜'), findsNothing);
    expect(find.text('成人精选榜'), findsNothing);
  });

  testWidgets('解锁后从黄果类进只显示黄果类榜', (tester) async {
    await mount(tester, unlocked: true, initialCategory: 'huangguo');
    expect(find.text('黄豆热播榜'), findsOneWidget);
    // 其他类仍隔离。
    expect(find.text('成人精选榜'), findsNothing);
    expect(find.text('实时热门电影'), findsNothing);
  });

  testWidgets('初始类落在未解锁受限类时不回落、展示空态', (tester) async {
    await mount(tester, initialCategory: 'huangguo');
    // 不回落到视频类，其他类榜不出现。
    expect(find.text('实时热门电影'), findsNothing);
    expect(find.text('黄豆热播榜'), findsNothing);
    expect(find.text('黄果类'), findsNothing);
    // 当前类无可见榜 → 空态。
    expect(find.text('暂无榜单内容'), findsOneWidget);
  });

  testWidgets('主页同款雾化接线：定高雾带 + 顶栏雾玻璃岛，正档延伸/负档收到 0', (
    tester,
  ) async {
    await mount(tester, initialCategory: 'video');
    // 手机分支与主页同构：雾带随筛选行一起钉进吸顶头（定高 ×1），
    // 顶栏标题/刷新各自包雾玻璃岛。
    expect(find.byType(TopFog), findsOneWidget);
    expect(find.byType(FogPill), findsNWidgets(2));
    final backup = FogTuningStore.state.value;
    addTearDown(() => FogTuningStore.state.value = backup);
    // 正档：雾面高度 +30 → 雾带 = topInset(56) + 吸顶行区(单行 56+10) + 30
    // （强隔离单类场景分类/类型行隐藏，仅榜单行吸顶，列表从其下穿过）。
    FogTuningStore.state.value = backup.copyWith(fogHeight: 30);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TopFog)).height, closeTo(152, 0.01));
    // 极端负档收到 0 不崩（clamp≥0 防负高度断言）。
    FogTuningStore.state.value = backup.copyWith(fogHeight: -500);
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(TopFog)).height, 0);
  });
}
