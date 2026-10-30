import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:duanju_app/models.dart';

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
  });

  /// `custom-` 前缀 + 12 位小写 hex，与 Go 端 `^custom-[a-z0-9]{4,40}$` 对齐。
  final String id;
  final String name;
  final String url;

  /// shortDrama / video / adult（Go 端三枚举，缺省 shortDrama）。
  final String category;

  /// 源站分类 ID（maccms type_id），可空。
  final String typeId;

  static const int maxSources = 16;
  static const List<String> categories = ['shortDrama', 'video', 'adult'];

  static String categoryLabel(String category) => switch (category) {
    'video' => '视频类',
    'adult' => '成人类',
    _ => '短剧类',
  };

  /// 由地址生成本机唯一 ID。
  static String idFor(String url) =>
      'custom-${sha256.convert(utf8.encode(url)).toString().substring(0, 12)}';

  /// 校验规则与 Go 端对齐；返回错误文案，null 表示通过。
  static String? validate({
    required String name,
    required String url,
    required String category,
    String typeId = '',
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
    return null;
  }

  /// 下发 Go 核心的 payload（config.source 的 customSources 段条目）。
  Map<String, String> toPayload() => {
    'id': id,
    'name': name,
    'url': url,
    'category': category,
    'typeId': typeId,
  };

  Map<String, String> toJson() => toPayload();

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
    );
  }

  SourceCategory? get sourceCategory => switch (category) {
    'video' => SourceCategory.video,
    'adult' => SourceCategory.adult,
    'shortDrama' => SourceCategory.shortDrama,
    _ => null,
  };

  /// 转成站源菜单/管理页通用的 [SourceSite] 实例（分类经覆盖携带）。
  SourceSite toSourceSite() => SourceSite(
    id,
    name,
    '自定义 · maccms 接口',
    categoryOverride: sourceCategory,
  );
}
