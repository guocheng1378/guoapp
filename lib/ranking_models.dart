import 'models.dart';

class RankingBoard {
  const RankingBoard({
    required this.id,
    required this.source,
    required this.name,
    this.description = '',
  });
  final String id;
  final String source;
  final String name;
  final String description;
  String get groupId => SourceSite.byId(source)?.groupId ?? source;
  /// 榜单 id 统一为 `<source>-<后缀>`（如 hongguo-hot、douban-top250），
  /// 解析首段为站源；未知前缀返回空串（由调用方按不可用站源拒绝）。
  static String sourceForID(String id) {
    final head = id.split('-').first;
    final site = SourceSite.byId(head);
    if (site != null) return site.id;
    // 黄果 AI 榜单历史 id 前缀是 `huangguo-*`（hot/recommend/potential），
    // 而站源 id 是 `huangguoai`——`byId('huangguo')` 为 null，不特判会让
    // 榜单取数授权拿到空源、抛「当前版本不包含此站源」。目前没有任何
    // `huangguo-*` 榜属于黄果旧版（huangguo-video 无榜定义），此映射安全。
    if (head == 'huangguo') return 'huangguoai';
    return '';
  }
  factory RankingBoard.fromJson(Map<String, dynamic> json) => RankingBoard(
    id: json['id'] as String? ?? '',
    source:
        json['source'] as String? ?? sourceForID(json['id'] as String? ?? ''),
    name: json['name'] as String? ?? '',
    description: json['description'] as String? ?? '',
  );
}

class RankingItem {
  const RankingItem(this.rank, this.drama, {this.metric = ''});
  final int rank;
  final Drama drama;
  final String metric;
  factory RankingItem.fromJson(Map<String, dynamic> json) => RankingItem(
    intValue(json['rank']),
    Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    metric: json['metric'] as String? ?? '',
  );
}

class RankingPage {
  const RankingPage({
    required this.items,
    this.page = 1,
    this.hasMore = false,
    this.warning = '',
    this.updatedText = '',
    this.stale = false,
  });
  final List<RankingItem> items;
  final int page;
  final bool hasMore;
  final String warning;
  final String updatedText;
  final bool stale;
  factory RankingPage.fromJson(Map<String, dynamic> json) => RankingPage(
    items: [
      for (final row in json['items'] as List? ?? [])
        RankingItem.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    page: intValue(json['page']),
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    updatedText: json['updatedText'] as String? ?? '',
    stale: json['stale'] == true,
  );
}
