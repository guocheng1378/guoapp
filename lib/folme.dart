import 'dart:async' show unawaited;
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import 'app_icons.dart';
import 'glass.dart';
import 'glass_preferences.dart';
import 'motion.dart';

/// MIUI「Folme」动效族：一条共用弹簧 + 雾面材质三件套。
///
/// 对齐小米商城包内实现（FabBlurStateCallback / BlurToken / SpringFlinger）：
/// 所有位移、缩放、明暗共用同一条弹簧（stiffness 400 / damping 26，欠阻尼
/// 轻过冲），雾面材质统一 BackdropFilter + 白瓷叠层；滚动/手势只改目标值，
/// 过渡全部交给弹簧——「唰」地到位，不是慢慢淡入。

/// 共用弹簧（小米 Folme 手感基准）：质量 1 / 刚度 400 / 阻尼 26。
const SpringDescription kFolmeSpring = SpringDescription(
  mass: 1,
  stiffness: 400,
  damping: 26,
);

/// 弹簧驱动器：目标值切换走 [SpringSimulation] 并携带当前速度续跳，
/// 快速连续触发（连点、连滚）不会像 Tween 那样每段重新起步。
///
/// 测试环境（[Motion.inTest]）直接跳到目标值，保证 pumpAndSettle 收敛。
class SpringDriver {
  SpringDriver(TickerProvider vsync, {double value = 0}) {
    _controller = AnimationController.unbounded(vsync: vsync, value: value);
  }

  late final AnimationController _controller;

  double get value => _controller.value;
  Animation<double> get view => _controller;

  /// 弹簧过渡到目标值（测试环境跳变）。
  void to(double target) {
    _controller.stop();
    if (Motion.inTest) {
      _controller.value = target;
      return;
    }
    _controller.animateWith(
      SpringSimulation(
        kFolmeSpring,
        _controller.value,
        target,
        _controller.velocity,
      ),
    );
  }

  /// 无动画直达（跟手阶段用，弹簧只负责松手后的收尾）。
  void jumpTo(double value) {
    _controller.stop();
    _controller.value = value;
  }

  void dispose() => _controller.dispose();
}

/// 胶囊果冻按压：按下缩到 [pressedScale]，松手弹簧弹回（轻过冲）。
///
/// 与 motion.dart 的 [PressableScale] 同一套指针观察（Listener 纯观察，
/// 不参与手势竞争，可包在任何交互组件外层），区别只在回弹走 Folme 弹簧。
class FolmePress extends StatefulWidget {
  const FolmePress({
    super.key,
    this.pressedScale = 0.96,
    this.enabled = true,
    required this.child,
  });

  final double pressedScale;
  final bool enabled;
  final Widget child;

  @override
  State<FolmePress> createState() => _FolmePressState();
}

class _FolmePressState extends State<FolmePress>
    with SingleTickerProviderStateMixin {
  late final SpringDriver _scale = SpringDriver(this, value: 1);

  @override
  void dispose() {
    _scale.dispose();
    super.dispose();
  }

  void _set(bool down) {
    if (!widget.enabled) return;
    _scale.to(down ? widget.pressedScale : 1);
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.inTest) return widget.child;
    return Listener(
      onPointerDown: (_) => _set(true),
      onPointerUp: (_) => _set(false),
      onPointerCancel: (_) => _set(false),
      child: AnimatedBuilder(
        animation: _scale.view,
        builder: (context, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: widget.child,
      ),
    );
  }
}

/// 雾面悬浮钮（回顶）：素玻璃球版（base(2).apk FogButton 真值）——
/// σ30 模糊 + 8% 常驻黑底 + 三层混色（alpha 随点亮爬升）+ Bloom 白描边
/// + 羽化辉光；滚动上行点亮（v 0→1）时玻璃球「变实变亮」，全部视觉由
/// 同一条弹簧联动（对应 MIUI FabBlurStateCallback 三态）。
///
/// 显示/隐藏由调用方控制（建议 AnimatedScale + AnimatedOpacity 收放），
/// 本组件只负责明暗与点击。
class FogFab extends StatefulWidget {
  const FogFab({
    super.key,
    required this.onTap,
    this.lit = false,
    this.tooltip = '回到顶部',
  });

