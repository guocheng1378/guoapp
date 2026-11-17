import 'dart:convert';

/// TVBox 配置里的 `ua` / `header` 形态很杂：对象、JSON 字符串、
/// `Key: Value` 多行文本。统一归一成请求头表并做安全过滤。
Map<String, String> parseHttpHeaders(Object? raw) {
  final out = <String, String>{};
  if (raw is Map) {
    raw.forEach((key, value) => _addHeader(out, key, value));
    return out;
  }
  if (raw is! String) return out;
  final text = raw.trim();
  if (text.isEmpty) return out;
  if (text.startsWith('{')) {
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) {
        decoded.forEach((key, value) => _addHeader(out, key, value));
        return out;
      }
    } catch (_) {}
  }
  for (final line in const LineSplitter().convert(text)) {
    final separator = line.indexOf(':');
    if (separator <= 0) continue;
    _addHeader(
      out,
      line.substring(0, separator),
      line.substring(separator + 1),
    );
  }
  return out;
}

void _addHeader(Map<String, String> out, Object? key, Object? value) {
  if (key is! String || value == null) return;
  final name = key.trim();
  final text = value.toString().trim();
  if (name.isEmpty ||
      text.isEmpty ||
      !RegExp(r'^[A-Za-z0-9-]+$').hasMatch(name) ||
      text.contains('\n') ||
      text.contains('\r')) {
    return;
  }
  out[name] = text;
}

/// 把 ua 字段合进请求头表；显式 User-Agent 优先。
Map<String, String> mergeUserAgent(
  Map<String, String> headers,
  String agent,
) {
  final out = Map<String, String>.from(headers);
  final clean = agent.trim();
  if (clean.isEmpty || clean.contains('\n') || clean.contains('\r')) {
    return out;
  }
  final hasAgent = out.keys.any((key) => key.toLowerCase() == 'user-agent');
  if (!hasAgent) out['User-Agent'] = clean;
  return out;
}

/// 下发给 Go 核心前的权威校验；返回错误文案，null 表示通过。
String? validateHttpHeaders(Map<String, String> headers) {
  if (headers.length > 8) return '自定义请求头最多 8 条';
  for (final entry in headers.entries) {
    final name = entry.key.toLowerCase();
    if (!RegExp(r'^[A-Za-z0-9-]+$').hasMatch(entry.key) ||
        entry.key.length > 64) {
      return '请求头名称非法：${entry.key}';
    }
    if (entry.value.length > 512 ||
        entry.value.contains('\n') ||
        entry.value.contains('\r')) {
      return '请求头内容非法：${entry.key}';
    }
    if (name == 'host' || name == 'content-length') {
      return '不支持覆盖请求头：${entry.key}';
    }
  }
  return null;
}

/// 站点/订阅共用的 UA 字段清洗：去控制字符、限长。
String sanitizeUserAgent(String raw) {
  final clean = String.fromCharCodes(
    raw.runes.where((rune) => rune >= 0x20 && rune != 0x7f),
  ).trim();
  return clean.length > 256 ? clean.substring(0, 256) : clean;
}
