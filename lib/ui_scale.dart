import 'package:flutter/widgets.dart';

/// 界面缩放（用户 2026-11-15 要求）：设置页拖动即时预览、松手落盘。
///
/// 实现走 [TextScaler]：项目里分类条、按钮、选集格、轮播副标题等尺寸
/// 本来就按 `MediaQuery.textScalerOf(context)` 换算，放大倍率会连带把这些
/// 控件一起放大，观感是「整个界面变大/变小」，而不是只改字号。
///
/// 用全局 [ValueNotifier] 而不是每次落盘：拖动过程中要逐帧预览，若每帧
/// 都写 SharedPreferences 会把存储队列打满。
abstract final class UiScale {
  /// 有效区间与步进：低于 85% 文字糊，高于 130% 会挤爆窄屏卡片标题。
  static const double min = 0.85;
  static const double max = 1.3;
  static const double step = 0.05;

  /// 当前生效倍率（1.0 = 系统默认）。启动时由 LocalStore 回填。
  static final ValueNotifier<double> current = ValueNotifier<double>(1);

  /// 档位化：按步进取整并夹到区间内，避免 0.9999 这类脏值。
  static double normalize(double value) {
    if (!value.isFinite) return 1;
    final stepped = (value / step).round() * step;
    return double.parse(stepped.clamp(min, max).toStringAsFixed(2));
  }

  /// 百分比文案：1 → 100%。
  static String label(double value) => '${(normalize(value) * 100).round()}%';

  /// 拖动中的即时预览（不落盘）。
  static void preview(double value) => current.value = normalize(value);

  /// 包一层 MediaQuery 把倍率乘到系统字体缩放上（系统无障碍字号仍然叠加）。
  static Widget apply(BuildContext context, Widget child) {
    final scale = current.value;
    if ((scale - 1).abs() < 0.001) return child;
    final media = MediaQuery.maybeOf(context);
    if (media == null) return child;
    return MediaQuery(
      data: media.copyWith(
        textScaler: _ScaledTextScaler(media.textScaler, scale),
      ),
      child: child,
    );
  }
}

/// 保留系统 [TextScaler] 的缩放曲线：先按用户倍率缩放字号，再交给系统缩放。
///
/// 旧实现取 `textScaler.scale(100) / 100` 当线性斜率，等于把 Android 的
/// 非线性无障碍字号压成一条直线（大字号失准、小字号放大不足）。
class _ScaledTextScaler extends TextScaler {
  const _ScaledTextScaler(this.base, this.factor);

  final TextScaler base;
  final double factor;

  @override
  double scale(double fontSize) => base.scale(fontSize * factor);

  // TextScaler 的抽象成员（旧 API），组合时一并乘上倍率。
  // ignore: deprecated_member_use
  @override
  double get textScaleFactor =>
      // ignore: deprecated_member_use
      base.textScaleFactor * factor;

  @override
  bool operator ==(Object other) =>
      other is _ScaledTextScaler && other.base == base && other.factor == factor;

  @override
  int get hashCode => Object.hash(base, factor);
}
