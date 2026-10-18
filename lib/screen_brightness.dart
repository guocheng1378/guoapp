import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 屏幕亮度：优先改窗口真实亮度（与系统亮度同一套物理背光），非 Android 退回遮罩模拟。
///
/// Android 侧 MainActivity 已实现 getBrightness / setBrightness / resetBrightness，
/// 写的是 WindowManager.LayoutParams.screenBrightness，无需任何权限；
/// 之前播放器一直在画面上叠黑纱模拟亮度，和系统亮度脱节，看起来很突兀。
class ScreenBrightness {
  const ScreenBrightness._();

  static const MethodChannel _channel = MethodChannel('duanju/device');

  static bool get _supported => defaultTargetPlatform == TargetPlatform.android;

  /// 读当前有效亮度：窗口亮度优先，未设置过时回退系统亮度。
  static Future<double?> current() async {
    if (!_supported) return null;
    try {
      final value = await _channel.invokeMethod<double>('getBrightness');
      if (value == null || value <= 0) return null;
      return value.clamp(0.01, 1.0);
    } catch (_) {
      return null;
    }
  }

  /// 设置窗口亮度（0.01~1.0）。成功返回 true，表示后续无需再叠遮罩。
  static Future<bool> apply(double value) async {
    if (!_supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>(
        'setBrightness',
        <String, dynamic>{'brightness': value.clamp(0.01, 1.0)},
      );
      return ok ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 恢复「跟随系统亮度」，退出播放器时调用。
  static Future<void> followSystem() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<bool>('resetBrightness');
    } catch (_) {
      // 忽略：窗口销毁后无需恢复
    }
  }
}
