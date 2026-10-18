import 'dart:convert';

import 'app_build.dart';

enum SourceCategory {
  shortDrama,
  video,
}

class SourceSite {
  const SourceSite(this.id, this.name, this.description);
  final String id;
  final String name;
  final String description;
  SourceCategory get category => _categories[id] ?? SourceCategory.shortDrama;
  bool get isShortDrama => category == SourceCategory.shortDrama;
  bool get isVideoSource => category == SourceCategory.video;

  /// 黄果类成员：黄果系入口（AI/旧版/视频）+ 黄豆/野果/剧果。
  /// 站源管理页独立成「黄果类」分区；受限名单即该类（受限的只有黄果类）。
  static const huangguoCategoryIds = <String>{
    'huangguo-video',
    'huangguoai',
    'cloudfront',
    'huangdou',
    'yeguo',
    'huangju',
  };
  bool get inHuangguoCategory => huangguoCategoryIds.contains(id);

  bool? get shortPlayOverride => _shortPlay[id];
  bool get onlineSearch => id == 'hongguo' || pagedSearch;
  bool get pagedSearch => id == 'huangju' || duanjuPaged;
  bool get duanjuPaged => const {
    'yingshigongchang',
    'hongniu',
    '360zy',
    'modu',
    'dytt',
  }.contains(id);
  bool get searchSuggestions => id == 'hongguo';
  // 黄果系入口（AI/旧版/视频）各自成组：主界面站源菜单与站源管理页
  // 均单独显示各入口，站源管理页仅按黄果类区头归拢。
  String get groupId => id;
  String get groupName => name;
  String get entryName => switch (id) {
    'huangguo-video' => '视频',
    'huangguoai' => 'AI',
    'cloudfront' => '旧版',
    _ => name,
  };

  static const hongguo = SourceSite('hongguo', '红果', '短剧 · 漫剧 · AI 剧');
  static const duanjuValues = [
    SourceSite('yingshigongchang', '影视工厂', 'maccms · m3u8 · 可播放'),
    SourceSite('360zy', '360', 'maccms · m3u8 · 可播放'),
    SourceSite('modu', '魔都', 'maccms · m3u8 · 可播放'),
    SourceSite('dytt', '电影天堂', 'maccms · 真分集 · 可播放'),
    SourceSite('shandian', '闪电', 'maccms · m3u8 · 可播放'),
    SourceSite('hongniu', '红牛', 'maccms · m3u8 · 可播放'),
    SourceSite('niuniuzy', '牛牛', 'maccms · m3u8 · 可播放'),
    SourceSite('wsyzy', '无水印', 'maccms · m3u8 · 可播放'),
    SourceSite('sorani', '青空', '番剧 · 剧场 · 特摄 · m3u8'),
    SourceSite('dongpiandi', '真果·鉴', 'AI 聚合 · 多线路 m3u8 · 短剧/影视'),
  ];
  static const dsd = SourceSite('dsd', '帝果', '帝果合成短剧 · VIP 直免');
  // engineValues：Go 引擎已注册（specs.go 共 25 源）、体检全绿，但此前漏出
  // UI 白名单的站源，2026-10-18 恢复展示；不在受限名单，默认启用。
  static const engineValues = [
    SourceSite('yeguo', '野果', 'API · 网页解析 · 短剧'),
    SourceSite('yaguo', '芽果', 'API · 星芽短剧'),
    SourceSite('maoguo', '猫果', 'API · 七猫短剧'),
    SourceSite('fanguo', '饭果', 'API · 西饭短剧'),
    SourceSite('heguo', '河果', '网页 · 河马剧场'),
    SourceSite('xingguo', '星果', 'API · 星星短剧'),
    SourceSite('huaguo', '花生', 'maccms · 短剧采集'),
    SourceSite('wangguo', '短剧网站', 'maccms · 短剧聚合'),
    SourceSite('faguo', '168 影院', 'maccms · 影视采集'),
    SourceSite('wuguo', '五五', 'maccms · 短剧采集'),
  ];
  // knownValues 只含当前版本提供的站源；allValues 额外保留已下线源（dsd、
  // huangguo-video），旧用户配置与备份仍可解析，但界面不再展示。
  static const knownValues = [
    hongguo,
    SourceSite('huangdou', '黄豆', '精选短剧'),
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    ...duanjuValues,
    ...engineValues,
  ];
  static const allValues = [
    hongguo,
    SourceSite('huangdou', '黄豆', '精选短剧'),
    SourceSite('huangju', '剧果', '热门 · 最新 · 分类短剧'),
    SourceSite('huangguo-video', '黄果视频', '视频剧集'),
    SourceSite('huangguoai', '黄果 AI', 'AI 短剧'),
    SourceSite('cloudfront', '黄果旧版', '旧 API 剧库'),
    dsd,
    ...duanjuValues,
    ...engineValues,
  ];
  static const values = allSourcesEnabled ? knownValues : [hongguo];
  static bool isAvailable(String id) => values.any((site) => site.id == id);
  static bool isKnown(String id) => allValues.any((site) => site.id == id);
  // 受限站源 = 黄果类成员（黄果系入口 + 黄豆/野果/剧果），默认关闭；
  // 其余分类的站源一律默认开放。
  static bool isRestricted(String id) => huangguoCategoryIds.contains(id);
  static SourceSite byId(String id) =>
      allValues.firstWhere((site) => site.id == id, orElse: () => hongguo);

