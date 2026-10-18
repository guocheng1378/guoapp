import 'catalog_sort.dart';
import 'models.dart';
import 'ranking_models.dart';

/// 榜单页的跨源本地榜，对齐云追「日榜 / 排期表」两个周期项。
///
/// 与站源榜不同，这里不调用 `AppRepository.rankings`，而是用各站源目录页
/// 已经返回的 [Drama.heat] / [Drama.views] / [Drama.onlineDate] 在本地聚合，
/// 因此零新增站源依赖、零 Go 侧改动。
const String localHeatBoardId = 'local-heat';
const String localScheduleBoardId = 'local-schedule';

enum LocalBoardKind { heat, schedule }

class LocalBoard {
  const LocalBoard(this.id, this.name, this.description);

  final String id;
  final String name;
  final String description;

  LocalBoardKind get kind =>
      id == localScheduleBoardId ? LocalBoardKind.schedule : LocalBoardKind.heat;
}

const List<LocalBoard> localBoards = [
  LocalBoard(localHeatBoardId, '实时热度', '按各站热度归一化排序'),
  LocalBoard(localScheduleBoardId, '排期表', '按上线日期分组的新剧与追更'),
];

bool isLocalBoardId(String id) =>
    id == localHeatBoardId || id == localScheduleBoardId;

/// 解析 [Drama.onlineDate]。
///
/// Go 侧 `providerReleaseDate` 已把各源归一为 `YYYY-MM-DD`（见
/// `provider_sources_parity_test.go` 对野果 `2026-09-23` 的断言），这里额外
/// 容忍 `YYYY/M/D` 与带时间部分；无法解析时返回 null 而不是猜。
DateTime? parseOnlineDate(String value) {
  final text = value.trim();
  if (text.isEmpty) return null;
  final match = RegExp(r'^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})').firstMatch(text);
  if (match == null) return null;
  final year = int.tryParse(match[1]!);
  final month = int.tryParse(match[2]!);
  final day = int.tryParse(match[3]!);
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  // DateTime 会把 2 月 31 日规范化到 3 月，需要回验。
  if (date.month != month || date.day != day) return null;
  return date;
}

