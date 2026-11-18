import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「纯黑深色模式」全局开关：OLED 屏幕上把深色主题的底色压到纯黑，
/// 关闭时回到默认深空灰。仅在深色模式下有意义，浅色模式忽略。
abstract final class PureBlackPreferences {
  static const String _key = 'theme.pureBlack';

  /// 全局纯黑开关（默认关闭，跟随上游默认值）。
  static final ValueNotifier<bool> enabled = ValueNotifier(false);

  /// 启动时从持久化恢复。
  static Future<void> load(SharedPreferences prefs) async {
    enabled.value = prefs.getBool(_key) ?? false;
  }

  /// 写盘并通知主题刷新；写失败仅静默（下次启动不记忆）。
  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }
}
