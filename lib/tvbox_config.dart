import 'dart:convert';

import 'custom_sources.dart';
import 'http_headers.dart';
import 'live_source_entry.dart';

/// TVBox 配置里一条可导入的苹果 CMS 站点（已归一化为根地址）。
class TvboxSite {
  const TvboxSite({
    required this.name,
    required this.url,
    required this.category,
    this.typeId = '',
    this.headers = const <String, String>{},
  });

  final String name;
  final String url;
  final String category;
  final String typeId;

  /// TVBox 的 ua / header 已合并成一张头表，随站源下发 Go 核心。
  final Map<String, String> headers;
}

/// 被跳过或忽略的配置项，导入前明确告知用户原因。
class TvboxNotice {
  const TvboxNotice(this.label, this.reason);

  final String label;
  final String reason;
}

/// 一次导入的可执行计划：只含本应用真正能消费的两类数据。
class TvboxImportPlan {
  const TvboxImportPlan({
    this.sites = const [],
    this.liveSources = const [],
    this.notices = const [],
    this.localPackage = false,
  });

  final List<TvboxSite> sites;
  final List<LiveSourceEntry> liveSources;
  final List<TvboxNotice> notices;

  /// 配置来自手机本地文件包（而非粘贴 / 接口地址）：导入的站源归「本地类」。
  final bool localPackage;

  bool get isEmpty => sites.isEmpty && liveSources.isEmpty;
}

class TvboxConfigException implements Exception {
  const TvboxConfigException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 解析 TVBox 配置 JSON（明文或带注释的 JSONC）。
///
/// 只导入两类内容：
/// - `sites[]` 中带 http(s) 苹果 CMS 接口的站点（转成自定义站源）；
/// - `lives[]` 中指向 m3u/m3u8/txt 订阅的 http(s) 链接。
///
/// 爬虫 jar / drpy / csp_ 类站点、内嵌 `channels`、非 CMS 接口一律跳过，
/// 并在 [TvboxImportPlan.notices] 里逐条给出原因。TVBox 的 `type` 只决定
/// 客户端如何解析其 api 返回，本项目会自行拼 `ac=list` 的 JSON 请求，因此
/// type 0/1 的 CMS 站点都可导入。
class TvboxConfigParser {
  const TvboxConfigParser._();

  static TvboxImportPlan parse(String raw, {bool localPackage = false}) {
    final text = raw.replaceFirst('\uFEFF', '').trim();
    if (text.isEmpty) {
      throw const TvboxConfigException('请先粘贴 TVBox 配置内容');
    }
    final decoded = _decode(text);
    if (decoded is! Map) {
      throw const TvboxConfigException('配置根节点必须是 JSON 对象');
    }
    final root = Map<String, dynamic>.from(decoded);
    if (!root.containsKey('sites') && !root.containsKey('lives')) {
      throw const TvboxConfigException('配置里没有 sites / lives 字段，可能不是 TVBox 配置');
    }
    final notices = <TvboxNotice>[];
    final sites = _sites(root['sites'], notices);
    final liveSources = _lives(root, notices);
    if (_present(root['spider'])) {
      notices.add(
        const TvboxNotice('spider', '爬虫 jar 及其站点已忽略（本项目无法执行 Java/JS 爬虫）'),
      );
    }
    if (['parse', 'flags', 'ijk', 'ads', 'proxy', 'wallpaper', 'doors']
        .any((key) => _present(root[key]))) {
      notices.add(
        const TvboxNotice('其它配置', '解析/嗅探/播放器/代理等 TVBox 专属参数已忽略'),
      );
    }
    return TvboxImportPlan(
      sites: sites,
      liveSources: liveSources,
      notices: notices,
      localPackage: localPackage,
    );
  }

  static Object? _decode(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      try {
        return jsonDecode(_stripComments(text));
      } catch (_) {
        if (RegExp(r'^[A-Za-z0-9+/=\s]+$').hasMatch(text) && text.length > 40) {
          throw const TvboxConfigException(
            '这份配置经过加密或 Base64 编码，请粘贴解密后的明文 JSON',
          );
        }
        if (text.startsWith('http://') || text.startsWith('https://')) {
          throw const TvboxConfigException(
            '这是一条接口地址，但取回的内容不是 JSON 配置（可能已失效或需要登录）',
          );
        }
        throw const TvboxConfigException('无法解析为 JSON 配置');
      }
    }
  }

