import 'models.dart';

enum CatalogSort {
  // 源站顺序对 maccms 类站源即“最近更新”，是目录的默认排序。
  source('源站顺序'),
  heat('热度'),
  views('播放量'),
  score('评分'),
  date('上线日期'),
  name('名称'),
  season('自然季号');

  const CatalogSort(this.label);
  final String label;
}

class CatalogView {
  const CatalogView({
    this.sort = CatalogSort.source,
    this.release = '',
    this.area = '',
    this.year = '',
    this.allSources = false,
  });
  final CatalogSort sort;
  final String release;

  /// 地区/年份筛选（'' = 全部）。选项由当前已加载条目动态聚合，
  /// 持久化恢复的值允许悬空（表现为不选中态，不做白名单校验）。
  final String area;
  final String year;
  final bool allSources;

  CatalogView copyWith({
    CatalogSort? sort,
    String? release,
    String? area,
    String? year,
    bool? allSources,
  }) => CatalogView(
    sort: sort ?? this.sort,
    release: release ?? this.release,
    area: area ?? this.area,
    year: year ?? this.year,
    allSources: allSources ?? this.allSources,
  );

  // 值相等语义：LocalStore.catalogView 每次 getter 都从 JSON 新建实例，
  // 任何按实例比较（==/集合键/缓存失效判定）都必须按字段值判等。
  @override
  bool operator ==(Object other) =>
      other is CatalogView &&
      other.sort == sort &&
      other.release == release &&
      other.area == area &&
      other.year == year &&
      other.allSources == allSources;

  @override
  int get hashCode => Object.hash(sort, release, area, year, allSources);

  Map<String, dynamic> toJson() => {
    'sort': sort.name,
    'release': release,
    'area': area,
    'year': year,
    'allSources': allSources,
  };

  factory CatalogView.fromJson(Map<String, dynamic> value) => CatalogView(
    sort:
        CatalogSort.values
            .where((sort) => sort.name == value['sort'])
            .firstOrNull ??
        CatalogSort.source,
    release: {'', 'finished', 'ongoing', 'unknown'}.contains(value['release'])
        ? value['release'] as String
        : '',
    area: value['area'] as String? ?? '',
    year: value['year'] as String? ?? '',
    allSources: value['allSources'] == true,
  );
}

String normalizedSearchText(String text) {
  final value = String.fromCharCodes(
    text.runes.map(
      (rune) => rune >= 0xff01 && rune <= 0xff5e ? rune - 0xfee0 : rune,
    ),
  );
  return value.toLowerCase().replaceAll(
    RegExp(r'[\s\u3000，。！？、：；·「」『』（）【】《》“”‘’.,!?:;\-_/()\[\]{}]+'),
    '',
  );
}

bool matchesDramaQuery(Drama drama, String query) {
  final fields = normalizedSearchText(
    '${drama.title} ${drama.description} ${drama.tags.join(' ')}',
  );
  final terms = query
      .trim()
      .split(RegExp(r'\s+'))
      .map(normalizedSearchText)
      .where((word) => word.isNotEmpty);
  return terms.every(fields.contains);
}

/// 解析评分文本（maccms vod_score 一般 0-10，"8.5"/"8.5分"）。
/// 超出 0-10 视为无效（其他字段混入时不当评分用），解析不出返回 null。
double? scoreValue(String text) {
  final match = RegExp(r'\d+(?:\.\d+)?').firstMatch(text.trim());
  if (match == null) return null;
  final value = double.tryParse(match.group(0)!);
  if (value == null || value < 0 || value > 10) return null;
  return value;
}

