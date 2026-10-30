import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/home_feed_models.dart';

Map<String, dynamic> sectionJson(
  String id,
  String title, {
  int priority = 0,
  int cards = 2,
  String moreLabel = '查看更多',
  bool hasMore = true,
}) =>
    {
      'id': id,
      'title': title,
      'subtitle': '$title 的副标题',
      'type': 'collection',
      'role': 'base',
      'priority': priority,
      'count': cards,
      'moreLabel': moreLabel,
      'hasMore': hasMore,
      'items': [
        for (var index = 0; index < cards; index++)
          {
            'id': '$id-$index',
            'source': 'dongpiandi',
            'sourceId': index.toString(),
            'title': '条目$index',
          },
      ],
    };

void main() {
  test('板块数量与顺序完全跟随远端数据', () {
    HomeFeed parse(List<Map<String, dynamic>> sections) =>
        HomeFeed.fromJson({'items': sections});

    final feed = parse([
      sectionJson('a', '国产新剧', priority: 88),
      sectionJson('b', '高分电影', priority: 84),
    ]);
    expect(feed.sections.length, 2);
    expect(feed.sections.first.title, '国产新剧');

    // 站点多发一个板块（例如新增「韩剧在追」）→ UI 侧数量随之变化，
    // 本地没有任何写死的数量上限。
    final grown = parse([
      sectionJson('a', '国产新剧', priority: 88),
      sectionJson('c', '韩剧在追', priority: 90),
      sectionJson('b', '高分电影', priority: 84),
      sectionJson('d', '院线热映', priority: 81),
    ]);
    expect(grown.sections.length, 4);

    // 站点删掉板块 → 数量跟着少。
    final shrunk = parse([sectionJson('a', '国产新剧', priority: 88)]);
    expect(shrunk.sections.length, 1);
    expect(shrunk.sections.single.id, 'a');
  });

  test('未知键与缺失字段不影响解析', () {
    final feed = HomeFeed.fromJson({
      'items': [
        {
          'title': '只有标题',
          'items': [
            {'id': 'x1', 'source': 'dongpiandi', 'title': '某剧'},
          ],
          'evidence': {'future': true},
          'next_year_field': 1,
        },
      ],
      'unknownTopLevel': 'ignored',
    });
    final section = feed.sections.single;
    expect(section.title, '只有标题');
    expect(section.id, '');
    expect(section.priority, 0);
    expect(section.subtitle, '');
    expect(section.moreLabel, '');
    // 没有 moreLabel 就不该显示「查看更多」入口。
    expect(section.canShowMore, isFalse);
    expect(section.items.single.title, '某剧');
  });

  test('空数据不产生空壳板块', () {
    expect(HomeFeed.fromJson({}).isEmpty, isTrue);
    expect(HomeFeed.fromJson({'items': []}).isEmpty, isTrue);
    expect(HomeFeed.fromJson({'items': [sectionJson('a', '空', cards: 0)]})
        .sections
        .single
        .isEmpty, isTrue);
  });

  test('moreLabel 与 hasMore 决定入口是否出现', () {
    final withMore = HomeSection.fromJson(
      sectionJson('a', '国产新剧', moreLabel: '查看完整榜单', hasMore: true),
    );
    expect(withMore.canShowMore, isTrue);
    expect(withMore.moreLabel, '查看完整榜单');

    final withoutMore = HomeSection.fromJson(
      sectionJson('a', '国产新剧', moreLabel: '查看完整榜单', hasMore: false),
    );
    expect(withoutMore.canShowMore, isFalse);
  });

  test('主推板块走轮播、其余板块走分类条', () {
    final feed = HomeFeed.fromJson({
      'items': [
        sectionJson('korean', '韩剧在追', priority: 90),
        sectionJson('everyone', '大家都在看', priority: 100),
      ],
    });
    // role 没下发时按顺序取第一块（站点已排好序）。
    expect(feed.primary?.id, 'korean');

    final marked = HomeFeed.fromJson({
      'items': [
        sectionJson('korean', '韩剧在追', priority: 90),
        {...sectionJson('everyone', '大家都在看'), 'role': 'primary'},
      ],
    });
    expect(marked.primary?.title, '大家都在看');
    // 主推板块不再出现在分类条里（它已经被轮播占用）。
    expect(marked.secondary.map((section) => section.id), ['korean']);
    expect(HomeFeed.fromJson({}).primary, isNull);
  });

  test('追剧周表按天解析', () {
    final calendar = WatchCalendar.fromJson({
      'days': [
        {
          'date': '2026-10-19',
          'label': '周一',
          'items': [
            {'id': 'av_a', 'source': 'dongpiandi', 'title': '甲'},
            {'id': 'av_b', 'source': 'dongpiandi', 'title': '乙'},
          ],
        },
        {
          'date': '2026-10-20',
          'label': '周二',
          'items': [
            {'id': 'av_a', 'source': 'dongpiandi', 'title': '甲'},
          ],
        },
        {'date': '2026-10-21', 'label': '周三', 'items': []},
      ],
    });
    expect(calendar.days.length, 3);
    expect(calendar.days.first.label, '周一');
    expect(calendar.days.last.isEmpty, isTrue);
    expect(calendar.isEmpty, isFalse);
    expect(WatchCalendar.fromJson({}).isEmpty, isTrue);
  });

  test('周表去重：同一部剧只留最新一天，顺序按首次出现', () {
    final calendar = WatchCalendar.fromJson({
      'days': [
        {
          'date': '2026-10-19',
          'items': [
            {'id': 'av_a', 'source': 'dongpiandi', 'title': '甲', 'episodes': 10},
            {'id': 'av_b', 'source': 'dongpiandi', 'title': '乙'},
          ],
        },
        {
          'date': '2026-10-20',
          'items': [
            {
              'id': 'av_a',
              'source': 'dongpiandi',
              'title': '甲',
              'episodes': 12,
              'releaseStatus': 'ongoing',
            },
          ],
        },
      ],
    });
    final latest = calendar.latest;
    // 嫁金钗这类天天更新的剧一周会出现 7 次，展示只留一条。
    expect(latest.length, 2);
    expect(latest.first.id, 'av_a');
    // 留的是最新一天那条（集数最新、状态跟着最新一条）。
    expect(latest.first.episodes, 12);
    expect(latest.first.episodeLabel, '更新至 12 集');
    expect(latest.last.id, 'av_b');
  });
}
