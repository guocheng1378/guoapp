import 'dart:io' show Platform;

import 'package:flutter/animation.dart';

/// 全局动效时长档位。
///
/// 档位语义：
/// - `micro`      微交互：按压、焦点、开关
/// - `quick`      快速过渡：小组件淡入淡出、轻弹层
/// - `base`       组件过渡：菜单、玻璃弹层、控制栏
/// - `page`       页面转场
/// - `emphasized` 强调转场：大面板、抽屉
/// - `hero`       强调动画：轮播大卡、进度条
abstract final class MotionDurations {
  static const Duration micro = Duration(milliseconds: 120);
  static const Duration quick = Duration(milliseconds: 160);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration page = Duration(milliseconds: 260);
  static const Duration emphasized = Duration(milliseconds: 320);
  static const Duration hero = Duration(milliseconds: 480);
}

/// 全局动效曲线令牌。
abstract final class MotionCurves {
  /// 入场减速（easeOutCubic 同族）。
  static const Curve standard = Cubic(0.33, 1, 0.68, 1);

  /// 强调转场（缓起急收）。
  static const Curve emphasized = Cubic(0.2, 0, 0, 1);

  /// 轻弹性按压回弹（轻微过冲）。
  static const Curve press = Cubic(0.34, 1.56, 0.64, 1);

  /// 退场加速。
  static const Curve exit = Curves.easeIn;
}

/// 动效环境开关。
abstract final class Motion {
  /// 测试环境（flutter test）：循环动画禁用、错峰入场静态渲染，
  /// 保证 pumpAndSettle 可收敛（与 home_carousel 的 FLUTTER_TEST 惯例同源）。
  static bool get inTest => Platform.environment.containsKey('FLUTTER_TEST');
}
