import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/related_dramas.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// 简介页的「相关推荐」（2026-10-25 用户问「简介页没有推荐的剧吗」）：
// 仓库里唯一的推荐接口 repository.recommendations(genre) 是红果专用且与本剧
// 无关，所以这里按 catalog 分级降级取同类内容。运行需带 ALL_SOURCES=true。

const _self = Drama(
  id: 'dongpiandi:9001',
  source: 'dongpiandi',
  title: '合成短剧甲',
  episodes: 12,
  category: '短剧',
  tags: ['都市', '甜宠'],
  releaseStatus: 'ongoing',
);

final _neighbours = <Drama>[
  _self,
  const Drama(
    id: 'dongpiandi:9002',
    source: 'dongpiandi',
    title: '同类剧乙',
    episodes: 30,
    category: '短剧',
  ),
  const Drama(
    id: 'dongpiandi:9003',
    source: 'dongpiandi',
    title: '同类剧丙',
    episodes: 8,
    category: '短剧',
  ),
  // 别的站的剧：即使在结果里也不能进条（点开会有源不可用问题）。
  FixtureRepository.free,
];

class RailRepository extends FixtureRepository {
  RailRepository(
    this.items, {
    this.failing = const <String>{},
    this.emptyRounds = 0,
  });

  final List<Drama> items;
  // 命中这些 query/category 的请求直接失败，用来验证降级链。
  final Set<String> failing;
  // 前 N 次请求一律返回空：模拟「首轮全空 → 800ms 后兜底重试」的真机情形。
  final int emptyRounds;
  int calls = 0;
  // 不叫 categories：AppRepository 有同名方法，子类字段会撞。
  final kindRequests = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async {
    requests.add(source);
    kindRequests.add(category);
    if (query.isNotEmpty) queries.add(query);
    if (failing.contains(category) || failing.contains(query)) {
      throw AppFailure('合成网络错误');
    }
    calls++;
    if (calls <= emptyRounds) {
      return CatalogPage(const <Drama>[], page: page, hasMore: false);
    }
    return CatalogPage(items, page: page, hasMore: false);
  }
}

