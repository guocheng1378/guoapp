import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「玻璃效果」全局开关：关闭后所有玻璃面降级为不透明等价样式。
///
/// GlassSurface 内部监听 [enabled]，每个玻璃面局部重建，无需重建整棵树。
abstract final class GlassPreferences {
  static const String _key = 'glass.enabled';

  /// 全局玻璃开关（true=瓷面，false=不透明降级）。
  static final ValueNotifier<bool> enabled = ValueNotifier(true);

  /// 启动时从持久化恢复。
  static Future<void> load(SharedPreferences prefs) async {
    enabled.value = prefs.getBool(_key) ?? true;
  }

  /// 写盘并通知全部玻璃面刷新；写失败仅静默（下次启动不记忆）。
  static Future<void> setEnabled(bool value) async {
    enabled.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_key, value);
    } catch (_) {}
  }
}