  final VoidCallback onTap;

  /// 点亮态：内容上行时为 true，下滑/停驻为 false。
  final bool lit;
  final String tooltip;

  @override
  State<FogFab> createState() => FogFabState();
}

class FogFabState extends State<FogFab> with SingleTickerProviderStateMixin {
  late final SpringDriver _lit = SpringDriver(this, value: widget.lit ? 1 : 0);

  @override
  void didUpdateWidget(covariant FogFab oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lit != widget.lit) _lit.to(widget.lit ? 1 : 0);
  }

  @override
  void dispose() {
    _lit.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    return ListenableBuilder(
      listenable: GlassPreferences.enabled,
      builder: (context, _) {
        final glass = GlassPreferences.enabled.value;
        return AnimatedBuilder(
          animation: _lit.view,
          builder: (context, _) {
            final v = _lit.value.clamp(0.0, 1.0);
            if (!glass) {
              // 不透明降级：瓷面圆钮（玻璃总控关闭时的无模糊形态）。
              final palette = GlassSurface.palette(
                GlassVariant.surface,
                theme.brightness,
                enabled: false,
              );
              return Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onTap,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: palette.tint,
                      shape: BoxShape.circle,
                      border: Border.all(color: palette.edge),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: dark ? 0.24 : 0.10,
                          ),
                          blurRadius: 12,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Center(
                      child: AppIcon(
                        AppIcons.expandLess,
                        size: 24,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: .8,
                        ),
                      ),
                    ),
                  ),
                ),
              );
            }
            // 素玻璃球：外层 96 盒给辉光留余量（FogFab 挂在 Positioned
            // 里，占位不参与文档流），三层视觉由同一条弹簧驱动。
            return SizedBox(
              width: 96,
              height: 96,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // ① 羽化辉光：单侧 4→12dp 径向白光，点亮时「呼吸」。
                  IgnorePointer(
                    child: Container(
                      width: 56 + 8 + 16 * v,
                      height: 56 + 8 + 16 * v,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          radius: 0.5 + 0.12 * v,
                          colors: [
                            Colors.white.withValues(alpha: 0.30 * v),
                            Colors.white.withValues(alpha: 0.12 * v),
                            Colors.transparent,
                          ],
                        ),
                      ),
                    ),
                  ),
                  // ② 阴影：#59000000 下坠 2px 扩散 64px（按 dpr 换算）。
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0x59000000),
                          offset: Offset(0, 2 / dpr),
                          blurRadius: 64 / dpr,
                        ),
                      ],
                    ),
                  ),
                  // ③ 雾面本体：ClipOval 严格裁轮廓（BackdropFilter 外层
                  // 裁剪铁律——child 侧裁剪裁不住滤镜），内层 σ30 模糊 +
                  // 8% 黑底 + 三层混色 + 恒白图标 + Bloom 白描边。
                  Material(
                    type: MaterialType.transparency,
                    child: InkWell(
                      onTap: widget.onTap,
                      customBorder: const CircleBorder(),
                      child: ClipOval(
                        child: BackdropFilter(
                          filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                          child: SizedBox(
                            width: 56,
                            height: 56,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // 8% 常驻黑底：熄灯态（混色 alpha=0）也
                                // 托住圆盘轮廓，恒白图标不浮空。
                                const Positioned.fill(
                                  child: ColoredBox(
                                    color: Color(0x14000000),
                                  ),
                                ),
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _FogFabMixPainter(v),
                                  ),
                                ),
                                AppIcon(
                                  AppIcons.expandLess,
                                  size: 24,
                                  color: Colors.white.withValues(
                                    alpha: 0.92 + 0.08 * v,
                                  ),
                                ),
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _FogFabBloomPainter(v),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

/// FogFab 三层混色（demo _MixLayersPainter 字节码真值）：alpha 随点亮
/// 爬升，玻璃球随滚动「变实」。绘制发生在 BackdropFilter 之后的同一帧
/// 缓冲上，blendMode 与模糊后的背景相混。层1 原配方 plusDarker 在本机
/// Flutter 3.47 的 dart:ui 尚未提供（demo 注释预留了此降级路径），
/// 降级 BlendMode.darken——黑 10% 层的压暗观感几乎无差。
class _FogFabMixPainter extends CustomPainter {
  _FogFabMixPainter(this.v);

  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    if (v <= 0.01) return;
    final rect = Offset.zero & size;
    // 层1 #1A000000 × darken（原 plusDarker，见类注释降级说明）
    canvas.drawRect(
      rect,
      Paint()
        ..color = Color.fromARGB((0x1A * v).round(), 0, 0, 0)
        ..blendMode = BlendMode.darken,
    );
    // 层2 #996C6C6C × luminosity
    canvas.drawRect(
      rect,
      Paint()
        ..color = Color.fromARGB((0x99 * v).round(), 0x6C, 0x6C, 0x6C)
        ..blendMode = BlendMode.luminosity,
    );
    // 层3 #99060606 × softLight
    canvas.drawRect(
      rect,
      Paint()
        ..color = Color.fromARGB((0x99 * v).round(), 0x06, 0x06, 0x06)
        ..blendMode = BlendMode.softLight,
    );
  }

  @override
  bool shouldRepaint(_FogFabMixPainter old) => old.v != v;
}

/// FogFab Bloom 环形白描边：亮 0.45 / 熄 0.15，光圈随点亮加宽。
/// 熄灯态也画（0.15 起），保证圆盘边缘可读。
class _FogFabBloomPainter extends CustomPainter {
  _FogFabBloomPainter(this.v);

  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.shortestSide / 2;
    if (v > 0.02) {
      final glow = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.35 * v)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 2 + 3 * v);
      canvas.drawCircle(c, r - 1, glow);
    }
    final line = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..color = Colors.white.withValues(alpha: 0.15 + 0.30 * v);
    canvas.drawCircle(c, r - 1.4, line);
  }

  @override
  bool shouldRepaint(_FogFabBloomPainter old) => old.v != v;
}