  static const _categories = <String, SourceCategory>{
    'hongguo': SourceCategory.shortDrama,
    'huangdou': SourceCategory.shortDrama,
    'huangju': SourceCategory.shortDrama,
    'huangguoai': SourceCategory.shortDrama,
    'cloudfront': SourceCategory.video,
    'huangguo-video': SourceCategory.video,
    'yeguo': SourceCategory.shortDrama,
    'dsd': SourceCategory.shortDrama,
    'yaguo': SourceCategory.shortDrama,
    'maoguo': SourceCategory.shortDrama,
    'fanguo': SourceCategory.shortDrama,
    'guanguo': SourceCategory.shortDrama,
    'heguo': SourceCategory.shortDrama,
    'xingguo': SourceCategory.shortDrama,
    'huaguo': SourceCategory.shortDrama,
    'niuguo': SourceCategory.shortDrama,
    'wangguo': SourceCategory.shortDrama,
    'faguo': SourceCategory.shortDrama,
    'piguo': SourceCategory.shortDrama,
    'wuguo': SourceCategory.shortDrama,
    'yingshigongchang': SourceCategory.video,
    '360zy': SourceCategory.video,
    'modu': SourceCategory.video,
    'dytt': SourceCategory.video,
    'shandian': SourceCategory.video,
    'hongniu': SourceCategory.video,
    'niuniuzy': SourceCategory.video,
    'wsyzy': SourceCategory.video,
    'sorani': SourceCategory.video,
    'dongpiandi': SourceCategory.video,
  };

  static const _shortPlay = <String, bool>{
    'hongguo': true,
    'huangdou': true,
    'huangju': true,
    'huangguoai': true,
    'huangguo-video': false,
    'cloudfront': false,
    'sorani': false,
    'yingshigongchang': false,
    '360zy': false,
    'modu': false,
    'dytt': false,
    'shandian': false,
    'hongniu': false,
    'niuniuzy': false,
    'wsyzy': false,
  };
}

class SourceGroup {
  const SourceGroup(this.id, this.name, this.sources);
  final String id;
  final String name;
  final List<SourceSite> sources;

  static List<SourceGroup> fromSources(Iterable<SourceSite> sources) {
    final groups = <String, List<SourceSite>>{};
    for (final source in sources) {
      (groups[source.groupId] ??= []).add(source);
    }
    return [
      for (final group in groups.entries)
        SourceGroup(group.key, group.value.first.groupName, group.value),
    ];
  }
}

class CatalogCategory {
  const CatalogCategory(this.id, this.name, {this.local = false});
  static const all = CatalogCategory('', '全部');
  final String id;
  final String name;
  final bool local;
  factory CatalogCategory.fromJson(Map<String, dynamic> json) =>
      CatalogCategory(
        json['id'] as String? ?? '',
        json['name'] as String? ?? '全部',
      );
}

