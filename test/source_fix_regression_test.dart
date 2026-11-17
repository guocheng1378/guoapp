import 'dart:convert';

import 'package:duanju_app/catalog_browser.dart';
import 'package:duanju_app/catalog_sort.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/tvbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

/// 搜索桩：按页返回可配置的结果，并记录请求过的页码。
class _PagedSearchRepository extends FixtureRepository {
  _PagedSearchRepository(this.respond);

  final CatalogPage Function(String source, int page, String query) respond;
  final requestedPages = <int>[];
  final requestedQueries = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async {
    requestedPages.add(page);
    requestedQueries.add(query);
    return respond(source, page, query);
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      CatalogPage([]);
}

List<Drama> _rows(String source, int page, int count, {String title = '匹配剧'}) =>
    [
      for (var i = 0; i < count; i++)
        Drama(
          id: '$source:p$page:$i',
          source: source,
          title: '$title $page-$i',
        ),
    ];

void main() {
  // 用支持分页搜索的站源（pagedSearch=true）走完整分页链路。
  const source = 'huangguoai';
  SourceGroup searchGroup() =>
      SourceGroup(source, '黄果 AI', [SourceSite.byId(source)!]);

  group('搜索分页收敛', () {
    test('warning 不再撑起 hasMore，也不冻结页码', () async {
      final repository = _PagedSearchRepository((s, page, query) {
        if (page == 1) {
          return CatalogPage(_rows(s, page, 2),
              page: page, hasMore: false, warning: '已显示当前可获取的匹配结果');
        }
        return CatalogPage([], page: page, hasMore: false);
      });
      final browser = CatalogBrowser(repository);
      final first = await browser.load(searchGroup(), query: '测试');
      expect(first.hasMore, isFalse,
          reason: '红果式 Limited 提示不能再让上拉无限重发同一页');
      expect(repository.requestedPages, [1]);
    });

    test('服务端每页回同一批条目时立即判耗尽', () async {
      final repeated = _rows(source, 1, 2);
      final repository = _PagedSearchRepository(
        (s, page, query) => CatalogPage(repeated, page: page, hasMore: true),
      );
      final browser = CatalogBrowser(repository);
      await browser.load(searchGroup(), query: '测试');
      final next = await browser.load(searchGroup(), query: '测试', more: true);
      expect(next.hasMore, isFalse,
          reason: '没有新增条目就不能继续翻页，否则列表看着不动、footer 一直转');
      expect(next.items.length, repeated.length);
    });

    test('正常翻页时页码单调推进', () async {
      final repository = _PagedSearchRepository(
        (s, page, query) => CatalogPage(_rows(s, page, 2),
            page: page, hasMore: page < 4),
      );
      final browser = CatalogBrowser(repository);
      await browser.load(searchGroup(), query: '测试');
      await browser.load(searchGroup(), query: '测试', more: true);
      await browser.load(searchGroup(), query: '测试', more: true);
      expect(repository.requestedPages, [1, 2, 3]);
    });

    test('持续失败的源有限次收敛', () async {
      final repository = _PagedSearchRepository((s, page, query) =>
          CatalogPage([], page: page, hasMore: true, warning: '源站超时'));
      final browser = CatalogBrowser(repository);

      // 空结果 + warning 会按既有语义抛 AppFailure 交给 UI 显示错误横幅；
      // 这里只验证分页状态：连续失败后不再发起新请求。
      Future<void> loadQuietly({required bool more}) async {
        try {
          await browser.load(searchGroup(), query: '测试', more: more);
        } on AppFailure {
          // 预期：错误横幅路径。
        }
      }

      await loadQuietly(more: false);
      await loadQuietly(more: true);
      final afterConverge = repository.requestedPages.length;
      await loadQuietly(more: true);
      await loadQuietly(more: true);
      expect(repository.requestedPages.length, afterConverge,
          reason: '坏源收敛后不该再重发同一页');
      expect(afterConverge, lessThanOrEqualTo(2));
    });
  });

  group('上游站源分类映射', () {
    test('笔盒归成人类、禁果短剧归黄果类、韩小圈归视频类', () {
      final beabox = SourceSite.byId('beabox');
      final jinguoduanju = SourceSite.byId('jinguoduanju');
      final hanxiaoquan = SourceSite.byId('hanxiaoquan');
      expect(beabox, isNotNull);
      expect(beabox!.isAdultSource, isTrue);
      expect(beabox.classKey, 'adult');
      expect(SourceSite.classLabel(beabox.classKey), '成人类');

      expect(jinguoduanju, isNotNull);
      expect(jinguoduanju!.inHuangguoCategory, isTrue);
      expect(jinguoduanju.classKey, 'huangguo');
      expect(SourceSite.classLabel(jinguoduanju.classKey), '黄果类');

      expect(hanxiaoquan, isNotNull);
      expect(hanxiaoquan!.isVideoSource, isTrue);
      expect(hanxiaoquan.classKey, 'video');
    });

    test('未接入加载实现的源不出现在站源菜单', () {
      final ids = SourceSite.values.map((site) => site.id).toSet();
      for (final id in ['beabox', 'jinguoduanju', 'hanxiaoquan']) {
        expect(ids.contains(id), isFalse,
            reason: '$id 本地核心无目录实现，进菜单会点了就报错');
      }
    });

    test('TVBox 配置按上游站点名精确归类', () {
      final plan = TvboxConfigParser.parse(jsonEncode({
        'sites': [
          {'key': 'b1', 'name': '笔盒', 'api': 'https://a.example.com'},
          {'key': 'j1', 'name': '禁果短剧', 'api': 'https://b.example.com'},
          {'key': 'h1', 'name': '韩小圈', 'api': 'https://c.example.com'},
        ],
        'lives': [],
      }));
      final categories = {
        for (final site in plan.sites) site.name: site.category,
      };
      expect(categories['笔盒'], 'adult');
      expect(categories['禁果短剧'], 'shortDrama');
      expect(categories['韩小圈'], 'video');
    });
  });

  group('搜索条目关键词复核', () {
    test('非在线搜索源的条目必须经过本地匹配', () {
      expect(SourceSite.searchesOnline('hongguo'), isTrue);
      expect(SourceSite.searchesOnline('huangguoai'), isTrue);
      expect(SourceSite.searchesOnline('beabox'), isFalse);
      expect(SourceSite.searchesOnline('jinguoduanju'), isFalse);
      expect(SourceSite.searchesOnline('hanxiaoquan'), isFalse);
      expect(SourceSite.searchesOnline('unknown-source'), isFalse);

      const matching = Drama(id: 'x:1', source: 'x', title: '霸道总裁');
      const unrelated = Drama(id: 'x:2', source: 'x', title: '乡村爱情');
      expect(matchesDramaQuery(matching, '总裁'), isTrue);
      expect(matchesDramaQuery(unrelated, '总裁'), isFalse);
    });
  });
}
