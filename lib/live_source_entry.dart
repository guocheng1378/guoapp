import 'dart:convert';

import 'http_headers.dart';

/// 一条自填直播源订阅。
///
/// 快照里 `liveSources` 始终是**一个 JSON 字符串**（LocalSnapshot._validate
/// 强制该键为 String），数组元素兼容旧版的纯 URL 字符串与本版的描述对象。
/// [payload] 非空表示内联订阅正文（TVBox 配置里直接内嵌 channels），
/// 这类条目不发起 HTTP 请求，由 Go 核心直接解析。
class LiveSourceEntry {
  const LiveSourceEntry({
    required this.url,
    this.agent = '',
    this.headers = const <String, String>{},
    this.payload = '',
    this.label = '',
    this.epg = '',
  });

  final String url;
  final String agent;
  final Map<String, String> headers;
  final String payload;
  final String label;

  /// 该订阅关联的 xmltv 节目单地址（TVBox 的 lives[].epg 或用户手填）。
  /// 为空表示不做 EPG，不产生任何额外请求。
  final String epg;

  bool get isInline => payload.isNotEmpty;
  bool get hasCustomHttp => agent.isNotEmpty || headers.isNotEmpty;
  bool get hasEpg => epg.isNotEmpty;

  String get displayLabel {
    if (!isInline) return url;
    return label.isEmpty ? 'TVBox 内嵌频道' : label;
  }

  /// 下发给 Go 核心（live.channels 的 liveSources 段）。
  /// UA 统一合进 headers，核心只认一张头表。
  Map<String, dynamic> toPayload() {
    final effective = mergeUserAgent(headers, agent);
    return <String, dynamic>{
      'url': url,
      if (effective.isNotEmpty) 'headers': effective,
      if (payload.isNotEmpty) 'payload': payload,
    };
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'url': url,
    if (agent.isNotEmpty) 'agent': agent,
    if (headers.isNotEmpty) 'headers': headers,
    if (payload.isNotEmpty) 'payload': payload,
    if (label.isNotEmpty) 'label': label,
    if (epg.isNotEmpty) 'epg': epg,
  };

  LiveSourceEntry copyWith({
    String? url,
    String? agent,
    Map<String, String>? headers,
    String? payload,
    String? label,
    String? epg,
  }) => LiveSourceEntry(
    url: url ?? this.url,
    agent: agent ?? this.agent,
    headers: headers ?? this.headers,
    payload: payload ?? this.payload,
    label: label ?? this.label,
    epg: epg ?? this.epg,
  );

  /// 防御性反序列化：旧版 String、新版 Map；结构不合法返回 null。
  static LiveSourceEntry? fromJson(Object? row) {
    if (row is String) {
      final url = row.trim();
      return url.isEmpty ? null : LiveSourceEntry(url: url);
    }
    if (row is! Map) return null;
    final url = row['url'];
    if (url is! String) return null;
    final cleanUrl = url.trim();
    if (cleanUrl.isEmpty) return null;
    final rawHeaders = row['headers'] ?? row['header'];
    final headers = parseHttpHeaders(rawHeaders);
    final agent = sanitizeUserAgent(
      (row['agent'] ?? row['ua'] ?? '').toString(),
    );
    return LiveSourceEntry(
      url: cleanUrl,
      agent: agent,
      headers: mergeUserAgent(headers, agent),
      payload: row['payload'] is String ? row['payload'] as String : '',
      label: row['label'] is String ? row['label'] as String : '',
      epg: sanitizeEpgUrl(row['epg']),
    );
  }

  /// EPG 只接受 http(s)：非法/空值静默丢弃，避免把脏数据带进快照与核心。
  static String sanitizeEpgUrl(Object? raw) {
    final text = raw is String ? raw.trim() : '';
    if (text.isEmpty) return '';
    final uri = Uri.tryParse(text);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return '';
    }
    return text;
  }

  /// 从列表快照解码：坏条目跳过，旧 String 自动升级。
  static List<LiveSourceEntry> decodeList(String? raw) {
    if (raw == null || raw.trim().isEmpty) return <LiveSourceEntry>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return <LiveSourceEntry>[];
      final out = <LiveSourceEntry>[];
      for (final row in decoded) {
        final entry = LiveSourceEntry.fromJson(row);
        if (entry != null) out.add(entry);
      }
      return out;
    } catch (_) {
      return <LiveSourceEntry>[];
    }
  }

  static String encodeList(List<LiveSourceEntry> entries) =>
      jsonEncode([for (final entry in entries) entry.toJson()]);
}
