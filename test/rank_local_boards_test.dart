import 'package:duanju_app/models.dart';
import 'package:duanju_app/rank_local_boards.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Drama drama(
    String id,
    String source, {
    String heat = '',
    String views = '',
    String onlineDate = '',
    int episodes = 0,
    String category = '',
  }) => Drama(
    id: id,
    source: source,
    title: id,
    heat: heat,
    views: views,
    onlineDate: onlineDate,
    episodes: episodes,
    category: category,
  );

  group('rank_local_boards', () {
    test('localBoards ids and isLocalBoardId', () {
      expect(
        localBoards.map((board) => board.id),
        containsAll(['local-heat', 'local-schedule']),
      );
      expect(isLocalBoardId('local-heat'), isTrue);
      expect(isLocalBoardId('douban-top250'), isFalse);
    });

    test('label helpers', () {
      expect(categoryTagLabel(drama('a', 's', category: '逆袭')), '[逆袭]');
      expect(categoryTagLabel(drama('a', 's')), '');
      expect(episodeCountLabel(drama('a', 's', episodes: 12)), '共 12 部');
      expect(episodeCountLabel(drama('a', 's')), '');
      expect(updateLabel(drama('a', 's', episodes: 8)), '更新至 8 集');
      expect(updateLabel(drama('a', 's')), '');
    });

    test('buildHeatBoard sorts 万/亿 aware, dedupes, skips zero-heat', () {
      final rows = buildHeatBoard([
        drama('low', 'a', heat: '321'),
        drama('yi', 'b', heat: '1.2亿'),
        drama('wan', 'c', heat: '9.5万'),
        drama('dup', 'd', heat: '50亿'),
        drama('dup', 'd', heat: '50亿'),
        drama('none', 'e'),
      ]);
      expect(rows.map((row) => row.drama.id).toList(), [
        'dup',
        'yi',
        'wan',
        'low',
      ]);
      expect(rows.first.metric, '热度 50亿');
      expect(rows[2].metric, '热度 9.5万');
    });

    test('views fallback when heat missing', () {
      final rows = buildHeatBoard([drama('v', 'a', views: '2万')]);
      expect(rows.single.metric, '热度 2万');
    });

    test('buildScheduleGroups newest first, following pinned, undated last', () {
      final groups = buildScheduleGroups(
        [
          drama('old', 'a', onlineDate: '2025-01-02', heat: '10'),
          drama('today', 'b', onlineDate: '2026年3月5日', heat: '1'),
          drama('noDate', 'c'),
          drama('md', 'd', onlineDate: '3月5日', heat: '5'),
        ],
        isFollowing: (d) => d.id == 'today',
      );
      expect(groups.first.label, '3月5日');
      expect(groups.first.total, 2);
      expect(groups.first.items.first.drama.id, 'today');
      expect(groups.last.label, '待定');
      expect(groups.last.items.single.drama.id, 'noDate');
    });
  });
}
