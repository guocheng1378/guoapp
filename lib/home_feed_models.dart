import 'models.dart';

/// 远端主页的一个板块。
///
/// 标题、副标题、类型、优先级、顺序、"查看更多"的文案**全部来自站点**
/// （`/v1/feed/home`），App 不内置任何板块清单：站点增删或改名即刻生效，
/// 本地只做渲染。站点给的 dramatically 字段缺失时一律回落空串/0，
/// 保证旧版本核心返回的数据也能解析。
class HomeSection {
  const HomeSection({
    required this.id,
    required this.title,
    this.subtitle = '',
    this.type = '',
    this.role = '',
    this.priority = 0,
    this.count = 0,
    this.moreLabel = '',
    this.hasMore = false,
    this.items = const <Drama>[],
  });

  final String id;
  final String title;
  final String subtitle;

  /// 站点板块类型：`trend`（大家都在看）、`collection`（榜单类）。
  final String type;

  /// 站点角色：`primary` 为主推板块。
  final String role;

  /// 站点排序权重，越大越靠前（App 不重排）。
  final int priority;
  final int count;

  /// 站点给的「查看更多 / 查看完整榜单」文案。
  final String moreLabel;
  final bool hasMore;
  final List<Drama> items;

  factory HomeSection.fromJson(Map<String, dynamic> json) => HomeSection(
    id: json['id'] as String? ?? '',
    title: json['title'] as String? ?? '',
    subtitle: json['subtitle'] as String? ?? '',
    type: json['type'] as String? ?? '',
    role: json['role'] as String? ?? '',
    priority: intValue(json['priority']),
    count: intValue(json['count']),
    moreLabel: json['moreLabel'] as String? ?? '',
    hasMore: json['hasMore'] == true,
    items: [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );

  bool get isEmpty => items.isEmpty;
  bool get canShowMore => hasMore && moreLabel.isNotEmpty;
}

/// 远端主页：板块列表 + 快照过期时间（毫秒时间戳，来自站点 expires_at，
/// 缺失时为 0=由核心侧默认策略决定）。
class HomeFeed {
  const HomeFeed({this.sections = const <HomeSection>[], this.expiresAt = 0});

  final List<HomeSection> sections;
  final int expiresAt;

  bool get isEmpty => sections.isEmpty;

  /// 站点主推板块（role=primary，即「大家都在看」）：没有标记时取第一块
  /// （站点已按 priority 排好序）。
  HomeSection? get primary {
    for (final section in sections) {
      if (section.role == 'primary') return section;
    }
    return sections.isEmpty ? null : sections.first;
  }

  /// 其余板块：按站点顺序（本地不重排），用于分类条。
  List<HomeSection> get secondary =>
      [for (final section in sections) if (section != primary) section];

  factory HomeFeed.fromJson(Map<String, dynamic> json) => HomeFeed(
    sections: [
      for (final row in json['items'] as List? ?? const [])
        HomeSection.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    expiresAt: intValue(json['expiresAt']),
  );
}

/// 追剧周表里的一天（站点 /v1/watch-calendar：7 天 × 电视剧/动漫/综艺/电影）。
class WatchDay {
  const WatchDay({
    this.date = '',
    this.label = '',
    this.items = const <Drama>[],
  });

  final String date;

  /// 星期标签（周一…周日），站点没给时由日期推出。
  final String label;
  final List<Drama> items;

  bool get isEmpty => items.isEmpty;

  factory WatchDay.fromJson(Map<String, dynamic> json) => WatchDay(
    date: json['date'] as String? ?? '',
    label: json['label'] as String? ?? '',
    items: [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
}

/// 追剧周表（App 内的「本周追剧」）。
class WatchCalendar {
  const WatchCalendar({this.days = const <WatchDay>[]});

  final List<WatchDay> days;

  bool get isEmpty => days.every((day) => day.isEmpty);

  /// 本周去重后的条目：同一部剧在一周里会天天出现，这里只留**最新一天**
  /// 的那条（集数标签最新），顺序按第一次出现的日子。
  ///
  /// 周表的语义就是「谁在更新」，去重后才是用户想看的清单——否则嫁金钗
  /// 会连着出现 7 次。
  List<Drama> get latest {
    final order = <String>[];
    final byId = <String, Drama>{};
    for (final day in days) {
      for (final drama in day.items) {
        if (drama.id.isEmpty) continue;
        if (!byId.containsKey(drama.id)) order.add(drama.id);
        byId[drama.id] = drama;
      }
    }
    return [for (final id in order) byId[id]!];
  }

  factory WatchCalendar.fromJson(Map<String, dynamic> json) => WatchCalendar(
    days: [
      for (final row in json['days'] as List? ?? const [])
        WatchDay.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
}
