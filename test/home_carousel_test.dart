import 'package:duanju_app/featured_catalog.dart';
import 'package:duanju_app/home_carousel.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 视频类锚点（电影天堂）：轮播走豆瓣选片。
final SourceSite videoAnchor = SourceSite.byId('dytt')!;
/// 短剧类锚点（红果）：轮播走「按类取榜」。
const SourceSite shortAnchor = SourceSite.hongguo;
/// 黄果类锚点（黄豆）：整体不拉榜，纯回退。
final SourceSite huangguoAnchor = SourceSite.byId('huangdou')!;

const Size phoneSize = Size(390, 844);
const Size desktopSize = Size(1280, 800);

/// 补位卡标题（= [FixtureRepository.free]）：榜单命中不足时用它补齐一列。
const String fallbackTitle = '测试短剧';

/// 豆瓣榜 fixture 条目：无播放链路，只能展示 + 点击原样上抛。
const Drama doubanDrama = Drama(
  id: 'douban:1',
  source: 'douban',
  title: '流浪地球',
  category: '科幻',
);

/// 红果自家榜 fixture 条目：带真实源，点按可直接播。
const Drama hongguoDrama = Drama(
  id: 'hongguo:300',
  source: 'hongguo',
  title: '红果热播剧',
  episodes: 12,
);

