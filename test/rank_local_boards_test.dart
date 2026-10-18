import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/rank_local_boards.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

String _day(int offset) {
  final now = DateTime.now();
  final date = DateTime(now.year, now.month, now.day).add(
    Duration(days: offset),
  );
  return '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

Drama _drama(
  String id, {
  String source = 'hongguo',
  String heat = '',
  String views = '',
  int episodes = 0,
  String category = '',
  String onlineDate = '',
}) => Drama(
  id: id,
  source: source,
  title: '剧 $id',
  heat: heat,
  views: views,
  episodes: episodes,
  category: category,
  onlineDate: onlineDate,
);

class ScheduleRepository extends FixtureRepository {
  final catalogRequests = <String>[];

  @override
  Future<List<RankingBoard>> rankingBoards() async => const [
    RankingBoard(id: 'hongguo-hot', source: 'hongguo', name: '总热播榜'),
  ];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    bool force = false,
  }) async {
    catalogRequests.add(source);
    return CatalogPage([
      _drama('a', heat: '3.4万', episodes: 20, category: '真人剧', onlineDate: _day(0)),
      _drama('b', heat: '9000', episodes: 12, category: '漫剧', onlineDate: _day(0)),
      _drama('c', views: '1.2亿', episodes: 30, onlineDate: _day(-1)),
      _drama('d', heat: '无热度', episodes: 5, onlineDate: _day(-2)),
      _drama('e', episodes: 8),
    ]);
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage(
    items: [RankingItem(1, _drama('rank', heat: '5万'))],
    page: page,
  );
}

