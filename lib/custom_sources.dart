import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/models.dart';

import 'http_headers.dart';

/// 本机自定义站源（maccms 兼容接口）。
///
/// 管理员在站源管理页添加；ID 由地址摘要生成（`custom-<hex>`），持久化在
/// 本地配置快照的设备级全局键 `customSources`，启动与每次增删后全量下发
/// Go 核心（config.source 的 customSources 段，Go 侧上限 16 个并做同规则
/// 校验，Dart 端先本地校验保证 UI 即时反馈与核心侧一致）。
class CustomSourceSpec {
  const CustomSourceSpec({
    required this.id,
    required this.name,
    required this.url,
    this.category = 'shortDrama',
    this.typeId = '',
    this.agent = '',
    this.headers = const <String, String>{},
    this.localPackage = false,
  });

  /// `custom-` 前缀 + 12 位小写 hex，与 Go 端 `^custom-[a-z0-9]{4,40}$` 对齐。
  final String id;
  final String name;
  final String url;

  /// shortDrama / video / adult（Go 端三枚举，缺省 shortDrama）。
  final String category;

  /// 源站分类 ID（maccms type_id），可空。
  final String typeId;

  /// 自定义 UA（TVBox 的 `ua` 字段）；下发时合进 [effectiveHeaders]。
  final String agent;

  /// 自定义请求头（TVBox 的 `header` 字段，已做安全过滤）。
  final Map<String, String> headers;

  /// 由本地配置文件包（手机里的 TVBox .json/.txt 离线导入）创建。
  /// 只影响界面分区（归「本地类」，与短剧类/视频类并列），
  /// [toPayload] 不下发该字段，Go 核心仍按真实 [category] 处理。
  final bool localPackage;

  /// 实际下发 Go 核心的头表：显式 User-Agent 优先，否则用 [agent] 补位。
  Map<String, String> get effectiveHeaders =>
      mergeUserAgent(headers, sanitizeUserAgent(agent));

  static const int maxSources = 16;
  // 分类清单与显示名统一由 SourceCategory / SourceSite.classLabel 提供：
  // 旧实现手写三值清单 + 另一套 switch，默认档还与 classLabel 相反
  // （这里默认「短剧类」、那里默认「视频类」），自定义源写错 category
  // 时会在菜单/管理页/榜单页分属不同类。
  /// 手工添加站源时可选的内容类型；「本地类」只由本地配置包导入产生，
  /// 不开放手选。
  static final List<String> categories = [
    for (final category in SourceCategory.values)
      if (category != SourceCategory.local) category.name,
  ];

  static String categoryLabel(String category) =>
      SourceSite.classLabel(category);

  /// 由地址生成本机唯一 ID。
  static String idFor(String url) =>
      'custom-${sha256.convert(utf8.encode(url)).toString().substring(0, 12)}';

  /// 把站源地址归一化为苹果 CMS 根地址。
  ///
  /// Go 核心会自行拼接 `/api.php/provide/vod/?ac=list...`，而 TVBox 配置的
  /// `api` 字段常是完整接口地址（如 `https://host/api.php/provide/vod/?ac=videolist`），
  /// 直接当根地址会拼出双段 `/api.php/provide/vod/api.php/provide/vod/`。
  /// 这里识别并截掉接口路径，同时保留子目录部署的站点根（如 `/maccms`）。
  /// 非法地址原样返回，交由 [validate] 报错。
  static String normalizeUrl(String raw) {
    final trimmed = raw.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null ||
        uri.host.isEmpty ||
        (uri.scheme != 'http' && uri.scheme != 'https')) {
      return trimmed;
    }
    final segments = uri.pathSegments
        .where((segment) => segment.isNotEmpty)
        .toList(growable: false);
    var cut = -1;
    for (var i = 0; i < segments.length; i++) {
      if (segments[i].toLowerCase() == 'api.php') {
        cut = i;
        break;
      }
    }
    if (cut < 0) {
      for (var i = 0; i + 1 < segments.length; i++) {
        if (segments[i].toLowerCase() == 'provide' &&
            segments[i + 1].toLowerCase() == 'vod') {
          cut = i;
          break;
        }
      }
    }
    final kept = cut >= 0 ? segments.take(cut) : segments;
    final path = kept.isEmpty ? '' : '/${kept.join('/')}';
    return '${uri.origin}$path';
  }

  /// 校验规则与 Go 端对齐；返回错误文案，null 表示通过。
  static String? validate({
    required String name,
    required String url,
    required String category,
    String typeId = '',
    String agent = '',
    Map<String, String> headers = const <String, String>{},
  }) {
    final trimmedName = name.trim();
    if (trimmedName.isEmpty) {
      return '请填写站源名称';
    }
    if (trimmedName.length > 32) {
      return '站源名称不能超过 32 个字符';
    }
    final base = Uri.tryParse(url.trim());
    if (base == null ||
        base.host.isEmpty ||
        (base.scheme != 'http' && base.scheme != 'https')) {
      return '请填写合法的 http(s) 站源地址';
    }
    if (!categories.contains(category)) {
      return '请选择站源分类';
    }
    final trimmedTypeId = typeId.trim();
    if (trimmedTypeId.length > 32 ||
        !RegExp(r'^[0-9A-Za-z_-]*$').hasMatch(trimmedTypeId)) {
      return '分类 ID 仅支持字母数字下划线短横线（不超过 32 位）';
    }
    return validateHttpHeaders(
      mergeUserAgent(headers, sanitizeUserAgent(agent)),
    );
  }

  /// 下发 Go 核心的 payload（config.source 的 customSources 段条目）。
  /// UA 合进 headers，核心只认一张头表。
  Map<String, dynamic> toPayload() {
    final effective = effectiveHeaders;
    return <String, dynamic>{
      'id': id,
      'name': name,
      'url': url,
      'category': category,
      'typeId': typeId,
      if (effective.isNotEmpty) 'headers': effective,
    };
  }

  /// 持久化用：在核心 payload 之上附带本机专属的本地包标记。
  Map<String, dynamic> toJson() => <String, dynamic>{
    ...toPayload(),
    if (localPackage) 'localPackage': true,
  };

  /// 防御性反序列化；结构不合法返回 null（调用方跳过该条目）。
  static CustomSourceSpec? fromJson(Object? row) {
    if (row is! Map) {
      return null;
    }
    final id = row['id'];
    final name = row['name'];
    final url = row['url'];
    if (id is! String || name is! String || url is! String) {
      return null;
    }
    if (!id.startsWith('custom-') || name.trim().isEmpty) {
      return null;
    }
    final category = row['category'];
    final typeId = row['typeId'];
    return CustomSourceSpec(
      id: id,
      name: name,
      url: url,
      category: category is String ? category : 'shortDrama',
      typeId: typeId is String ? typeId : '',
      headers: parseHttpHeaders(row['headers'] ?? row['header']),
      localPackage: row['localPackage'] == true,
    );
  }

  SourceCategory? get sourceCategory {
    if (localPackage) return SourceCategory.local;
    return switch (category) {
      'video' => SourceCategory.video,
      'adult' => SourceCategory.adult,
      'shortDrama' => SourceCategory.shortDrama,
      _ => null,
    };
  }

  /// 转成站源菜单/管理页通用的 [SourceSite] 实例（分类经覆盖携带）。
  SourceSite toSourceSite() => SourceSite(
    id,
    name,
    '自定义 · maccms 接口',
    categoryOverride: sourceCategory,
  );
}