/// 聚合当前条目集上的地区/年份筛选选项：地区按条目数降序，
/// 年份数字降序取前 10（老片年份长尾不必全列），非数字年份排最后。
({List<String> areas, List<String> years}) catalogFilterOptions(
  Iterable<Drama> items,
) {
  final areaCounts = <String, int>{};
  final yearCounts = <String, int>{};
  for (final drama in items) {
    final area = drama.area.trim();
    if (area.isNotEmpty) areaCounts[area] = (areaCounts[area] ?? 0) + 1;
    final year = drama.year.trim();
    if (year.isNotEmpty) yearCounts[year] = (yearCounts[year] ?? 0) + 1;
  }
  final areas =
      areaCounts.keys.toList()..sort((a, b) {
        final byCount = (areaCounts[b] ?? 0).compareTo(areaCounts[a] ?? 0);
        return byCount != 0 ? byCount : a.compareTo(b);
      });
  final years =
      yearCounts.keys.toList()..sort((a, b) {
        final numberA = int.tryParse(a);
        final numberB = int.tryParse(b);
        if (numberA != null && numberB != null) return numberB.compareTo(numberA);
        if (numberA != null) return -1;
        if (numberB != null) return 1;
        return b.compareTo(a);
      });
  return (areas: areas, years: years.take(10).toList());
}

double? catalogMetric(String text) {
  final cleaned = text.toLowerCase().replaceAll(RegExp(r'[,，\s]'), '');
  final match = RegExp(
    r'^(\d+(?:\.\d+)?)([亿万千wkmb]?)(?:\+)?(?:次播放|次观看|人看过|热度|播放|观看|次)?\+?$',
  ).firstMatch(cleaned);
  if (match == null) return null;
  final number = double.tryParse(match[1]!);
  if (number == null || !number.isFinite) return null;
  return number *
      switch (match[2]) {
        '亿' => 100000000,
        '万' || 'w' => 10000,
        '千' || 'k' => 1000,
        'm' => 1000000,
        'b' => 1000000000,
        _ => 1,
      };
}

/// 当前条目集上真正有效的排序项：依赖字段（热度/播放量/上线日期）在全部条目
/// 上都解析不出数值时，对应排序与源站顺序等价（假排序），UI 应禁用该选项。
/// 源站顺序、名称、季号只依赖本地字段，恒可用。
/// 服务端排序（如剧果 sort=hot/new）由调用方按源能力并入返回集合。
Set<CatalogSort> catalogSortSupport(Iterable<Drama> items) {
  var heat = false;
  var views = false;
  var score = false;
  var dated = false;
  for (final drama in items) {
    heat = heat || catalogMetric(drama.heat) != null;
    views = views || catalogMetric(drama.views) != null;
    score = score || scoreValue(drama.score) != null;
    dated = dated || DateTime.tryParse(drama.onlineDate) != null;
    if (heat && views && score && dated) break;
  }
  return {
    CatalogSort.source,
    CatalogSort.name,
    CatalogSort.season,
    if (heat) CatalogSort.heat,
    if (views) CatalogSort.views,
    if (score) CatalogSort.score,
    if (dated) CatalogSort.date,
  };
}

int _seasonNumber(String label) {
  final numeric = int.tryParse(label);
  if (numeric != null) return numeric;
  const digits = {
    '零': 0,
    '〇': 0,
    '一': 1,
    '二': 2,
    '两': 2,
    '兩': 2,
    '三': 3,
    '四': 4,
    '五': 5,
    '六': 6,
    '七': 7,
    '八': 8,
    '九': 9,
  };
  var number = 0;
  var digit = 0;
  for (final rune in label.runes) {
    final character = String.fromCharCode(rune);
    if (digits.containsKey(character)) {
      digit = digit * 10 + digits[character]!;
    } else {
      final multiplier = character == '百' ? 100 : 10;
      number += (digit == 0 ? 1 : digit) * multiplier;
      digit = 0;
    }
  }
  return number + digit;
}

String _naturalTitle(String title) =>
    normalizedSearchText(title).replaceAllMapped(
      RegExp(r'第([0-9零〇一二两兩三四五六七八九十百]+)([季部])'),
      (match) => '第${_seasonNumber(match[1]!)}${match[2]}',
    );

int naturalTitleCompare(String left, String right) {
  final pattern = RegExp(r'\d+|\D+');
  final a = pattern
      .allMatches(_naturalTitle(left))
      .map((match) => match[0]!)
      .toList();
  final b = pattern
      .allMatches(_naturalTitle(right))
      .map((match) => match[0]!)
      .toList();
  for (var index = 0; index < a.length && index < b.length; index++) {
    final numberA = int.tryParse(a[index]);
    final numberB = int.tryParse(b[index]);
    final comparison = numberA != null && numberB != null
        ? numberA.compareTo(numberB)
        : a[index].compareTo(b[index]);
    if (comparison != 0) return comparison;
  }
  return a.length.compareTo(b.length);
}

