import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import 'motion_tokens.dart';

/// 雾面动态取色采样器。
///
/// 包住内容区（RepaintBoundary + 滚动通知监听），滚动时节流采样
/// boundary 的极小缩略图，取顶部行带平均色经亮度/饱和整形后输出到
/// [tint]——雾面（TopFog 的 tint 参数）据此把提亮层基色从纯白向
/// 内容色靠拢，实现「色跟内容走」。
///
/// 性能护栏：
/// - 采样图 pixelRatio 仅 0.05（1200px 宽屏 → 约 60px 宽缩略图），
///   单次开销毫秒级；静止时零开销（无滚动通知即无任何工作）。
/// - 滚动通知触发节流（150ms），到点后等下一帧（addPostFrameCallback）
///   再拍图，保证采到滚动后的画面。
/// - 测试环境（[Motion.inTest]）整体禁用（toImage 在 flutter_tester
///   下不可靠且会拖垮 pumpAndSettle）；[forceEnabled] 供确需验证
///   采样的测试注入。
/// - toImage 失败/空尺寸静默回落：[tint] 置 null（雾面回纯白）。
class FogTintSampler extends StatefulWidget {
  const FogTintSampler({
    required this.child,
    required this.tint,
    this.forceEnabled = false,
    this.sampleBandStart = 0.0,
    this.sampleBandEnd = 0.25,
    super.key,
  });

  final Widget child;

  /// 采样结果输出（null=回落白色）。外部持有，采样器只写不 dispose。
  final ValueNotifier<Color?> tint;

  /// 测试注入：默认 FLUTTER_TEST 下禁用，置 true 强制启用。
  final bool forceEnabled;

  /// 采样行带（缩略图高度比例区间）。雾面/吸顶头本身在采样 boundary
  /// 内（pinned header 属滚动视图）时，须把 start 抬到雾面比例之上，
  /// 否则采到的是雾面自身颜色而非雾下内容（反馈循环）。首页接线取
  /// 0.30–0.62（屏中上部内容带）。
  final double sampleBandStart;
  final double sampleBandEnd;

  @override
  State<FogTintSampler> createState() => _FogTintSamplerState();
}

class _FogTintSamplerState extends State<FogTintSampler> {
  static const Duration _throttle = Duration(milliseconds: 150);
  static const double _pixelRatio = 0.05;

  final GlobalKey _boundaryKey = GlobalKey();
  Timer? _pending;

  bool get _enabled =>
      widget.forceEnabled || !Motion.inTest;

  @override
  void initState() {
    super.initState();
    if (_enabled) {
      // 首帧初始采样：内容加载即有正确色相。
      SchedulerBinding.instance.addPostFrameCallback((_) => _sample());
    }
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) _schedule();
    return false;
  }

  void _schedule() {
    if (_pending != null) return;
    _pending = Timer(_throttle, () {
      _pending = null;
      if (!mounted) return;
      // 等本节流周期末的滚动结果绘制完成再拍图。
      SchedulerBinding.instance.addPostFrameCallback((_) => _sample());
    });
  }

  Future<void> _sample() async {
    final ctx = _boundaryKey.currentContext;
    if (ctx == null) return;
    final ro = ctx.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize || ro.size.isEmpty) return;
    try {
      final image = await ro.toImage(pixelRatio: _pixelRatio);
      Color? tint;
      try {
        final bytes = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        if (bytes != null) {
          tint = fogTintFromRgba(
            bytes.buffer.asUint8List(),
            image.width,
            image.height,
            bandStart: widget.sampleBandStart,
            bandEnd: widget.sampleBandEnd,
          );
        }
      } finally {
        image.dispose();
      }
      if (!mounted) return;
      widget.tint.value = tint;
    } catch (_) {
      // 静默回落：保留上一次的色（或 null=纯白），不打断滚动。
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return widget.child;
    return NotificationListener<ScrollNotification>(
      onNotification: _onScroll,
      child: RepaintBoundary(key: _boundaryKey, child: widget.child),
    );
  }
}

/// rawRgba 缩略图 [bandStart, bandEnd) 行带的平均色，经「拉亮 + 控饱
/// 和」整形——雾的染色层必须保持浅色气质（白雾带色相），不能被浓色
/// 海报直接染成深色玻璃。
///
/// 平均策略为**饱和度加权**（v2154：用户实测普通平均在浅色网格背景
/// 上被稀释到近乎无感）：weight = (max−min)/255，浓色像素主导色相，
/// 白/灰背景权重趋零；整行内容都无彩色（wsum≈0）时回落普通平均。
///
/// 返回 null 仅当数据不足（空图/字节长度不符）。
Color? fogTintFromRgba(
  Uint8List bytes,
  int width,
  int height, {
  double bandStart = 0,
  double bandEnd = 0.25,
}) {
  if (width <= 0 || height <= 0) return null;
  if (bytes.length < width * height * 4) return null;
  var row0 = (height * bandStart.clamp(0.0, 1.0)).floor();
  var row1 = (height * bandEnd.clamp(0.0, 1.0)).ceil();
  row0 = row0.clamp(0, height);
  row1 = math.max(row1, row0 + 1).clamp(row0 + 1, height);
  var r = 0, g = 0, b = 0, count = 0;
  var wr = 0, wg = 0, wb = 0, wsum = 0;
  for (var y = row0; y < row1; y++) {
    var offset = y * width * 4;
    for (var x = 0; x < width; x++) {
      final cr = bytes[offset];
      final cg = bytes[offset + 1];
      final cb = bytes[offset + 2];
      r += cr;
      g += cg;
      b += cb;
      // 饱和度权重（0–255）：浓色主导，灰白背景趋零。
      final mx = cr > cg ? (cr > cb ? cr : cb) : (cg > cb ? cg : cb);
      final mn = cr < cg ? (cr < cb ? cr : cb) : (cg < cb ? cg : cb);
      final w = mx - mn;
      wr += cr * w;
      wg += cg * w;
      wb += cb * w;
      wsum += w;
      offset += 4;
      count++;
    }
  }
  if (count == 0) return null;
  Color avg;
  if (wsum == 0) {
    // 整行无彩色（纯灰内容）：回落普通平均（整形后仍是白雾）。
    avg = Color.fromARGB(
      255,
      (r / count).round().clamp(0, 255),
      (g / count).round().clamp(0, 255),
      (b / count).round().clamp(0, 255),
    );
  } else {
    avg = Color.fromARGB(
      255,
      (wr / wsum).round().clamp(0, 255),
      (wg / wsum).round().clamp(0, 255),
      (wb / wsum).round().clamp(0, 255),
    );
  }
  // 整形：色相保留，饱和度增强（多色平均会发灰；加权平均后已大幅
  // 改善，×2 再兜一层）并封顶，亮度拉到浅色区——「白雾带色相」而非
  // 「深色玻璃」。
  final hsl = HSLColor.fromColor(avg);
  return hsl
      .withSaturation(math.min(hsl.saturation * 2.0, 0.55))
      .withLightness(math.min(math.max(hsl.lightness, 0.50), 0.92))
      .toColor();
}