void main() {
  group('选片', () {
    testWidgets('视频类锚点直出豆瓣榜卡，点击原样上抛', (tester) async {
      final scene = await _mount(
        tester,
        anchor: videoAnchor,
        doubanRanking: _page([_item(doubanDrama, '8.0分 · 100万人评价')]),
      );
      // 豆瓣条目本身上卡：徽章标「豆瓣」，评分摘要只取首段。
      expect(find.text(doubanDrama.title), findsOneWidget);
      expect(find.text('豆瓣'), findsOneWidget);
      expect(find.text('8.0分'), findsOneWidget);
      expect(find.text('100万人评价'), findsNothing);
      // 不足一列用当前源条目补位（PageView 相邻页隐式构建）。
      expect(find.text(fallbackTitle), findsWidgets);
      // 直出榜条目不再搜站源：零目录/搜索请求。
      expect(scene.repository.requests, isEmpty);
      expect(scene.repository.queries, isEmpty);
      // 豆瓣条目无播放链路：原样上抛，由 home_screen 分流同名搜索。
      await tester.tap(find.text(doubanDrama.title));
      expect(scene.opened?.id, doubanDrama.id);
    });

    testWidgets('短剧类锚点播自家榜：来源徽章 + 榜单摘要', (tester) async {
      await _mount(
        tester,
        anchor: shortAnchor,
        boards: [_board('hongguo-hot', 'hongguo')],
        pages: {
          'hongguo-hot': _page([_item(hongguoDrama, '12万热度')]),
        },
      );
      expect(find.text(hongguoDrama.title), findsOneWidget);
      expect(find.text('红果榜'), findsOneWidget);
      expect(find.text('12万热度'), findsOneWidget);
      expect(find.text(fallbackTitle), findsWidgets);
    });

    testWidgets('榜单为空静默回退当前源条目', (tester) async {
      await _mount(tester, anchor: videoAnchor, doubanRanking: _page(const []));
      expect(find.text('豆瓣'), findsNothing);
      expect(find.text(doubanDrama.title), findsNothing);
      expect(find.text(fallbackTitle), findsWidgets);
    });

    testWidgets('同一天同一锚点：换实例不重拉榜', (tester) async {
      final first = await _mount(
        tester,
        anchor: videoAnchor,
        doubanRanking: _page([_item(doubanDrama, '8.0分')]),
        key: const ValueKey('a'),
      );
      // 换一个轮播实例（不同 key 强制新建 State）：命中当天会话缓存。
      await _mount(
        tester,
        anchor: videoAnchor,
        repository: first.repository,
        reusePicksCache: true,
        key: const ValueKey('b'),
      );
      expect(first.repository.rankingsCalls, 1);
    });

    testWidgets('黄果类锚点不拉榜，整体回退', (tester) async {
      final scene = await _mount(
        tester,
        anchor: huangguoAnchor,
        doubanRanking: _page([_item(doubanDrama, '8.0分')]),
      );
      expect(scene.repository.rankingsCalls, 0);
      expect(find.text('豆瓣'), findsNothing);
      expect(find.text(doubanDrama.title), findsNothing);
      expect(find.text(fallbackTitle), findsWidgets);
    });
  });

  group('响应式布局', () {
    testWidgets('手机与桌面宽度都完整渲染且无溢出', (tester) async {
      for (final size in <Size>[phoneSize, desktopSize]) {
        await _mount(
          tester,
          anchor: videoAnchor,
          doubanRanking: _page([_item(doubanDrama, '8.0分')]),
          size: size,
        );
        final carousel = find.byKey(const ValueKey('home-carousel'));
        expect(carousel, findsOneWidget);
        // 轮播横铺满宽度、自身高度固定一档，不随视口变。
        final box = tester.getSize(carousel);
        expect(box.width, closeTo(size.width, 0.5));
        expect(box.height, 188);
        expect(find.text(doubanDrama.title), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });
  });

  group('精选位', () {
    test('黄果类锚点不走精选位，无论开关状态', () async {
      final local = await _newStore();
      expect(pickFeaturedSource(local, huangguoAnchor), isEmpty);
      expect(featuredSources(local, huangguoAnchor), isEmpty);
      expect(doubanPicksFill(HomeCarousel.maxItems, huangguoAnchor), isFalse);
    });
  });
}

/// 干净的本地配置：每个用例一份，避免站源开关之类互相污染。
Future<LocalStore> _newStore() async {
  SharedPreferences.setMockInitialValues({});
  return LocalStore(await SharedPreferences.getInstance());
}

/// 清空选片会话缓存（豆瓣 + 按类取榜），防止用例之间沿用同一天的命中。
void _clearPicksCache() {
  clearDoubanPicksCache();
  clearCategoryPicksCache();
}

RankingPage _page(List<RankingItem> items) => RankingPage(items: items, page: 1);

RankingItem _item(Drama drama, String metric) =>
    RankingItem(1, drama, metric: metric);

RankingBoard _board(String id, String source) =>
    RankingBoard(id: id, source: source, name: id);

/// 一次轮播挂载的句柄：[repository] 供请求流水断言，[opened] 是最后一次
/// 点按上抛的条目。
class _Scene {
  _Scene(this.repository);
  final FixtureRepository repository;
  Drama? opened;
}

/// 挂载首页轮播并等选片落地。
///
/// 不传 [repository] 时按 [doubanRanking]/[boards]/[pages] 现场造一份榜单
/// 仓库；选片缓存默认清空，只有串联同一天多次挂载时才传
/// [reusePicksCache] 保留。
Future<_Scene> _mount(
  WidgetTester tester, {
  required SourceSite anchor,
  RankingPage? doubanRanking,
  List<RankingBoard> boards = const [],
  Map<String, RankingPage> pages = const {},
  FixtureRepository? repository,
  LocalStore? store,
  Size size = phoneSize,
  ValueKey<String>? key,
  bool reusePicksCache = false,
}) async {
  if (!reusePicksCache) _clearPicksCache();
  final repo = repository ??
      _BoardRepository(
        boards: boards,
        // null-aware element：没给豆瓣榜就不落下这条 entry。
        rankingPages: {doubanCarouselBoard: ?doubanRanking, ...pages},
      );
  final scene = _Scene(repo);
  tester.view.physicalSize = size * tester.view.devicePixelRatio;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: HomeCarousel(
          key: key,
          store: store ?? await _newStore(),
          repository: repo,
          onOpen: (drama) => scene.opened = drama,
          fallbackItems: const [FixtureRepository.free],
          anchor: anchor,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return scene;
}

/// 只 stub 榜单链路的仓库：[boards] 决定「按类取榜」命中哪个榜，[pages]
/// 决定每个榜的条目；其余能力继承 [FixtureRepository]（目录请求流水仍可
/// 供「零多余请求」断言）。
class _BoardRepository extends FixtureRepository {
  _BoardRepository({this.boards = const [], this.rankingPages = const {}});

  /// 每个榜 id 对应的条目（基类 [FixtureRepository.pages] 是目录页码流水，
  /// 名字被占，这里另起一个）。
  final List<RankingBoard> boards;
  final Map<String, RankingPage> rankingPages;

  @override
  Future<List<RankingBoard>> rankingBoards() async => boards;

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    rankingsCalls++;
    final stub = rankingPages[board];
    if (stub == null) throw StateError('榜单不存在：$board');
    return stub;
  }
}
