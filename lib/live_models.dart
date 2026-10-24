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
    this.urls = const [],
  });
  final String name;
  final String group;
  final String logo;
  final List<String> urls;
  bool get playable => urls.isNotEmpty;
  factory LiveChannel.fromJson(Map<String, dynamic> json) => LiveChannel(
    name: json['name'] as String? ?? '',
    group: json['group'] as String? ?? '',
    logo: json['logo'] as String? ?? '',
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