Future<void> frames(WidgetTester tester, {int count = 24}) async {
  // 详情页有循环指示动画，pumpAndSettle 会一直等到超时。
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

class _NavSpy extends NavigatorObserver {
  final pushed = <String>[];
  int pops = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.runtimeType.toString());
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pops++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore() async {
    // 默认档案受保护 + forceLogin 缺省开启 → store 自锁，简介页只渲染
    // 「当前用户无权访问」。这里显式关掉强制登录。
    SharedPreferences.setMockInitialValues(<String, Object>{
      'forceLogin': false,
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }


  Future<RailRepository> pumpDetail(
    WidgetTester tester,
    RailRepository repository, {
    _NavSpy? spy,
    Drama self = _self,
  }) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
    final store = await localStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        navigatorObservers: spy == null ? const [] : [spy],
        home: DetailScreen(
          drama: self,
          repository: repository,
          store: store,
        ),
      ),
    );
    await frames(tester);
    return repository;
  }

  testWidgets('简介页渲染相关推荐，排除自己与其它站的剧', (tester) async {
    final repository = await pumpDetail(tester, RailRepository(_neighbours));

    expect(find.text('相关推荐'), findsOneWidget);
    // 自己与别的站的剧都不进条（自身的标题在页面标题/AppBar 里另有两处，
    // 所以按卡片 key 断言，别数文本）。
    expect(find.byKey(const ValueKey('related-card-dongpiandi:9001')), findsNothing);
    expect(find.byKey(const ValueKey('related-card-hongguo:100')), findsNothing);
    expect(find.byKey(const ValueKey('related-card-dongpiandi:9002')), findsOneWidget);
    expect(find.byKey(const ValueKey('related-card-dongpiandi:9003')), findsOneWidget);
    expect(find.text('同类剧乙'), findsOneWidget);
    expect(find.text('同类剧丙'), findsOneWidget);
    // 第一条就走站点 content_kind，不是拿中文去搜索。
    expect(repository.kindRequests, <String>['short_drama']);
    expect(repository.queries, isEmpty);
  });

  testWidgets('点推荐卡推它自己的简介页', (tester) async {
    final spy = _NavSpy();
    final repo = await pumpDetail(tester, RailRepository(_neighbours), spy: spy);
    expect(find.byType(DetailScreen), findsOneWidget);

    // 推荐卡在简介区末尾，落在首屏之外：先滚进视口再 tap。
    final card = find.byKey(const ValueKey('related-card-dongpiandi:9002'));
    await tester.ensureVisible(card);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(card);
    await frames(tester);

    // skipOffstage: false —— 转场结束后旧页面会被标记 offstage，默认 finder
    // 会把前一个 DetailScreen 跳过，数出来永远只有 1 个。
    expect(
      find.byType(DetailScreen, skipOffstage: false),
      findsNWidgets(2),
    );
    expect(spy.pushed.length, 2);
    expect(spy.pops, 0);
    // 新开的那一页会自己拉详情。
    expect(repo.detailCalls, 2);
  });

  testWidgets('站点 kind 拉不到时降级到关键词', (tester) async {
    final repository = await pumpDetail(
      tester,
      RailRepository(_neighbours, failing: <String>{'short_drama'}),
    );

    expect(find.text('同类剧乙'), findsOneWidget);
    expect(repository.kindRequests, <String>['short_drama', '']);
    expect(repository.queries, <String>['短剧']);
  });

  testWidgets('卡片把对应的剧回传给调用方', (tester) async {
    final opened = <Drama>[];
    final store = await localStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: Scaffold(
          body: SingleChildScrollView(
            child: RelatedDramaRail(
              repository: RailRepository(_neighbours),
              store: store,
              drama: _self,
              onOpen: opened.add,
            ),
          ),
        ),
      ),
    );
    await frames(tester);
    await tester.tap(find.byKey(const ValueKey('related-card-dongpiandi:9002')));
    await tester.pump(const Duration(milliseconds: 100));

    expect(opened.map((drama) => drama.title), <String>['同类剧乙']);
  });

  testWidgets('首轮候选全空时兜底重试一次再显示', (tester) async {
    // 四级候选（kind / 分类 / 两个标签）四次请求全空，第五次是 800ms 后的
    // 兜底重试 —— 真机上被并发读取排队或 cancelCatalog 掐掉时就是这条路径。
    await pumpDetail(tester, RailRepository(_neighbours, emptyRounds: 4));

    expect(find.byKey(const ValueKey('related-card-dongpiandi:9002')), findsOneWidget);
    expect(find.text('相关推荐'), findsOneWidget);
  });

  testWidgets('全拉不到时整条隐藏，不占简介页版面', (tester) async {
    final repository = await pumpDetail(tester, RailRepository(const <Drama>[]));

    expect(find.text('相关推荐'), findsNothing);
    // 四级候选全试过：kind / 分类 / 两个标签（「全部」兜底也在这条链上）。
    expect(repository.requests.length, greaterThanOrEqualTo(4));
    expect(find.byType(RelatedDramaRail), findsOneWidget);
  });

  testWidgets('同系列优先：剥掉第N部主干搜索，不先走分类', (tester) async {
    final repository = await pumpDetail(
      tester,
      RailRepository(_neighbours),
      self: const Drama(
        id: 'dongpiandi:9001',
        source: 'dongpiandi',
        title: '长公主驾到 第一部',
        episodes: 12,
        category: '短剧',
      ),
    );

    expect(find.byKey(const ValueKey('related-card-dongpiandi:9002')), findsOneWidget);
    // 第一条（也是唯一一条）请求是同系列：搜剧名主干。
    expect(repository.queries, <String>['长公主驾到']);
    expect(repository.kindRequests.contains('short_drama'), isFalse);
  });

  testWidgets('同主演：首个主演当搜索词，排在分类链之前', (tester) async {
    final repository = await pumpDetail(
      tester,
      RailRepository(_neighbours),
      self: const Drama(
        id: 'dongpiandi:9001',
        source: 'dongpiandi',
        title: '合成短剧甲',
        episodes: 12,
        category: '短剧',
        actors: <String>['陆之屿', '白桃'],
      ),
    );

    expect(find.byKey(const ValueKey('related-card-dongpiandi:9002')), findsOneWidget);
    expect(repository.queries, <String>['陆之屿']);
    expect(repository.kindRequests.contains('short_drama'), isFalse);
  });
}