/// MIUI 商城同款下拉刷新圆环：分类条下缘一颗 30×30 描边小圆，下拉时
/// 宽度恒定不变、只纵向拉长（30 → 76px 竖椭圆环，环顶钉在 displacement
/// 向下伸展），松手过阈值同一根弹簧原路缩回小圆——拉到哪、弹回就经过
/// 哪，落定位置与静止小圆同位同描边（前后呼应）；刷新中小点沿环内圈
/// 绕行，完成淡出收场，不足阈值弹簧弹回淡出。
///
/// 通知驱动（[OverscrollNotification] 累计下拉量），与 RefreshIndicator
/// 一样要求 clamping 系物理（AlwaysScrollableScrollPhysics）；纯观察
/// 通知，不参与手势竞争，不影响横滑切分类。
///
/// 界面跟手：内容与环共用同一根弹簧进度，下拉时整页内容 1:1 向下平移
/// 让出空隙（环在空隙里拉长），松手同轨弹回；刷新期内容停在环下让位，
/// 小环悬在空隙中不压内容，收场与环淡出一起归零。
///
/// 吸顶层（[header]，如吸顶分类条）：钉在原位**不随下拉平移**，盖在
/// 内容层之上——真机定调「分组不跟着下来，刷新图标在拉下来后的白色
/// 区域」：下拉时只有内容层下滑，吸顶条下方露出白区，环正落在白区里；
/// 刷新全程吸顶条不动、内容停在让位量，动画做完才一起回去。
///
/// 回拖跟手：按住不松手往回拖时（列表从顶缘滚回正区间的回滚帧），
/// 已累计的下拉量按回滚量等量收回——内容跟手缩回原位，不等
/// 松手才弹回（用户定调「按着手动回去应该缩小的」）。
class FogRefresh extends StatefulWidget {
  const FogRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.displacement = 12,
    this.threshold = 64,
    this.header,
    this.headerExtent = 0,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  /// 刷新位时圆环顶边距滚动视口顶的距离；主页传顶栏+吸顶分类条总高
  /// + 间隙，让环停在分类条之下。
  final double displacement;

