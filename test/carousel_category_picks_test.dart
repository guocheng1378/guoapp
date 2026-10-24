import 'package:duanju_app/featured_catalog.dart';
import 'package:duanju_app/home_carousel.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 同时提供视频类（豆瓣）/黄果类（黄豆）/短剧类（红果）榜，用于验证
/// loadCategoryRankingPicks 按锚点大类选榜：视频→豆瓣、短剧→红果、黄果→黄果。
class CategoryBoardsRepository extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'douban-tv-domestic', source: 'douban', name: '近期热门国产剧'),
    RankingBoard(id: 'huangdou-hot', source: 'huangdou', name: '黄豆热播榜'),
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '红果热播榜'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    final source = RankingBoard.sourceForID(board);
    return RankingPage(
      items: [
        for (var i = 1; i <= 3; i++)
          RankingItem(
            i,
            Drama(id: '$board:$i', source: source, title: '榜单项$i'),
            // 站源榜每条都带 metric（热度/评分），对齐榜单页 _rankingMetricLabel
            // 全量展示 item.metric 的口径。
            metric: '热度$i',
          ),
      ],
      page: 1,
      hasMore: false,
    );
  }
}

/// 只提供豆瓣榜：用于验证「锚点大类无对应榜」时静默返回空（轮播走回退）。
class DoubanOnlyRepository extends FixtureRepository {
  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'douban-tv-domestic', source: 'douban', name: '近期热门国产剧'),
  ];

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async =>
      RankingPage(
        items: [
          RankingItem(
            1,
            Drama(id: '$board:1', source: 'douban', title: '豆瓣剧'),
          ),
        ],
        page: 1,
        hasMore: false,
      );
}

Future<LocalStore> _store() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  setUp(() {
    clearCategoryPicksCache();
    clearDoubanPicksCache();
  });

  test('视频类锚点走豆瓣选片，徽章标「豆瓣」', () async {
    final store = await _store();
    final picks = await loadCategoryRankingPicks(
      DoubanOnlyRepository(),
      store,
      SourceSite.byId('douban')!,
    );
    expect(picks, isNotEmpty);
    expect(picks.every((p) => p.boardLabel == '豆瓣'), isTrue);
    expect(picks.first.drama.source, 'douban');
  });

  test('短剧类锚点播红果榜（非豆瓣源、带红果榜徽章）', () async {
    final store = await _store();
    final picks = await loadCategoryRankingPicks(
      CategoryBoardsRepository(),
      store,
      SourceSite.byId('hongguo')!,
    );
    expect(picks, isNotEmpty);
    expect(picks.length, 3);
    // 条目来自红果（真实源），不是豆瓣。
    expect(picks.every((p) => p.drama.source == 'hongguo'), isTrue);
    // 徽章标明榜单来源，且不是「豆瓣」。
    expect(picks.every((p) => p.boardLabel.isNotEmpty && p.boardLabel != '豆瓣'),
        isTrue);
    expect(picks.first.boardLabel, '红果榜');
    // 与榜单页同口径：非豆瓣轮播卡也携带 item.metric 热度/评分摘要。
    expect(picks.every((p) => p.tag.isNotEmpty), isTrue);
  });

  test('黄果类锚点播黄果榜（不再纯回退）', () async {
    final store = await _store();
    final picks = await loadCategoryRankingPicks(
      CategoryBoardsRepository(),
      store,
      SourceSite.byId('huangdou')!,
    );
    expect(picks, isNotEmpty);
    expect(picks.every((p) => p.drama.source == 'huangdou'), isTrue);
    expect(picks.first.boardLabel, '黄豆榜');
    // 与榜单页同口径：黄果类轮播卡也携带 item.metric 热度摘要。
    expect(picks.every((p) => p.tag.isNotEmpty), isTrue);
  });

  test('锚点大类无对应榜时静默返回空（轮播走回退）', () async {
    final store = await _store();
    // 仅豆瓣榜的仓库；短剧类锚点找不到红果榜 → 空。
    final picks = await loadCategoryRankingPicks(
      DoubanOnlyRepository(),
      store,
      SourceSite.byId('hongguo')!,
    );
    expect(picks, isEmpty);
  });

  testWidgets('短剧类锚点轮播渲染红果榜徽章与榜单项', (tester) async {
    final store = await _store();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            store: store,
            repository: CategoryBoardsRepository(),
            onOpen: (_) {},
            fallbackItems: const [],
            anchor: SourceSite.byId('hongguo')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 榜单来源徽章与榜单项标题都应上卡。
    expect(find.text('红果榜'), findsWidgets);
    expect(find.text('榜单项1'), findsOneWidget);
    // 与榜单页同款：来源徽章旁再显示 item.metric 热度徽章。
    expect(find.text('热度1'), findsWidgets);
  });

  testWidgets('黄果类锚点轮播渲染黄果榜徽章（非纯回退）', (tester) async {
    final store = await _store();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            store: store,
            repository: CategoryBoardsRepository(),
            onOpen: (_) {},
            fallbackItems: const [],
            anchor: SourceSite.byId('huangdou')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('黄豆榜'), findsWidgets);
    expect(find.text('榜单项1'), findsOneWidget);
  });
}
