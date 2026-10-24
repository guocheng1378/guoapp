import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/ranking_models.dart';

class FixtureRepository extends AppRepository {
  int detailCalls = 0;
  bool fail = false;
  final requests = <String>[];
  // 目录查询词流水（豆瓣搜片断言「不重搜」用，与精选位拉取分离）。
  final queries = <String>[];
  final pages = <int>[];
  final forced = <bool>[];
  final cachedPages = <String, CatalogPage>{};
  // 豆瓣搜片测试：rankingPage 置空时 rankings 走基类抛错（模拟变体无
  // 榜单 Provider）；queryResults 以查询词为键返回命中条目。
  int rankingsCalls = 0;
  RankingPage? rankingPage;
  final Map<String, List<Drama>> queryResults = {};
  static const free = Drama(
    id: 'hongguo:100',
    source: 'hongguo',
    title: '测试短剧',
    episodes: 2,
    category: '合成数据',
    // 20 分钟 > 600 秒：显式定性长剧，保播放器存量用例走旧分支。
    duration: 1200,
  );
  static const vip = Drama(
    id: 'huangdou:200',
    source: 'huangdou',
    title: '会员测试剧',
    episodes: 4,
    vip: true,
    duration: 1200,
  );
  @override
  Future<void> initialize() async {}
  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async {
    rankingsCalls++;
    final stub = rankingPage;
    if (stub == null) {
      return super.rankings(board, page: page, force: force);
    }
    return stub;
  }
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      cachedPages[source] ?? CatalogPage([]);
  @override
  Future<String> cover(Drama drama, {bool force = false}) async =>
      throw AppFailure('合成剧集没有远程海报');
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
    // 仅记录搜索查询（目录拉取 query 为空不记），供「不重搜」断言用。
    if (query.isNotEmpty) queries.add(query);
    pages.add(page);
    forced.add(force);
    if (fail) {
      throw AppFailure('合成网络错误');
    }
    final hits = queryResults[query];
    if (query.isNotEmpty && hits != null) {
      return CatalogPage(hits, page: page, hasMore: false);
    }
    return CatalogPage(
      [
        free,
        vip,
        Drama(
          id: '$source:auto-$page',
          source: source,
          title: '第$page页短剧',
          episodes: 1,
          category: '合成数据',
        ),
      ],
      page: page,
      hasMore: page < 5,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    detailCalls++;
    return DramaDetail(drama, [
      Episode({'id': '1', 'title': '第1集', 'currentEpisode': 1}, 1),
      Episode({'id': '2', 'title': '第2集', 'currentEpisode': 2}, 2),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => const PlaybackPlan(url: 'https://example.test/synthetic.mp4');
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      throw AppFailure('没有备用线路');
  @override
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route) async =>
      throw AppFailure('测试桩不支持选线');
  @override
  Future<void> cancelPlayback() async {}
  @override
  Future<void> release(String session) async {}
}
