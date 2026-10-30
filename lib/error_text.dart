/// 错误文案友好化：给用户看的错误不再直出 `Exception: xxx` 原文。
///
/// 独立于 widgets.dart（无 UI 依赖），纯逻辑/数据层（如 batch_downloads）
/// 也能安全引用。识别常见异常给说人话的文案；未知错误保留原文
/// （便于用户反馈时附带原始信息排查）。
library;

import 'dart:async';

String friendlyError(Object error) {
  if (error is TimeoutException) return '加载超时，请检查网络后重试';
  final text = error.toString();
  const networkHints = [
    'SocketException',
    'ClientException',
    'Connection refused',
    'Connection reset',
    'Connection closed',
    'Connection timed out',
    'Failed host lookup',
    'Network is unreachable',
    '软件导致连接中止',
    '远程主机强迫关闭',
  ];
  for (final hint in networkHints) {
    if (text.contains(hint)) return '网络连接失败，请检查网络后重试';
  }
  if (text.contains('HandshakeException')) return '网络连接失败，请检查网络后重试';
  if (text.contains('FormatException') || text.contains('type cast')) {
    return '内容解析异常，请稍后重试';
  }
  return text;
}