void main() {
  group('parseOnlineDate', () {
    test('accepts the YYYY-MM-DD form produced by providerReleaseDate', () {
      expect(parseOnlineDate('2026-09-23'), DateTime(2026, 9, 23));
    });

    test('tolerates slashes and a trailing time part', () {
      expect(parseOnlineDate('2026/9/3'), DateTime(2026, 9, 3));
      expect(parseOnlineDate('2026-10-18 12:30:00'), DateTime(2026, 10, 18));
    });

    test('returns null for missing or impossible dates', () {
      expect(parseOnlineDate(''), isNull);
      expect(parseOnlineDate('   '), isNull);
      expect(parseOnlineDate('刚刚'), isNull);
      expect(parseOnlineDate('2026-02-31'), isNull);
      expect(parseOnlineDate('2026-13-01'), isNull);
    });
  });

  group('buildHeatBoard', () {
    test('sorts across sources by normalised heat', () {
      final board = buildHeatBoard([
        _drama('low', heat: '9000'),
        _drama('high', heat: '1.2亿'),
        _drama('mid', views: '3.4万'),
      ]);
      expect(board.map((item) => item.drama.id), ['high', 'mid', 'low']);
      expect(board.map((item) => item.rank), [1, 2, 3]);
    });

    test('drops entries without a parsable metric instead of guessing', () {
      final board = buildHeatBoard([
        _drama('none'),
        _drama('free', heat: '无热度'),
        _drama('ok', heat: '2万'),
      ]);
      expect(board.map((item) => item.drama.id), ['ok']);
    });

    test('de-duplicates by id and honours maxItems', () {
      final board = buildHeatBoard([
        _drama('same', heat: '1万'),
        _drama('same', heat: '1万'),
        _drama('other', heat: '2万'),
      ], maxItems: 1);
      expect(board.length, 1);
      expect(board.single.drama.id, 'other');
    });
  });

  group('buildScheduleGroups', () {
    test('groups by date, newest first, and labels recent days', () {
      final groups = buildScheduleGroups(
        [
          _drama('today', onlineDate: _day(0)),
          _drama('yesterday', onlineDate: _day(-1)),
          _drama('older', onlineDate: _day(-2)),
        ],
        isFollowing: (_) => false,
      );
      expect(groups.map((group) => group.label), ['今天', '昨天', '前天']);
    });

    test('falls back to a month/day label beyond three days', () {
      final groups = buildScheduleGroups(
        [_drama('old', onlineDate: _day(-10))],
        isFollowing: (_) => false,
      );
      expect(groups.single.label, isNot(startsWith('今')));
      expect(groups.single.label, contains('月'));
    });

    test('keeps followed series on top inside a day', () {
      final groups = buildScheduleGroups(
        [
          _drama('hot', heat: '9万', onlineDate: _day(0)),
          _drama('followed', heat: '100', onlineDate: _day(0)),
        ],
        isFollowing: (drama) => drama.id == 'followed',
      );
      expect(
        groups.single.items.map((item) => item.drama.id),
        ['followed', 'hot'],
      );
    });

    test('ignores entries outside the window and without a date', () {
      final groups = buildScheduleGroups(
        [
          _drama('future', onlineDate: _day(2)),
          _drama('undated'),
          _drama('fresh', onlineDate: _day(0)),
        ],
        isFollowing: (_) => false,
      );
      expect(groups.length, 1);
      expect(groups.single.items.single.drama.id, 'fresh');
    });

    test('groups carry their own count for the header', () {
      final groups = buildScheduleGroups(
        [
          _drama('a', onlineDate: _day(0)),
          _drama('b', onlineDate: _day(0)),
        ],
        isFollowing: (_) => false,
      );
      expect(groups.single.total, 2);
    });
  });

  group('label helpers', () {
    test('match the wording used by 云追视频', () {
      final drama = _drama('x', episodes: 24, category: '真人剧');
      expect(episodeCountLabel(drama), '共 24 部');
      expect(updateLabel(drama), '更新至 24 集');
      expect(categoryTagLabel(drama), '[真人剧]');
      expect(categoryTagLabel(_drama('y')), '');
      expect(episodeCountLabel(_drama('y')), '');
      expect(updateLabel(_drama('y')), '');
    });

    test('rankingMetricLabel falls back from metric to heat to episodes', () {
      final withMetric = RankingItem(1, _drama('a'), metric: '热度 8万');
      expect(rankingMetricLabel(withMetric), '热度 8万');
      expect(rankingMetricLabel(RankingItem(1, _drama('b', heat: '7万'))), '7万');
      expect(rankingMetricLabel(RankingItem(1, _drama('c', episodes: 6))), '共 6 部');
    });

    test('bare play counts are rewritten with 万/亿 units', () {
      expect(
        rankingMetricLabel(RankingItem(1, _drama('a', views: '3864880'))),
        '386.5万 热度',
      );
      expect(
        rankingMetricLabel(RankingItem(1, _drama('b', heat: '120000000'))),
        '1.2亿 热度',
      );
      expect(
        rankingMetricLabel(RankingItem(1, _drama('c', views: '1,234'))),
        '1234 热度',
      );
      // 站源已格式化的文案保持原样，不再二次换算。
      expect(rankingMetricLabel(RankingItem(1, _drama('d', heat: '9200万'))), '9200万');
      expect(isBareNumber('3.4万'), isFalse);
      expect(isBareNumber(''), isFalse);
      expect(isBareNumber(' 3864880 '), isTrue);
    });
  });

  group('榜单页的跨源本地榜', () {
    Future<int> mountRankings(
      WidgetTester tester,
      ScheduleRepository repository,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      SharedPreferences.setMockInitialValues({});
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.setSource('hongguo');
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();
      // 榜单入口收进「⋯ → 榜单」。
      await tester.tap(find.byTooltip('更多'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('榜单').last);
      await tester.pumpAndSettle();
      return repository.catalogRequests.length;
    }

    Future<void> openLocal(WidgetTester tester, String label) async {
      final chip = find.text(label);
      await tester.ensureVisible(chip);
      await tester.tap(chip);
      await tester.pumpAndSettle();
    }

    testWidgets('进榜页不打扰站源榜，也不为本地榜预取目录', (tester) async {
      final repository = ScheduleRepository();
      final baseline = await mountRankings(tester, repository);
      expect(baseline, 1, reason: '只有首页那一次目录请求');
      expect(find.text('总热播榜'), findsOneWidget);
      expect(find.text('实时热度'), findsOneWidget);
      expect(find.text('排期表'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('排期表按日期分组并展示集数与分类标签', (tester) async {
      final repository = ScheduleRepository();
      final baseline = await mountRankings(tester, repository);
      await openLocal(tester, '排期表');

      expect(repository.catalogRequests.length, baseline + 1);
      expect(find.text('今天'), findsOneWidget);
      expect(find.text('更新 2 部'), findsOneWidget);
      expect(find.text('[真人剧]'), findsOneWidget);
      expect(find.text('共 20 部'), findsOneWidget);
      expect(find.text('更新至 20 集'), findsOneWidget);
      // 无 onlineDate 的条目不进排期表
      expect(find.text('剧 e'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('实时热度榜跨源按归一化热度排序并剔除无热度条目',
        (tester) async {
      final repository = ScheduleRepository();
      final baseline = await mountRankings(tester, repository);
      await openLocal(tester, '实时热度');
      expect(repository.catalogRequests.length, baseline + 1);

      final keys = tester
          .widgetList<InkWell>(find.byType(InkWell))
          .map((tile) => tile.key)
          .whereType<ValueKey<String>>()
          .map((key) => key.value)
          .where((key) => key.startsWith('rank-'))
          .toList();
      expect(keys, ['rank-1-c', 'rank-2-a', 'rank-3-b']);
      expect(find.text('剧 d'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
