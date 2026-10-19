import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:duanju_app/rankings_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 覆盖视频类（豆瓣）/黄果类（黄豆）/成人类（155）三类榜，验证
/// 「黄果类与成人类榜单默认整组隐藏、关于卡解锁后显示」的口径
/// （与站源菜单/站源管理页同源）。
class HiddenBoardsRepository extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'douban-realtime', source: 'douban', name: '实时热门电影'),
    RankingBoard(id: 'huangdou-hot', source: 'huangdou', name: '黄豆热播榜'),
    RankingBoard(id: 'zy155-hot', source: 'zy155', name: '成人精选榜'),
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
  Future<LocalStore> mount(WidgetTester tester, {bool unlocked = false}) async {
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
        ),
      ),
    );
    await tester.pumpAndSettle();
    return store;
  }

  testWidgets('未解锁时黄果类/成人类榜单整组隐藏', (tester) async {
    await mount(tester);
    // 分类行只剩视频类一组（单分类不渲染分类行），黄果/成人类不出现。
    expect(find.text('黄果类'), findsNothing);
    expect(find.text('成人类'), findsNothing);
    expect(find.text('黄豆热播榜'), findsNothing);
    expect(find.text('成人精选榜'), findsNothing);
    // 可见类（视频类）的榜照常展示。
    expect(find.text('实时热门电影'), findsOneWidget);
    expect(find.text('榜单条目'), findsOneWidget);
  });

  testWidgets('解锁后黄果类/成人类榜单显示', (tester) async {
    await mount(tester, unlocked: true);
    // 三分类齐备 → 分类行出现。
    expect(find.text('黄果类'), findsOneWidget);
    expect(find.text('成人类'), findsOneWidget);
    expect(find.text('实时热门电影'), findsOneWidget);
  });

  testWidgets('初始分类落在被隐藏类时回落到第一个可见分类', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: RankingsScreen(
          repository: HiddenBoardsRepository(),
          store: store,
          // 从黄果类站源打开榜单页：未解锁时该类不可见，应回落视频类。
          initialCategory: 'huangguo',
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('黄果类'), findsNothing);
    expect(find.text('实时热门电影'), findsOneWidget);
    expect(find.text('榜单条目'), findsOneWidget);
  });
}
