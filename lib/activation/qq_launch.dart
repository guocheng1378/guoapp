import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _channel = MethodChannel('duanju/device');

/// 测试注入口：null=按真实平台判断。
/// 测试主机本身是 Windows，不注入会误走 cmd 分支而跳过通道。
@visibleForTesting
bool? debugIsWindows;
bool _isWindows() => debugIsWindows ?? Platform.isWindows;

/// 从联系方式文本中提取 QQ 号（5-12 位连续数字）。
String? qqNumberFrom(String contact) {
  final match = RegExp(r'\d{5,12}').firstMatch(contact);
  return match?.group(0);
}

/// 尝试拉起 QQ 加好友/聊天界面。
///
/// Android：先 QQ 资料卡（含「加好友」按钮），失败再试临时会话聊天。
/// Windows：走 tencent:// 协议（桌面 QQ 注册的协议）。
/// 其他平台或未安装 QQ 返回 false，调用方应退化为复制联系方式。
Future<bool> tryOpenQQ(String qq) async {
  if (qq.isEmpty) return false;
  if (_isWindows()) {
    try {
      final result = await Process.run('cmd', [
        '/c',
        'start',
        '',
        'tencent://Message/?uin=$qq&Site=&Menu=yes',
      ]);
      return result.exitCode == 0;
    } on Object {
      return false;
    }
  }
  try {
    return await _channel.invokeMethod<bool>('openQQ', {'uin': qq}) ?? false;
  } on Object {
    return false;
  }
}