/// 热度指标原文：优先 `heat`，其次 `views`（对应云追的 `hot_type`）。
String? heatMetric(Drama drama) {
  for (final value in [drama.heat, drama.views]) {
    final text = value.trim();
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// 归一化热度数值，用于跨源排序；无法解析返回 null。
double? heatValue(Drama drama) =>
    catalogMetric(drama.heat) ?? catalogMetric(drama.views);

/// 「共 N 部」，对齐云追 `text_topic_count`。
String episodeCountLabel(Drama drama) =>
    drama.episodes > 0 ? '共 ${drama.episodes} 部' : '';

/// 「更新至 N 集」，对齐云追 `text_update_to_episode`。
String updateLabel(Drama drama) =>
    drama.episodes > 0 ? '更新至 ${drama.episodes} 集' : '';

/// 分类标签 `[分类]`，对齐云追 `text_topic_tag_count`。
String categoryTagLabel(Drama drama) =>
    drama.category.isEmpty ? '' : '[${drama.category}]';

/// 把归一化后的热度数值写成「万/亿」单位，避免裸数字出现在界面上。
String formatHeatValue(double value) {
  if (value >= 100000000) return '${(value / 100000000).toStringAsFixed(1)}亿';
  if (value >= 10000) return '${(value / 10000).toStringAsFixed(1)}万';
  return value.round().toString();
}

/// 指标原文是裸数字（各源给的是播放量整数值）还是已格式化的文本。
bool isBareNumber(String text) {
  final cleaned = text.replaceAll(',', '').replaceAll(' ', '').trim();
  if (cleaned.isEmpty) return false;
  return double.tryParse(cleaned) != null;
}

/// 条目指标文案：站源给的优先，缺失时用热度/播放量兜底，再兜底为集数。
///
/// 站源榜的 `metric` 通常已是「9200万 热度」这类成品文案，直接透传；
/// 本地榜拿到的是播放量整数值（如 `3864880`），必须换算成带单位的文本，
/// 否则界面上会出现一串裸数字。
String rankingMetricLabel(RankingItem item) {
  final given = item.metric.trim();
  if (given.isNotEmpty) return given;
  final raw = heatMetric(item.drama);
  if (raw != null) {
    final value = heatValue(item.drama);
    if (value != null && isBareNumber(raw)) {
      return '${formatHeatValue(value)} 热度';
    }
    return raw;
  }
  return episodeCountLabel(item.drama);
}

class ScheduleGroup {
  const ScheduleGroup({required this.label, required this.items, this.date});

  final String label;
  final DateTime? date;
  final List<RankingItem> items;

  int get total => items.length;
}

String scheduleDayLabel(DateTime date, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final target = DateTime(date.year, date.month, date.day);
  return switch (today.difference(target).inDays) {
    0 => '今天',
    1 => '昨天',
    2 => '前天',
    _ => '${date.month}月${date.day}日',
  };
}

class _Scored {
  const _Scored(this.value, this.drama);
  final double value;
  final Drama drama;
}

/// 组内排名：我的追剧置顶，其余按归一化热度降序，再按集数。
List<RankingItem> _rankWithin(
  List<Drama> dramas,
  bool Function(Drama) isFollowing,
) {
  final sorted = [...dramas]..sort((a, b) {
    final follow = (isFollowing(b) ? 1 : 0).compareTo(isFollowing(a) ? 1 : 0);
    if (follow != 0) return follow;
    final left = heatValue(a);
    final right = heatValue(b);
    if (left != null && right != null) return right.compareTo(left);
    if (left != null) return -1;
    if (right != null) return 1;
    return b.episodes.compareTo(a.episodes);
  });
  return [
    for (var index = 0; index < sorted.length; index++)
      RankingItem(
        index + 1,
        sorted[index],
        metric: heatMetric(sorted[index]) ?? '',
      ),
  ];
}

/// 排期表：按上线日期倒序分组，只保留最近 [days] 天窗口内的条目。
///
/// 没有 `onlineDate` 的剧不会出现在排期表里 —— 各源并非都提供该字段
/// （红果常常要靠额外的详情元数据补全），这里不做任何猜测。
List<ScheduleGroup> buildScheduleGroups(
  List<Drama> dramas, {
  required bool Function(Drama) isFollowing,
  DateTime? now,
  int days = 21,
}) {
  final clock = now ?? DateTime.now();
  final today = DateTime(clock.year, clock.month, clock.day);
  final floor = today.subtract(Duration(days: days < 1 ? 0 : days - 1));
  final buckets = <DateTime, List<Drama>>{};
  final seen = <String>{};
  for (final drama in dramas) {
    if (!seen.add(drama.id)) continue;
    final date = parseOnlineDate(drama.onlineDate);
    if (date == null) continue;
    if (date.isBefore(floor) || date.isAfter(today)) continue;
    buckets.putIfAbsent(date, () => []).add(drama);
  }
  final dates = buckets.keys.toList()
    ..sort((a, b) => b.compareTo(a));
  return [
    for (final date in dates)
      ScheduleGroup(
        label: scheduleDayLabel(date, today),
        date: date,
        items: _rankWithin(buckets[date]!, isFollowing),
      ),
  ];
}

/// 实时热度榜：跨源按归一化热度降序，最多 [maxItems] 条。
///
/// 只保留能解析出热度数值的条目 —— 拿不到数值的排在榜上只会误导用户。
List<RankingItem> buildHeatBoard(List<Drama> dramas, {int maxItems = 100}) {
  final ranked = <_Scored>[];
  final seen = <String>{};
  for (final drama in dramas) {
    if (!seen.add(drama.id)) continue;
    final value = heatValue(drama);
    if (value == null) continue;
    ranked.add(_Scored(value, drama));
  }
  ranked.sort((a, b) => b.value.compareTo(a.value));
  final take = ranked.length < maxItems ? ranked.length : maxItems;
  return [
    for (var index = 0; index < take; index++)
      RankingItem(
        index + 1,
        ranked[index].drama,
        metric: heatMetric(ranked[index].drama) ?? '',
      ),
  ];
}
