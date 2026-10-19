import 'models.dart';
import 'ranking_models.dart';

/// 跨源本地榜：不请求任何榜单接口，用各站源目录页已有的
/// heat / views / onlineDate 字段在本地聚合，离线也能看。
///
/// 目录页里 heat/views 常见三种形态：纯数字、`12.3万`、`1.2亿`，
/// 统一解析成数值再比较；onlineDate 宽松解析出年月日做排期分组。

enum LocalBoardKind { heat, schedule }

/// 一个本地榜的元信息；id 用 `local-` 前缀，与站源榜单 id
/// （`<站源>-<后缀>`）天然不冲突——站源名解析不出 `local`。
class LocalBoard {
  const LocalBoard(this.id, this.name, this.description, this.kind);
  final String id;
  final String name;
  final String description;
  final LocalBoardKind kind;
}

const List<LocalBoard> localBoards = [
  LocalBoard(
    'local-heat',
    '实时热度',
    '聚合各站源目录的热度与播放量',
    LocalBoardKind.heat,
  ),
  LocalBoard(
    'local-schedule',
    '更新排期',
    '按各站源标注的上线日期分组',
    LocalBoardKind.schedule,
  ),
];

bool isLocalBoardId(String id) => localBoards.any((board) => board.id == id);

/// `[分类]`，对齐云追 `text_topic_tag_count`。
String categoryTagLabel(Drama drama) =>
    drama.category.isEmpty ? '' : '[${drama.category}]';

/// 「共 N 部」，对齐云追 `text_topic_count`。
String episodeCountLabel(Drama drama) =>
    drama.episodes > 0 ? '共 ${drama.episodes} 部' : '';

/// 「更新至 N 集」，对齐云追 `text_update_to_episode`。
String updateLabel(Drama drama) =>
    drama.episodes > 0 ? '更新至 ${drama.episodes} 集' : '';

/// 榜单指标文案直接透传（豆瓣等榜单的 metric 已由内核生成）。
String rankingMetricLabel(RankingItem item) => item.metric.trim();

/// 把 `3.2万` / `1.2亿` / `12345` 统一解析为可比较的数值。
double _countValue(String raw) {
  final text = raw.trim();
  if (text.isEmpty) return 0;
  final match = RegExp(r'([\d.]+)').firstMatch(text);
  if (match == null) return 0;
  final number = double.tryParse(match.group(1) ?? '') ?? 0;
  if (text.contains('亿')) return number * 100000000;
  if (text.contains('万')) return number * 10000;
  return number;
}

/// 热度/播放量取大者；两者都缺失返回 0（不进热度榜）。
double _heatValue(Drama drama) {
  final heat = _countValue(drama.heat);
  final views = _countValue(drama.views);
  return heat >= views ? heat : views;
}

String _trim1(double value) {
  final text = value.toStringAsFixed(1);
  return text.endsWith('.0') ? text.substring(0, text.length - 2) : text;
}

String _compact(double value) {
  if (value >= 100000000) return '${_trim1(value / 100000000)}亿';
  if (value >= 10000) return '${_trim1(value / 10000)}万';
  return value.toInt().toString();
}

/// 热度徽标文案：原文已带「万/亿」直接沿用，纯数字压缩展示。
String _metricText(Drama drama) {
  final raw =
      _countValue(drama.heat) >= _countValue(drama.views)
          ? drama.heat.trim()
          : drama.views.trim();
  if (raw.isEmpty) return '';
  final value = double.tryParse(raw);
  return '热度 ${value == null ? raw : _compact(value)}';
}

/// 实时热度榜：heat/views 聚合降序；同剧多源取热度最高的一条。
List<RankingItem> buildHeatBoard(List<Drama> dramas) {
  final seen = <String>{};
  final ranked =
      dramas
          .where(
            (drama) =>
                seen.add('${drama.source}:${drama.id}') &&
                _heatValue(drama) > 0,
          )
          .toList()
        ..sort((a, b) => _heatValue(b).compareTo(_heatValue(a)));
  return [
    for (var index = 0; index < ranked.length; index++)
      RankingItem(index + 1, ranked[index], metric: _metricText(ranked[index])),
  ];
}

/// 排期表的一个日期分组。
class ScheduleGroup {
  const ScheduleGroup(this.label, this.total, this.items);
  final String label;
  final int total;
  final List<RankingItem> items;
}

/// 解析 onlineDate 为 (year, month, day)；解析不出返回 null。
/// 兼容 `2025-01-02` / `2025.1.2` / `2025年1月2日` / `1月2日` / `01-02`。
({int year, int month, int day})? _parseDate(String raw) {
  final text = raw.trim();
  final full = RegExp(
    r'(\d{4})[-/.年]\s*(\d{1,2})[-/.月]\s*(\d{1,2})',
  ).firstMatch(text);
  if (full != null) {
    return (
      year: int.parse(full.group(1)!),
      month: int.parse(full.group(2)!),
      day: int.parse(full.group(3)!),
    );
  }
  final partial = RegExp(r'(\d{1,2})[-/.月]\s*(\d{1,2})').firstMatch(text);
  if (partial != null) {
    return (
      year: DateTime.now().year,
      month: int.parse(partial.group(1)!),
      day: int.parse(partial.group(2)!),
    );
  }
  return null;
}

/// 更新排期表：按上线日期分组，最新日期在前；组内追更中的排最前，
/// 其余按热度降序。没有日期的条目归入末尾「待定」组。
List<ScheduleGroup> buildScheduleGroups(
  List<Drama> dramas, {
  required bool Function(Drama drama) isFollowing,
}) {
  final dated = <({int year, int month, int day}), List<Drama>>{};
  final undated = <Drama>[];
  final seen = <String>{};
  for (final drama in dramas) {
    if (!seen.add('${drama.source}:${drama.id}')) continue;
    final date = _parseDate(drama.onlineDate);
    if (date == null) {
      undated.add(drama);
    } else {
      dated.putIfAbsent(date, () => []).add(drama);
    }
  }
  final keys =
      dated.keys.toList()
        ..sort((a, b) {
          final byYear = b.year.compareTo(a.year);
          if (byYear != 0) return byYear;
          final byMonth = b.month.compareTo(a.month);
          if (byMonth != 0) return byMonth;
          return b.day.compareTo(a.day);
        });
  List<RankingItem> ranked(List<Drama> rows) {
    final sorted =
        rows.toList()
          ..sort((a, b) {
            final byFollow =
                (isFollowing(b) ? 1 : 0) - (isFollowing(a) ? 1 : 0);
            if (byFollow != 0) return byFollow;
            return _heatValue(b).compareTo(_heatValue(a));
          });
    return [
      for (var index = 0; index < sorted.length; index++)
        RankingItem(index + 1, sorted[index]),
    ];
  }

  return [
    for (final key in keys)
      ScheduleGroup(
        '${key.month}月${key.day}日',
        dated[key]!.length,
        ranked(dated[key]!),
      ),
    if (undated.isNotEmpty)
      ScheduleGroup('待定', undated.length, ranked(undated)),
  ];
}
