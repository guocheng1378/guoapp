import 'package:duanju_app/app_build.dart' show allSourcesEnabled;
import 'package:duanju_app/featured_catalog.dart';
import 'package:duanju_app/home_carousel.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  RankingPage doubanBoard() => RankingPage(
    items: [
      RankingItem(
        1,
        const Drama(
          id: 'douban:1',
          source: 'douban',
          title: '流浪地球',
          category: '科幻',
        ),
        metric: '8.0分 · 100万人评价',
      ),
    ],
    page: 1,
  );

  Widget carousel({
    required LocalStore local,
    required FixtureRepository repository,
    ValueKey<String>? key,
  }) => MaterialApp(
    home: Scaffold(
      body: HomeCarousel(
        key: key,
        store: local,
        repository: repository,
        onOpen: (_) {},
        fallbackItems: const [FixtureRepository.free],
        anchor: SourceSite.byId('dytt')!,
      ),
    ),
  );

  testWidgets('豆瓣榜条目直接上轮播第一位，点击原样上抛（全源版）', (tester) async {
    clearDoubanPicksCache();
    final repository = FixtureRepository()..rankingPage = doubanBoard();
    Drama? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            store: await store(),
            repository: repository,
            onOpen: (drama) => opened = drama,
            fallbackItems: const [FixtureRepository.free],
            anchor: SourceSite.byId('dytt')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 豆瓣卡在轮播第一位：蓝色豆瓣徽章 + 评分摘要（metric 首段）。
    expect(find.text('流浪地球'), findsOneWidget);
    expect(find.text('豆瓣'), findsOneWidget);
    expect(find.text('8.0分'), findsOneWidget);
    expect(find.text('100万人评价'), findsNothing);
    // 不足 5 张用当前源条目补位（PageView 相邻页隐式构建，补位卡可见）。
    expect(find.text('测试短剧'), findsWidgets);
    // 直出榜条目不再搜站源：全库零搜索请求。
    expect(repository.queries, isEmpty);
    expect(repository.requests, isEmpty);
    // 点击原样上抛豆瓣条目（同名搜索跳转由 home_screen 分流承担）。
    await tester.tap(find.text('流浪地球'));
    expect(opened?.id, 'douban:1');
  }, skip: !allSourcesEnabled);

  testWidgets('榜单为空静默回退，当日缓存跨实例不重拉（全源版）', (tester) async {
    clearDoubanPicksCache();
    final repository = FixtureRepository()
      ..rankingPage = const RankingPage(items: [], page: 1);
    final local = await store();
    await tester.pumpWidget(
      carousel(local: local, repository: repository, key: const ValueKey('a')),
    );
    await tester.pumpAndSettle();
    expect(find.text('豆瓣'), findsNothing);
    expect(find.text('流浪地球'), findsNothing);
    // 榜单空 = 纯回退：当前源条目补满轮播。
    expect(find.text('测试短剧'), findsWidgets);
    // 重挂一个轮播实例：命中「当天+锚点已拉过」缓存——榜单零请求。
    await tester.pumpWidget(
      carousel(local: local, repository: repository, key: const ValueKey('b')),
    );
    await tester.pumpAndSettle();
    expect(repository.rankingsCalls, 1);
  }, skip: !allSourcesEnabled);

  testWidgets('黄果类锚点不拉豆瓣榜，纯回退自家条目', (tester) async {
    clearDoubanPicksCache();
    final repository = FixtureRepository()..rankingPage = doubanBoard();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            store: await store(),
            repository: repository,
            onOpen: (_) {},
            fallbackItems: const [FixtureRepository.free],
            anchor: SourceSite.byId('huangdou')!,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 零请求：榜单都不拉，轮播整体回退。
    expect(repository.rankingsCalls, 0);
    expect(find.text('豆瓣'), findsNothing);
    expect(find.text('流浪地球'), findsNothing);
    expect(find.text('测试短剧'), findsWidgets);
  });

  testWidgets('单源变体同样直出豆瓣榜卡（红果鉴）', (tester) async {
    clearDoubanPicksCache();
    final repository = FixtureRepository()..rankingPage = doubanBoard();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeCarousel(
            store: await store(),
            repository: repository,
            onOpen: (_) {},
            fallbackItems: const [FixtureRepository.free],
            anchor: SourceSite.hongguo,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // 选片不再依赖同类站源：单源变体轮播照样播豆瓣榜条目 + 补位。
    expect(find.text('流浪地球'), findsOneWidget);
    expect(find.text('豆瓣'), findsOneWidget);
    expect(find.text('测试短剧'), findsWidgets);
  }, skip: allSourcesEnabled);

  test('黄果类锚点不走精选位，无论开关状态', () async {
    SharedPreferences.setMockInitialValues({});
    final local = await SharedPreferences.getInstance();
    final localStore = LocalStore(local);
    final huangdou = SourceSite.byId('huangdou')!;
    expect(pickFeaturedSource(localStore, huangdou), isEmpty);
    expect(featuredSources(localStore, huangdou), isEmpty);
    expect(doubanPicksFill(HomeCarousel.maxItems, huangdou), isFalse);
  });
}