int _descending(num? a, num? b) => a == null
    ? (b == null ? 0 : 1)
    : b == null
    ? -1
    : b.compareTo(a);

/// 上线状态筛选匹配（'' = 全部）。
bool matchesReleaseStatus(Drama drama, String release) {
  if (release.isEmpty) return true;
  final status = drama.releaseStatus == 'completed'
      ? 'finished'
      : drama.releaseStatus;
  // 「状态未知」= 站源没有给出完结状态的条目（空/unknown）。
  // 不填 releaseStatus 的源在此筛选下等于全量，语义与「全部」重合属预期。
  return release == 'unknown'
      ? status.isEmpty || status == 'unknown'
      : status == release;
}

/// 按 view 的筛选维度过滤（不含排序）。skip* 供筛选选项聚合使用：
/// 聚合某维度的选项时跳过该维度自身、其余维度照常生效——保证面板上
/// 显示的每个选项在当前其它过滤态下选中必有内容（选了不出空列表）。
List<Drama> filterCatalog(
  Iterable<Drama> rows,
  CatalogView view, {
  bool skipArea = false,
  bool skipYear = false,
  bool skipRelease = false,
}) => rows.where((drama) {
  // 地区/年份为精确匹配筛选（选项来自已加载条目，值域与字段一致）。
  if (!skipArea && view.area.isNotEmpty && drama.area.trim() != view.area) {
    return false;
  }
  if (!skipYear && view.year.isNotEmpty && drama.year.trim() != view.year) {
    return false;
  }
  return skipRelease || matchesReleaseStatus(drama, view.release);
}).toList();

/// 当前条目池上有内容的上线状态选项集合（'' 恒含；键值与
/// catalog_sort_sheet 的 _releaseOptions 对应），供筛选面板隐藏
/// 无命中的状态（如全是连载的源不显示「已完结」）。
Set<String> catalogReleaseOptions(Iterable<Drama> items) {
  final pool = items.toList();
  return {
    for (final release in const ['', 'ongoing', 'finished', 'unknown'])
      if (release.isEmpty ||
          pool.any((drama) => matchesReleaseStatus(drama, release)))
        release,
  };
}

List<Drama> sortCatalog(Iterable<Drama> rows, CatalogView view) {
  final items = filterCatalog(rows, view);
  if (view.sort == CatalogSort.source) return items;
  final positions = {for (final entry in items.indexed) entry.$2.id: entry.$1};
  final metrics = <String, num?>{
    for (final drama in items)
      drama.id: switch (view.sort) {
        CatalogSort.heat => catalogMetric(drama.heat),
        CatalogSort.views => catalogMetric(drama.views),
        CatalogSort.score => scoreValue(drama.score),
        CatalogSort.date => DateTime.tryParse(
          drama.onlineDate,
        )?.millisecondsSinceEpoch,
        _ => null,
      },
  };
  // 字段型排序（热度/播放/评分/日期）在所有条目都没有对应字段值时
  // 自动降级为源站顺序：切源后持久化的排序请求可能悬空（如热度选中
  // 状态切到无热度字段的源），此时强行排序只会靠 tie-break 原样返回
  // 源站顺序，造成「已选中但列表无变化」的假象——直接诚实降级。
  // 剧果「全部」页源站本就按热度序返回，降级后结果与语义一致。
  final metricDriven = switch (view.sort) {
    CatalogSort.heat ||
    CatalogSort.views ||
    CatalogSort.score ||
    CatalogSort.date => true,
    _ => false,
  };
  if (metricDriven && metrics.values.every((value) => value == null)) {
    return items;
  }
  items.sort((a, b) {
    final comparison = switch (view.sort) {
      CatalogSort.source => 0,
      CatalogSort.name => normalizedSearchText(
        a.title,
      ).compareTo(normalizedSearchText(b.title)),
      CatalogSort.season => naturalTitleCompare(a.title, b.title),
      _ => _descending(metrics[a.id], metrics[b.id]),
    };
    return comparison != 0
        ? comparison
        : positions[a.id]!.compareTo(positions[b.id]!);
  });
  return items;
}