  /// 去掉 `//` 与 `/* */` 注释（跳过字符串内部），TVBox 配置常带这类注释。
  static String _stripComments(String text) {
    final buffer = StringBuffer();
    var inString = false;
    var escaped = false;
    for (var i = 0; i < text.length; i++) {
      final char = text[i];
      if (inString) {
        buffer.write(char);
        if (escaped) {
          escaped = false;
        } else if (char == r'\') {
          escaped = true;
        } else if (char == '"') {
          inString = false;
        }
        continue;
      }
      if (char == '"') {
        inString = true;
        buffer.write(char);
        continue;
      }
      if (char == '/' && i + 1 < text.length && text[i + 1] == '/') {
        while (i < text.length && text[i] != '\n') {
          i++;
        }
        if (i < text.length) buffer.write('\n');
        continue;
      }
      if (char == '/' && i + 1 < text.length && text[i + 1] == '*') {
        i += 2;
        while (i + 1 < text.length && !(text[i] == '*' && text[i + 1] == '/')) {
          if (text[i] == '\n') buffer.write('\n');
          i++;
        }
        i++;
        continue;
      }
      buffer.write(char);
    }
    return buffer.toString();
  }

  static List<TvboxSite> _sites(Object? raw, List<TvboxNotice> notices) {
    final out = <TvboxSite>[];
    if (raw == null) return out;
    if (raw is! List) {
      notices.add(const TvboxNotice('sites', '字段不是数组，已忽略'));
      return out;
    }
    final seen = <String>{};
    for (var i = 0; i < raw.length; i++) {
      final row = raw[i];
      if (row is! Map) {
        notices.add(TvboxNotice('站点 #${i + 1}', '条目格式无效，已跳过'));
        continue;
      }
      final entry = Map<String, dynamic>.from(row);
      final label = _label(entry, '站点 #${i + 1}');
      if (_present(entry['jar']) || _present(entry['spider'])) {
        notices.add(TvboxNotice(label, '需要爬虫 jar / JS 引擎，已跳过'));
        continue;
      }
      final api = entry['api'];
      if (api is! String || api.trim().isEmpty) {
        notices.add(TvboxNotice(label, '没有 http(s) 接口地址，已跳过'));
        continue;
      }
      final uri = Uri.tryParse(api.trim());
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        notices.add(
          TvboxNotice(label, '接口不是 http(s) 地址（爬虫标记如 csp_ / drpy），已跳过'),
        );
        continue;
      }
      if (!_looksLikeCms(uri)) {
        notices.add(
          TvboxNotice(label, '非苹果 CMS 接口（api.php/provide/vod），已跳过'),
        );
        continue;
      }
      final url = CustomSourceSpec.normalizeUrl(api.trim());
      if (seen.contains(url)) {
        notices.add(TvboxNotice(label, '站点地址与已导入项重复，已跳过'));
        continue;
      }
      seen.add(url);
      final category = _category(entry);
      final headers = _siteHeaders(entry);
      out.add(
        TvboxSite(
          name: _name(entry, i),
          url: url,
          category: category,
          typeId: _typeId(entry, uri),
          headers: headers,
        ),
      );
      if (entry['type'].toString() == '0') {
        notices.add(
          TvboxNotice(label, '标注为 XML（type=0），本项目按 JSON 请求，可能无数据'),
        );
      }
      if (category == 'adult') {
        notices.add(TvboxNotice(label, '归入成人类，默认隐藏（需彩蛋解锁）'));
      }
      if (headers.isNotEmpty) {
        notices.add(TvboxNotice(label, '已携带 ${headers.length} 条自定义请求头'));
      }
    }
    return out;
  }

  /// 把 TVBox 的 ua / header 合成为一张头表，并裁到核心允许的上限。
  static Map<String, String> _siteHeaders(Map<String, dynamic> entry) {
    final agent = sanitizeUserAgent((entry['ua'] ?? '').toString());
    final merged = mergeUserAgent(
      parseHttpHeaders(entry['header'] ?? entry['headers']),
      agent,
    );
    if (merged.length <= 8) return merged;
    return Map<String, String>.fromEntries(merged.entries.take(8));
  }

  /// 判断 api 是否像苹果 CMS 接口：显式接口路径/参数、纯域名、或子目录部署。
  static bool _looksLikeCms(Uri uri) {
    final path = uri.path.toLowerCase();
    if (path.contains('api.php') || path.contains('provide/vod')) return true;
    if (uri.query.toLowerCase().contains('ac=')) return true;
    if (path.contains('/api/') || path.endsWith('.json')) return false;
    if (path.endsWith('.php')) return false;
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .length;
    return segments <= 2;
  }

  static List<LiveSourceEntry> _lives(
    Map<String, dynamic> root,
    List<TvboxNotice> notices,
  ) {
    final out = <LiveSourceEntry>[];
    final seen = <String>{};

    void add(
      String? value,
      String label, {
      Map<String, String> headers = const <String, String>{},
      String epg = '',
    }) {
      final url = (value ?? '').trim();
      if (url.isEmpty) return;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.host.isEmpty ||
          (uri.scheme != 'http' && uri.scheme != 'https')) {
        notices.add(TvboxNotice(label, '不是 http(s) 订阅链接，已跳过'));
        return;
      }
      if (seen.contains(url)) return;
      seen.add(url);
      out.add(LiveSourceEntry(url: url, headers: headers, epg: epg));
    }

    // 配置里直接内嵌的 channels 不发起 HTTP，序列化成内联订阅正文交给 Go 解析。
    void addInline(String label, Object? rawChannels, {String epg = ''}) {
      final channels = normalizeLiveChannels(rawChannels);
      if (channels.isEmpty) {
        notices.add(TvboxNotice(label, '内嵌频道列表为空或格式无效，已跳过'));
        return;
      }
      final url = 'inline:${out.length}';
      if (seen.contains(url)) return;
      seen.add(url);
      out.add(
        LiveSourceEntry(
          url: url,
          label: label,
          payload: jsonEncode({'channels': channels}),
          epg: epg,
        ),
      );
      notices.add(
        TvboxNotice(label, '内嵌 ${channels.length} 个频道已作为内联订阅导入'),
      );
    }

    final raw = root['lives'];
    if (raw is List) {
      for (var i = 0; i < raw.length; i++) {
        final row = raw[i];
        final label = '直播源 #${i + 1}';
        if (row is String) {
          add(row, label);
          continue;
        }
        if (row is! Map) {
          notices.add(TvboxNotice(label, '条目格式无效，已跳过'));
          continue;
        }
        final entry = Map<String, dynamic>.from(row);
        final name = (entry['name'] ?? entry['group'] ?? label).toString();
        final headers = _siteHeaders(entry);
        // EPG 地址随订阅保存，直播页有节目单时才会发起请求。
        final epg = LiveSourceEntry.sanitizeEpgUrl(entry['epg']);
        if (entry['channels'] is List) {
          addInline(name, entry['channels'], epg: epg);
        } else {
          final url = entry['url'];
          if (url is! String || url.trim().isEmpty) {
            notices.add(TvboxNotice(name, '没有订阅链接，已跳过'));
            continue;
          }
          add(url, name, headers: headers, epg: epg);
        }
        if (headers.isNotEmpty) {
          notices.add(
            TvboxNotice(name, '已携带 ${headers.length} 条自定义请求头'),
          );
        }
        if (_present(entry['epg'])) {
          notices.add(
            epg.isEmpty
                ? TvboxNotice(name, 'EPG 地址不是 http(s)，已忽略')
                : TvboxNotice(name, '已关联节目单（EPG）'),
          );
        }
        if (entry['type'].toString() == '1') {
          notices.add(TvboxNotice(name, '代理型订阅（type=1）按直连处理'));
        }
      }
    } else if (raw is String) {
      add(raw, 'lives');
    }
    for (final key in const ['liveUrl', 'live', 'iptv']) {
      final value = root[key];
      if (value is String) add(value, key);
    }
    if (out.isNotEmpty) {
      notices.add(
        const TvboxNotice(
          '直播订阅',
          '支持 m3u/m3u8/txt 与 JSON 频道列表（含配置内嵌 channels）',
        ),
      );
    }
    return out;
  }

  /// TVBox 内嵌 channels 规整成 Go 侧可解析的统一结构。
  static List<Map<String, dynamic>> normalizeLiveChannels(Object? raw) {
    final out = <Map<String, dynamic>>[];
    if (raw is! List) return out;
    for (final row in raw) {
      if (row is! Map) continue;
      final entry = Map<String, dynamic>.from(row);
      final name = (entry['name'] ?? entry['title'] ?? '').toString().trim();
      final urls = <String>[];
      final rawUrls = entry['urls'] ?? entry['url'] ?? entry['lines'];
      if (rawUrls is List) {
        for (final value in rawUrls) {
          if (value is String && value.trim().isNotEmpty) {
            urls.add(value.trim());
          }
        }
      } else if (rawUrls is String) {
        for (final part in rawUrls.split('#')) {
          if (part.trim().isNotEmpty) urls.add(part.trim());
        }
      }
      if (name.isEmpty || urls.isEmpty) continue;
      out.add(<String, dynamic>{
        'name': name,
        'group': (entry['group'] ?? entry['groupName'] ?? '')
            .toString()
            .trim(),
        'urls': urls.take(8).toList(),
      });
      if (out.length >= 3000) break;
    }
    return out;
  }

  /// TVBox 的 ext 可能是对象、JSON 字符串、纯数字或 `type_id=1&...`。
  static String _typeId(Map<String, dynamic> entry, Uri uri) {
    String? raw;
    final ext = entry['ext'];
    if (ext is Map) {
      raw = _pickTypeId(Map<String, dynamic>.from(ext));
    } else if (ext is String) {
      final text = ext.trim();
      if (text.startsWith('{')) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map) {
            raw = _pickTypeId(Map<String, dynamic>.from(decoded));
          }
        } catch (_) {}
      } else if (RegExp(r'^\d+$').hasMatch(text)) {
        raw = text;
      } else {
        raw = RegExp(
          r'(?:type_?id|t|cate_?id)\s*=\s*([0-9A-Za-z_-]+)',
          caseSensitive: false,
        ).firstMatch(text)?.group(1);
      }
    }
    if (raw == null) {
      for (final key in const ['type_id', 't', 'typeId', 'cate_id']) {
        final value = uri.queryParameters[key];
        if (value != null && value.isNotEmpty) {
          raw = value;
          break;
        }
      }
    }
    if (raw == null) {
      final direct = entry['type_id'] ?? entry['typeId'];
      if (direct != null) raw = direct.toString();
    }
    final clean = (raw ?? '').trim();
    if (clean.length > 32 || !RegExp(r'^[0-9A-Za-z_-]*$').hasMatch(clean)) {
      return '';
    }
    return clean;
  }

  static String? _pickTypeId(Map<String, dynamic> map) {
    for (final key in const ['type_id', 'typeId', 't', 'cate_id', 'cateId']) {
      final value = map[key];
      if (value != null && value.toString().trim().isNotEmpty) {
        return value.toString().trim();
      }
    }
    return null;
  }

  /// 上游站点的固定归类：这些名字既不含「短剧/成人」关键词，也不能靠
  /// 关键词猜（例如「禁果短剧」会被短剧规则抢走），必须精确点名。
  /// 黄果系（禁果短剧）在站源表里另由 huangguoCategoryIds 抬到黄果类，
  /// 这里只定它的底层内容类型。
  static const _sourceCategoryByName = <String, String>{
    '笔盒': 'adult',
    '禁果短剧': 'shortDrama',
    '韩小圈': 'video',
  };

  static String _category(Map<String, dynamic> entry) {
    final name = (entry['name'] ?? '').toString().trim();
    final pinned = _sourceCategoryByName[name];
    if (pinned != null) return pinned;
    final words = <String>[];
    final categories = entry['categories'];
    if (categories is List) {
      words.addAll(categories.map((item) => item.toString()));
    } else if (categories is String) {
      words.add(categories);
    }
    words.add(name);
    final joined = words.join(' ').toLowerCase();
    if (joined.contains('短剧')) return 'shortDrama';
    if (joined.contains('成人') ||
        joined.contains('伦理') ||
        joined.contains('福利')) {
      return 'adult';
    }
    return 'video';
  }

  static String _name(Map<String, dynamic> entry, int index) {
    final raw = (entry['name'] ?? entry['key'] ?? '').toString();
    final cleaned = String.fromCharCodes(
      raw.runes.where((rune) => rune >= 0x20 && rune != 0x7f),
    ).trim();
    if (cleaned.isEmpty) return 'TVBox 站点 ${index + 1}';
    return String.fromCharCodes(cleaned.runes.take(32));
  }

  static String _label(Map<String, dynamic> entry, String fallback) {
    final raw = (entry['name'] ?? entry['key'] ?? '').toString().trim();
    if (raw.isEmpty) return fallback;
    return raw.length > 24 ? '${raw.substring(0, 24)}…' : raw;
  }

  static bool _present(Object? value) {
    if (value == null) return false;
    if (value is String) return value.trim().isNotEmpty;
    if (value is Map) return value.isNotEmpty;
    if (value is List) return value.isNotEmpty;
    return true;
  }
}
