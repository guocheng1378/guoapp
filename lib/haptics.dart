import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 统一触感反馈。
///
/// Flutter 的 `HapticFeedback.*` 在 Android 上走 `View.performHapticFeedback`：
/// 受系统「触摸反馈」总开关控制，且 light/selection 两档在很多 ROM 上
/// 几乎无感——代码里调了但用户「感觉不到震动」。这里改为经
/// `duanju/device` 通道直调 `Vibrator`（明确时长 + 强度），只受硬件与
/// 全局勿扰影响；通道不存在、旧包或非 Android 平台自动回退 Flutter。
abstract final class AppHaptics {
  static const MethodChannel _channel = MethodChannel('duanju/device');

  static void selection() =>
      _buzz('selection', HapticFeedback.selectionClick);

  static void light() => _buzz('light', HapticFeedback.lightImpact);

  static void medium() => _buzz('medium', HapticFeedback.mediumImpact);

  static void heavy() => _buzz('heavy', HapticFeedback.heavyImpact);

  static void _buzz(String kind, Future<void> Function() fallback) {
    if (_nativeAvailable) {
      // 不 await：点按反馈不能挡住任何 UI 动作，也不让平台通道的
      // 异常/超时进入调用方的异步链。
      unawaited(_native(kind, fallback));
    } else {
      unawaited(_safeFallback(fallback));
    }
  }

  /// 纯 Dart 单测宿主可能连 platform channel binding 都没初始化，
  /// 反馈失败绝不能变成未捕获的异步错误把用例染红。
  static Future<void> _safeFallback(Future<void> Function() fallback) async {
    try {
      await fallback();
    } catch (_) {}
  }

  static bool get _nativeAvailable =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      Platform.environment['FLUTTER_TEST'] != 'true';

  static Future<void> _native(
    String kind,
    Future<void> Function() fallback,
  ) async {
    try {
      final ok = await _channel
          .invokeMethod<bool>('vibrate', <String, Object>{'kind': kind})
          .timeout(const Duration(milliseconds: 300));
      if (ok == true) return;
    } catch (_) {
      // 原生端没有该分支（旧包）、无振动器或通道不可达：回退。
    }
    await _safeFallback(fallback);
  }
}