  /// 触发阈值（逻辑像素的下拉过冲量）。
  final double threshold;

  /// 吸顶层（如吸顶分类条）：不随下拉平移，盖在内容层之上。下拉时
  /// 内容层整体下滑让位，吸顶条钉在原位，环落在其下方露出的白区里。
  final Widget? header;

  /// 吸顶层高度；内容层需自行留出等高占位（首屏内容从其下方起排）。
  final double headerExtent;

  @override
  FogRefreshState createState() => FogRefreshState();
}

class FogRefreshState extends State<FogRefresh> with TickerProviderStateMixin {
  late final SpringDriver _p = SpringDriver(this);

  /// 环的可见度：刷新中恒 1，刷新完成后 1→0 淡出收场；下拉态不用它
  /// （走进度淡入）。
  late final AnimationController _e = AnimationController(vsync: this);

  /// 刷新态小点绕环内圈旋转（~0.9s/圈）。测试环境不自转（repeat 的
  /// 无穷动画会让 pumpAndSettle 不收敛），小点静止。
  late final AnimationController _spin = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 900),
  );

  /// 刷新让位控制器（像素）：下拉触发刷新时，内容从当前位置弹簧挪到
  /// 让位量停住，刷新完成随淡出一起归零；程序化触发不经它（内容不动）。
  late final AnimationController _hold = AnimationController.unbounded(
    vsync: this,
  );

  /// 本轮累计下拉过冲（跟手值，松手/触发后清零）。
  double _drag = 0;

  /// 本轮手势是否「起步就在顶缘」——RefreshIndicator 同款门槛：
  /// 从列表深处一把拖到顶的手势不触发刷新（否则回顶拖拽松手即误刷）。
  bool _startedAtTop = false;
  bool _refreshing = false;

  /// 阈值之后仍可继续拉的拉伸上限（环长手感余量，高度封顶 76px）。
  static const double _maxStretch = 1.3;

  /// 圆环真值：宽度恒 30（=静止小圆直径，任何状态都不变大），
  /// 高度 = 30 + 46×进度（唯一变量，只拉长）。
  static const double _ringWidth = 30.0;
  static const double _ringBaseHeight = 30.0;
  static const double _ringMaxGrow = 46.0;

  /// 刷新期内容让位量：环高 30 + 6px 间隙——刷新小环的底缘恰好悬在
  /// 内容顶边之上的空隙里，不压轮播；随环真值派生，环调尺寸自动跟随。
  static const double _holdClearance = _ringBaseHeight + 6.0;

  bool _onNotification(ScrollNotification n) {
    if (_refreshing) return false;
    if (n is ScrollStartNotification && n.dragDetails != null) {
      // 手指落下：记录是否起步于顶缘（extentBefore==0）。
      _startedAtTop = n.metrics.extentBefore <= 0;
      return false;
    }
    if (n is OverscrollNotification &&
        _startedAtTop &&
        n.overscroll < 0 &&
        n.dragDetails != null) {
      // 顶部下拉过冲的 overscroll 为负（RefreshIndicator 同款约定），
      // 取绝对值累计；dragDetails 门槛滤掉惯性过冲帧。跟手直接映射
      // 进度，弹簧只负责松手收尾。
      _drag = math.min(_drag - n.overscroll, widget.threshold * _maxStretch);
      _p.jumpTo(_drag / widget.threshold);
      return false;
    }
    if (n is ScrollUpdateNotification &&
        _startedAtTop &&
        _drag > 0 &&
        n.dragDetails != null &&
        (n.scrollDelta ?? 0) > 0) {
      // 按住往回拖的回滚帧：顶缘过冲回拖时 clamping 物理不再报
      // OverscrollNotification，改报 scrollDelta>0 的滚动帧（dragDetails
      // 只在手指驱动帧有值，滤掉惯性）。已累计的下拉量等量收回，
      // 内容/吸顶分类条跟手缩回；缩回后继续上拖=正常滚动列表。
      _drag = math.max(0, _drag - n.scrollDelta!);
      _p.jumpTo(_drag / widget.threshold);
      return false;
    }
    if (n is ScrollEndNotification) {
      final drag = _drag;
      _drag = 0;
      _startedAtTop = false;
      if (drag > 0) {
        if (drag >= widget.threshold) {
          show();
        } else {
          _p.to(0); // SpringFlinger：不足阈值弹簧弹回
        }
      }
    }
    return false;
  }

  /// 公开触发入口（与 RefreshIndicatorState.show() 同语义）。
  void show() {
    if (_refreshing) return;
    // 下拉触发的刷新：内容从当前位置弹簧挪到让位量（环高+间隙）停住，
    // 给小环腾出空隙、不压轮播；程序化触发（offset=0）内容原地不动。
    // 必须在 _p.to(0) 起跳前同步取值。
    final off = _p.value * widget.threshold;
    if (off > 0) {
      _hold.value = off;
      if (Motion.inTest) {
        _hold.value = _holdClearance;
      } else {
        unawaited(
          _hold.animateWith(
            SpringSimulation(kFolmeSpring, off, _holdClearance, 0),
          ),
        );
      }
    }
    setState(() => _refreshing = true);
    // 同一颗环原路收回：拉伸态经弹簧缩回 30×30 小圆（携带下拉速度，
    // 拉多长弹回就经过多长），落定位置=静止小圆锚点，前后呼应。
    _p.to(0);
    _e.value = 1;
    if (!Motion.inTest) _spin.repeat();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        _spin.stop();
        // 收场：30×30 小圆原位淡出，内容让位同步弹簧归零（环与界面一起
        // 收场），两者都落定才摘刷新态。
        if (Motion.inTest) {
          _e.value = 0;
          _hold.value = 0;
          setState(() => _refreshing = false);
        } else {
          final release = _hold.animateWith(
            SpringSimulation(kFolmeSpring, _hold.value, 0, 0),
          );
          await _e.animateBack(0, duration: const Duration(milliseconds: 160));
          await release;
          if (mounted) setState(() => _refreshing = false);
        }
      }
    }
  }

  @override
  void dispose() {
    _e.dispose();
    _spin.dispose();
    _hold.dispose();
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: Stack(
        children: [
          // 内容层：下拉/弹回与环共用同一进度跟手平移（界面让出空间），
          // 刷新期停在让位量、收场归零；关闭系统拉伸指示——内容边缘的
          // stretch 畸变与平移叠加会双重位移。
          AnimatedBuilder(
            animation: Listenable.merge([_p.view, _hold, _e]),
            builder: (context, child) {
              final offset = _refreshing || _e.value > 0.001
                  ? _hold.value
                  : _p.value * widget.threshold;
              return Transform.translate(
                offset: Offset(0, offset),
                child: child,
              );
            },
            child: ScrollConfiguration(
              behavior: ScrollConfiguration.of(context).copyWith(
                overscroll: false,
              ),
              child: widget.child,
            ),
          ),
          // 吸顶层：钉在原位不随下拉平移，盖在内容层之上——内容下滑
          // 让位时其下方露出白区，环正落在白区里（环层画在其上但几何
          // 在其下方，互不遮挡）。
          if (widget.header != null)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: widget.headerExtent,
              child: widget.header!,
            ),
          // 圆环浮层：顶边永远钉在 displacement（分类条下缘），只向下
          // 伸展、向上收回——锚点不动、宽度不变，不罩分类条。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedBuilder(
              animation: Listenable.merge([_p.view, _e, _spin]),
              builder: (context, _) {
                final e = _e.value;
                final v = _p.value;
                final p = v.clamp(0.0, 1.0);
                if (_refreshing) {
                  // 刷新态：环以弹簧速度缩回小圆（p→0），小点随收缩淡入。
                  return _ring(
                    height: _ringBaseHeight + _ringMaxGrow * p,
                    alpha: e,
                    dotAlpha: 1 - p,
                    spin: _spin.value,
                  );
                }
                if (e > 0.001) {
                  // 刷新完成后的淡出尾巴（此刻已是 30×30 小圆）。
                  return _ring(
                    height: _ringBaseHeight,
                    alpha: e,
                    dotAlpha: 0,
                    spin: 0,
                  );
                }
                if (v <= 0.001) return const SizedBox.shrink();
                // 拉伸态（跟手）：只拉长，前 30% 进度淡入。
                return _ring(
                  height: _ringBaseHeight + _ringMaxGrow * p,
                  alpha: (p / 0.3).clamp(0.0, 1.0),
                  dotAlpha: 0,
                  spin: 0,
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 圆环浮层本体：顶边钉在 [FogRefresh.displacement]，宽恒
  /// [_ringWidth]，高度与透明度由调用方给。
  Widget _ring({
    required double height,
    required double alpha,
    required double dotAlpha,
    required double spin,
  }) {
    final theme = Theme.of(context);
    return Transform.translate(
      offset: Offset(0, widget.displacement),
      child: Align(
        alignment: Alignment.topCenter,
        child: Opacity(
          opacity: alpha.clamp(0.0, 1.0),
          child: SizedBox(
            key: const Key('fog-refresh-ring'),
            width: _ringWidth,
            height: height,
            child: CustomPaint(
              painter: _FogRefreshRingPainter(
                dark: theme.brightness == Brightness.dark,
                dotColor: theme.colorScheme.primary,
                dotAngle: spin * 2 * math.pi,
                dotAlpha: dotAlpha.clamp(0.0, 1.0),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 刷新圆环本体：宽 30 恒定的描边环（拉长时为竖椭圆 stadium），环顶
/// 弧线与静止小圆完全重合（同一颗环被拉长又缩回）。亮色白 0.95 描边
/// + 轻影（黑 0.10 blur3 下坠 1.5，浅底保证可读），暗色白 0.75；刷新中
/// 小点（primary 色）沿环内圈绕行。
class _FogRefreshRingPainter extends CustomPainter {
  _FogRefreshRingPainter({
    required this.dark,
    required this.dotColor,
    required this.dotAngle,
    required this.dotAlpha,
  });

  final bool dark;
  final Color dotColor;
  final double dotAngle;
  final double dotAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 2.4;
    final rect = (Offset.zero & size).deflate(stroke / 2);
    final rrect = RRect.fromRectAndRadius(
      rect,
      Radius.circular(rect.shortestSide / 2),
    );
    canvas.drawRRect(
      rrect.shift(const Offset(0, 1.5)),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.black.withValues(alpha: dark ? 0.20 : 0.10)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..color = Colors.white.withValues(alpha: dark ? 0.75 : 0.95),
    );
    if (dotAlpha > 0.01) {
      // 小点绕环内圈：留出描边与点径的余量。
      final orbit = rect.shortestSide / 2 - 4.4;
      final c = rect.center;
      canvas.drawCircle(
        Offset(
          c.dx + math.cos(dotAngle) * orbit,
          c.dy + math.sin(dotAngle) * orbit,
        ),
        3,
        Paint()..color = dotColor.withValues(alpha: dotAlpha),
      );
    }
  }

  @override
  bool shouldRepaint(_FogRefreshRingPainter old) =>
      old.dark != dark ||
      old.dotColor != dotColor ||
      old.dotAngle != dotAngle ||
      old.dotAlpha != dotAlpha;
}