int intValue(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

class Drama {
  const Drama({
    required this.id,
    required this.source,
    required this.title,
    this.sourceId = '',
    this.description = '',
    this.cover = '',
    this.episodes = 0,
    this.category = '',
    bool? vip,
    this.heat = '',
    this.views = '',
    this.onlineDate = '',
    this.tags = const [],
    this.releaseStatus = '',
  }) : vipStatus = vip;
  final String id;
  final String source;
  final String sourceId;
  final String title;
  final String description;
  final String cover;
  final int episodes;
  final String category;
  final bool? vipStatus;
  bool get vip => vipStatus == true;
  final String heat;
  final String views;
  final String onlineDate;
  final List<String> tags;
  final String releaseStatus;
  String get releaseLabel => switch (releaseStatus) {
    'finished' || 'completed' => '已完结',
    'ongoing' => '连载中',
    _ => '状态未知',
  };

  factory Drama.fromJson(Map<String, dynamic> json) => Drama(
    id: json['id'] as String? ?? '',
    source: json['source'] as String? ?? 'hongguo',
    sourceId: json['sourceId'] as String? ?? '',
    title: json['title'] as String? ?? '短剧',
    description: json['description'] as String? ?? '',
    cover: json['cover'] as String? ?? '',
    episodes: intValue(json['episodes']),
    category: json['category'] as String? ?? '',
    vip: json['vip'] == true
        ? true
        : json['vip'] == false &&
              (json['source'] != 'huangdou' ||
                  intValue(json['metadataSchema']) >= 1)
        ? false
        : null,
    heat: json['heat']?.toString() ?? '',
    views: json['views']?.toString() ?? '',
    onlineDate: json['onlineDate'] as String? ?? '',
    tags: (json['tags'] as List? ?? const []).whereType<String>().toList(),
    releaseStatus: json['releaseStatus'] as String? ?? '',
  );
  Map<String, dynamic> toJson() => {
    'metadataSchema': 1,
    'id': id,
    'source': source,
    'sourceId': sourceId,
    'title': title,
    'description': description,
    'cover': cover,
    'episodes': episodes,
    'category': category,
    'vip': vipStatus,
    'heat': heat,
    'views': views,
    'onlineDate': onlineDate,
    'tags': tags,
    'releaseStatus': releaseStatus,
  };

  Drama merge(Drama fresh) {
    if (id != fresh.id) return fresh;
    const genericCategories = {
      '短剧',
      '真人剧',
      '漫剧',
      'AI剧',
      'AI 剧',
      'AI短剧',
      'AI 短剧',
      'AI漫剧',
      'AI 漫剧',
    };
    return Drama(
      id: id,
      source: fresh.source.isEmpty ? source : fresh.source,
      sourceId: fresh.sourceId.isEmpty ? sourceId : fresh.sourceId,
      title: fresh.title.isEmpty || fresh.title == '短剧' ? title : fresh.title,
      description: fresh.description.isEmpty ? description : fresh.description,
      cover: fresh.cover.isEmpty ? cover : fresh.cover,
      episodes: fresh.episodes > 0 ? fresh.episodes : episodes,
      category:
          fresh.category.isEmpty ||
              genericCategories.contains(fresh.category) &&
                  category.isNotEmpty &&
                  !genericCategories.contains(category)
          ? category
          : fresh.category,
      vip: fresh.vipStatus ?? vipStatus,
      heat: fresh.heat.isEmpty ? heat : fresh.heat,
      views: fresh.views.isEmpty ? views : fresh.views,
      onlineDate: fresh.onlineDate.isEmpty ? onlineDate : fresh.onlineDate,
      tags: fresh.tags.isEmpty ? tags : fresh.tags,
      releaseStatus:
          fresh.releaseStatus.isEmpty || fresh.releaseStatus == 'unknown'
          ? releaseStatus
          : fresh.releaseStatus,
    );
  }
}

class Episode {
  Episode(this.raw, int fallback)
    : id = raw['id'] as String? ?? '',
      title = raw['title'] as String? ?? '第$fallback集',
      number = intValue(raw['currentEpisode']) > 0
          ? intValue(raw['currentEpisode'])
          : fallback,
      vip = raw['vip'] == true;
  final Map<String, dynamic> raw;
  final String id;
  final String title;
  final int number;
  final bool vip;
}

class DramaDetail {
  DramaDetail(this.drama, this.episodes, {this.warning = ''});
  final Drama drama;
  final List<Episode> episodes;
  final String warning;
  factory DramaDetail.fromJson(Map<String, dynamic> json) {
    final rows = json['chapters'] as List? ?? const [];
    return DramaDetail(
      Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
      [
        for (var i = 0; i < rows.length; i++)
          Episode(Map<String, dynamic>.from(rows[i] as Map), i + 1),
      ],
      warning: json['warning'] as String? ?? '',
    );
  }
}

class CatalogPage {
  CatalogPage(
    this.items, {
    this.hasMore = false,
    this.warning = '',
    this.page = 1,
    this.fresh = false,
  });
  final List<Drama> items;
  final bool hasMore;
  final String warning;
  final int page;
  final bool fresh;
  factory CatalogPage.fromJson(Map<String, dynamic> json) => CatalogPage(
    [
      for (final row in json['items'] as List? ?? const [])
        Drama.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    hasMore: json['hasMore'] == true,
    warning: json['warning'] as String? ?? '',
    page: intValue(json['page']) > 0 ? intValue(json['page']) : 1,
    fresh: json['fresh'] == true,
  );
}

class PlaybackPlan {
  const PlaybackPlan({
    required this.url,
    this.headers = const {},
    this.decryptionKey = '',
    this.quality = 0,
    this.qualities = const [],
    this.session = '',
    this.danmakuId = '',
    this.prefetchedBytes = 0,
    this.expiresAt = 0,
    this.routeIndex = 0,
    this.routeCount = 1,
    this.local = false,
  });
  final String url;
  final Map<String, String> headers;
  final String decryptionKey;
  final int quality;
  final List<int> qualities;
  final String session;
  final String danmakuId;
  final int prefetchedBytes;
  final int expiresAt;
  final int routeIndex;
  final int routeCount;
  final bool local;
  bool get hasAlternative => session.isNotEmpty && routeIndex + 1 < routeCount;
  factory PlaybackPlan.fromJson(Map<String, dynamic> json) => PlaybackPlan(
    url: json['url'] as String? ?? '',
    local: json['local'] == true,
    headers: (json['headers'] as Map? ?? {}).map(
      (key, value) => MapEntry(key.toString(), value.toString()),
    ),
    decryptionKey: json['decryptionKey'] as String? ?? '',
    quality: intValue(json['quality']),
    qualities: (json['qualities'] as List? ?? []).map(intValue).toSet().toList()
      ..sort((a, b) => b.compareTo(a)),
    session: json['session'] as String? ?? '',
    danmakuId: json['danmakuId'] as String? ?? '',
    prefetchedBytes: intValue(json['prefetchedBytes']),
    expiresAt: intValue(json['expiresAt']),
    routeIndex: intValue(json['routeIndex']),
    routeCount: intValue(json['routeCount']) > 0
        ? intValue(json['routeCount'])
        : 1,
  );
}

class WatchEntry {
  WatchEntry({
    required this.drama,
    required this.episode,
    required this.position,
    required this.duration,
    required this.updatedAt,
  });
  final Drama drama;
  final int episode;
  final double position;
  final double duration;
  final DateTime updatedAt;
  bool get finished => duration > 1 && position >= duration - 1;
  Map<String, dynamic> toJson() => {
    'drama': drama.toJson(),
    'episode': episode,
    'position': position,
    'duration': duration,
    'updatedAt': updatedAt.toIso8601String(),
  };
  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
    drama: Drama.fromJson(Map<String, dynamic>.from(json['drama'] as Map)),
    episode: intValue(json['episode']),
    position: (json['position'] as num?)?.toDouble() ?? 0,
    duration: (json['duration'] as num?)?.toDouble() ?? 0,
    updatedAt:
        DateTime.tryParse(json['updatedAt'].toString()) ?? DateTime(2000),
  );
}

class DownloadJob {
  const DownloadJob({
    required this.id,
    required this.drama,
    required this.episode,
    required this.state,
    this.bytes = 0,
    this.total = 0,
    this.progress = 0,
    this.quality = 0,
    this.actualQuality = 0,
    this.error = '',
    this.created = 0,
    this.revision = 0,
    this.archived = false,
  });
  final int created;
  final int revision;
  final bool archived;
  final String id;
  final Drama drama;
  final Episode episode;
  final String state;
  final int bytes;
  final int total;
  final double progress;
  final int quality;
  final int actualQuality;
  final String error;
  bool get completed => state == 'completed';
  bool get active => state == 'queued' || state == 'downloading';
  bool get resumable => state == 'paused' || state == 'failed';
  String get stateLabel => switch (state) {
    'queued' => '等待下载',
    'downloading' => '正在下载',
    'paused' => '已暂停',
    'failed' => '下载失败',
    'completed' => '已下载',
    'removing' => '正在取消',
    _ => '等待更新',
  };
  factory DownloadJob.fromJson(Map<String, dynamic> value) => DownloadJob(
    id: value['id'] as String? ?? '',
    drama: Drama.fromJson(Map<String, dynamic>.from(value['drama'] as Map)),
    episode: Episode(
      Map<String, dynamic>.from(value['chapter'] as Map),
      intValue(value['index']),
    ),
    state: value['state'] as String? ?? 'failed',
    bytes: intValue(value['bytes']),
    total: intValue(value['total']),
    progress: ((value['progress'] as num?)?.toDouble() ?? 0).clamp(0, 1),
    quality: intValue(value['quality']),
    actualQuality: intValue(value['actualQuality']),
    error: value['error'] as String? ?? '',
    created: intValue(value['created']),
    revision: intValue(value['revision']),
    archived: value['archived'] == true,
  );
}

List<Map<String, dynamic>> readJsonList(String? value) {
  try {
    return (jsonDecode(value ?? '[]') as List)
        .whereType<Map>()
        .map((row) => Map<String, dynamic>.from(row))
        .toList();
  } catch (_) {
    return [];
  }
}
