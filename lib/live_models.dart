import 'models.dart';

/// 电视直播数据模型（2026-10-22）：与 Go core `live.channels` 响应对齐。
/// 响应形状：{listId, lists:[{id,name}], groups:[{name, channels:[…]}],
/// channelCount, fetchedAt(RFC3339|''), stale, warning}。
class LiveList {
  const LiveList({required this.id, required this.name});
  final String id;
  final String name;
  factory LiveList.fromJson(Map<String, dynamic> json) => LiveList(
    id: json['id'] as String? ?? '',
    name: json['name'] as String? ?? '',
  );
}

class LiveChannel {
  const LiveChannel({
    required this.name,
    this.group = '',
    this.logo = '',
    this.tvgId = '',
    this.urls = const [],
  });
  final String name;
  final String group;
  final String logo;

  /// m3u 的 tvg-id（EPG 匹配的第一优先级）；txt/JSON 订阅通常为空。
  final String tvgId;
  final List<String> urls;
  bool get playable => urls.isNotEmpty;
  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    name: json['name'] as String? ?? '',
    group: json['group'] as String? ?? '',
    logo: json['logo'] as String? ?? '',
    tvgId: json['tvgId'] as String? ?? '',
    urls: [
      for (final url in json['urls'] as List? ?? const [])
        if (url is String && url.trim().isNotEmpty) url.trim(),
    ],
  );
}

class LiveGroup {
  const LiveGroup({required this.name, required this.channels});
  final String name;
  final List<LiveChannel> channels;
  factory LiveGroup.fromJson(Map<String, dynamic> json) => LiveGroup(
    name: json['name'] as String? ?? '',
    channels: [
      for (final row in json['channels'] as List? ?? const [])
        LiveChannel.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
  );
}

/// 电子节目单（EPG）一档节目。
///
/// 时间来自 xmltv 原文（带时区偏移），解析后统一转本地时间；缺 stop 时按
/// 「开始后 30 分钟」估算，避免进度条除零。
class LiveProgram {
  const LiveProgram({
    required this.title,
    required this.start,
    this.stop,
    this.desc = '',
  });
  final String title;
  final String desc;
  final DateTime start;
  final DateTime? stop;

  Duration get duration =>
      stop?.difference(start) ?? const Duration(minutes: 30);

  bool isOnAir(DateTime now) =>
      !start.isAfter(now) && start.add(duration).isAfter(now);

  /// 0~1 的播放进度，用于节目进度条。
  double progressAt(DateTime now) {
    final total = duration.inSeconds;
    if (total <= 0) return 0;
    final passed = now.difference(start).inSeconds;
    if (passed <= 0) return 0;
    if (passed >= total) return 1;
    return passed / total;
  }

  factory LiveProgram.fromJson(Map<String, dynamic> json) {
    final start = DateTime.tryParse(json['start'] as String? ?? '');
    return LiveProgram(
      title: json['title'] as String? ?? '',
      desc: json['desc'] as String? ?? '',
      start: (start ?? DateTime.now()).toLocal(),
      stop: DateTime.tryParse(json['stop'] as String? ?? '')?.toLocal(),
    );
  }
}

/// 单个频道的节目单：正在播 / 下一档 / 当日节目表。
class LiveEpgChannel {
  const LiveEpgChannel({
    required this.name,
    this.tvgId = '',
    this.matched = false,
    this.match = '',
    this.now,
    this.next,
    this.programs = const [],
  });
  final String name;
  final String tvgId;
  final bool matched;
  final String match;
  final LiveProgram? now;
  final LiveProgram? next;
  final List<LiveProgram> programs;

  LiveProgram? programAt(DateTime moment) {
    for (final program in programs) {
      if (program.isOnAir(moment)) return program;
    }
    return null;
  }

  factory LiveEpgChannel.fromJson(Map<String, dynamic> json) => LiveEpgChannel(
    name: json['name'] as String? ?? '',
    tvgId: json['tvgId'] as String? ?? '',
    matched: json['matched'] == true,
    match: json['match'] as String? ?? '',
    now: json['now'] is Map
        ? LiveProgram.fromJson(Map<String, dynamic>.from(json['now'] as Map))
        : null,
    next: json['next'] is Map
        ? LiveProgram.fromJson(Map<String, dynamic>.from(json['next'] as Map))
        : null,
    programs: [
      for (final row in json['programs'] as List? ?? const [])
        if (row is Map) LiveProgram.fromJson(Map<String, dynamic>.from(row)),
    ],
  );
}

/// 一次 EPG 查询结果。没有配置 EPG 源时是 [LiveEpg.empty]，所有 UI 自然降级。
class LiveEpg {
  const LiveEpg({
    this.channels = const [],
    this.fetchedAt = '',
    this.warning = '',
    this.cached = false,
  });
  final List<LiveEpgChannel> channels;
  final String fetchedAt;
  final String warning;
  final bool cached;

  static const LiveEpg empty = LiveEpg();

  bool get isEmpty => channels.isEmpty;

  /// 按 tvg-id 优先、台名兜底查找（与 Go 侧的匹配优先级一致）。
  LiveEpgChannel? find(String name, {String tvgId = ''}) {
    if (channels.isEmpty) return null;
    if (tvgId.isNotEmpty) {
      for (final channel in channels) {
        if (channel.tvgId.isNotEmpty && channel.tvgId == tvgId) return channel;
      }
    }
    for (final channel in channels) {
      if (channel.name == name) return channel;
    }
    return null;
  }

  factory LiveEpg.fromJson(Map<String, dynamic> json) => LiveEpg(
    channels: [
      for (final row in json['channels'] as List? ?? const [])
        if (row is Map) LiveEpgChannel.fromJson(Map<String, dynamic>.from(row)),
    ],
    fetchedAt: json['fetchedAt'] as String? ?? '',
    warning: json['warning'] as String? ?? '',
    cached: json['cached'] == true,
  );
}

class LivePage {
  const LivePage({
    this.listId = '',
    this.lists = const [],
    this.groups = const [],
    this.channelCount = 0,
    this.fetchedAt = '',
    this.stale = false,
    this.warning = '',
  });
  final String listId;
  final List<LiveList> lists;
  final List<LiveGroup> groups;
  final int channelCount;
  final String fetchedAt;
  final bool stale;
  final String warning;
  bool get isEmpty => groups.isEmpty;
  factory LivePage.fromJson(Map<String, dynamic> json) => LivePage(
    listId: json['listId'] as String? ?? '',
    lists: [
      for (final row in json['lists'] as List? ?? const [])
        LiveList.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    groups: [
      for (final row in json['groups'] as List? ?? const [])
        LiveGroup.fromJson(Map<String, dynamic>.from(row as Map)),
    ],
    channelCount: intValue(json['channelCount']),
    fetchedAt: json['fetchedAt'] as String? ?? '',
    stale: json['stale'] == true,
    warning: json['warning'] as String? ?? '',
  );
}
