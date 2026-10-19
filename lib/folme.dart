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

/// 雾面悬浮钮（回顶）：滚动上行点亮——玻璃底色变亮、模糊上升、投影
/// 变浓三参数由同一条弹簧联动（对应 MIUI 的 FabBlurStateCallback 三态），
/// 熄灭/点亮都是「唰」一下的弹簧过渡而非淡入淡出。
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
    return ListenableBuilder(
      listenable: GlassPreferences.enabled,
      builder: (context, _) {
        final glass = GlassPreferences.enabled.value;
        return AnimatedBuilder(
          animation: _lit.view,
          builder: (context, _) {
            final v = _lit.value.clamp(0.0, 1.0);
            final base = GlassChipTokens.tint(dark);
            // 底色暗→亮：亮起时向纯白提亮（暗色主题同步加深白瓷）。
            final fill = !glass
                ? GlassSurface.palette(
                    GlassVariant.surface,
                    theme.brightness,
                    enabled: false,
                  ).tint
                : Color.lerp(
                    base,
                    dark ? const Color(0xCCFFFFFF) : const Color(0xFFFFFFFF),
                    v,
                  )!;
            final sigma = glass ? 3.0 + 2.5 * v : 0.0;
            final shape = BorderRadius.circular(28);
            Widget button = ClipRRect(
              borderRadius: shape,
              child: Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: widget.onTap,
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: fill,
                      border: Border.all(color: GlassChipTokens.edge(dark)),
                    ),
                    child: Center(
                      child: AppIcon(
                        AppIcons.expandLess,
                        size: 24,
                        color: Color.lerp(
                          theme.colorScheme.onSurface.withValues(alpha: .6),
                          theme.colorScheme.onSurface,
                          v,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
            if (sigma > 0) {
              button = BackdropFilter(
                filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                child: button,
              );
            }
            // 投影随点亮变浓变散（blurRadius 12+20v），画在 ClipRRect 外层。
            return DecoratedBox(
              decoration: BoxDecoration(
                borderRadius: shape,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(
                      alpha: (dark ? 0.24 : 0.10) + 0.14 * v,
                    ),
                    blurRadius: 12 + 20 * v,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
              child: button,
            );
          },
        );
      },
    );
  }
}

/// MIUI 商城同款下拉刷新胶囊：下拉时胶囊自顶栏后方滑出并被拉长
/// （高宽同涨、图标反向缩小，过阈值翻转成「松手刷新」），松手过阈值
/// 弹簧固定转圈、不足则弹簧弹回（对应包内 SpringBackLayoutWrap +
/// SpringFlinger），刷新完成后收回。
///
/// 通知驱动（[OverscrollNotification] 累计下拉量），与 RefreshIndicator
/// 一样要求 clamping 系物理（AlwaysScrollableScrollPhysics）；纯观察
/// 通知，不参与手势竞争，不影响横滑切分类。
class FogRefresh extends StatefulWidget {
  const FogRefresh({
    super.key,
    required this.onRefresh,
    required this.child,
    this.displacement = 12,
    this.threshold = 64,
  });

  final Future<void> Function() onRefresh;
  final Widget child;

  /// 刷新位时胶囊顶边距滚动视口顶的距离；主页传 AppBar 高度 + 间隙，
  /// 让胶囊停在顶栏正下方。
  final double displacement;

  /// 触发阈值（逻辑像素的下拉过冲量）。
  final double threshold;

  @override
  FogRefreshState createState() => FogRefreshState();
}

class FogRefreshState extends State<FogRefresh>
    with SingleTickerProviderStateMixin {
  late final SpringDriver _p = SpringDriver(this);

  /// 本轮累计下拉过冲（跟手值，松手/触发后清零）。
  double _drag = 0;

  /// 本轮手势是否「起步就在顶缘」——RefreshIndicator 同款门槛：
  /// 从列表深处一把拖到顶的手势不触发刷新（否则回顶拖拽松手即误刷）。
  bool _startedAtTop = false;
  bool _refreshing = false;

  /// 阈值之后仍可继续拉的拉伸上限（胶囊拉长的手感余量）。
  static const double _maxStretch = 1.3;

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
    setState(() => _refreshing = true);
    _p.to(1); // 过阈值：弹簧固定在刷新位转圈
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await widget.onRefresh();
    } finally {
      if (mounted) {
        setState(() => _refreshing = false);
        _p.to(0); // 收回
      }
    }
  }

  @override
  void dispose() {
    _p.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: _onNotification,
      child: Stack(
        children: [
          widget.child,
          // 胶囊浮层：自顶栏后方滑入（负位移被 Stack 裁掉，即「藏进顶栏后」）。
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: AnimatedBuilder(
              animation: _p.view,
              builder: (context, _) {
                final v = _p.value;
                if (v <= 0.001) return const SizedBox.shrink();
                final p = v.clamp(0.0, 1.0);
                final h = 34.0 + 14.0 * p;
                return Transform.translate(
                  offset: Offset(
                    0,
                    -(h + 12) + p * (h + 12 + widget.displacement),
                  ),
                  child: Center(
                    child: _FogRefreshCapsule(
                      width: 72.0 + 26.0 * p,
                      height: h,
                      progress: p,
                      refreshing: _refreshing,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// 刷新胶囊本体：白瓷胶囊（GlassChipTokens 唯一配方）+ TopFog 同款
/// 恒定 σ4.5 雾面；高宽随进度同涨、图标反向缩小并旋转 180°（过阈翻转）。
class _FogRefreshCapsule extends StatelessWidget {
  const _FogRefreshCapsule({
    required this.width,
    required this.height,
    required this.progress,
    required this.refreshing,
  });

  final double width;
  final double height;
  final double progress;
  final bool refreshing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final glass = GlassPreferences.enabled.value;
    final shape = BorderRadius.circular(height / 2);
    Widget capsule = Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: glass
            ? GlassChipTokens.tint(dark)
            : GlassSurface.palette(
                GlassVariant.surface,
                theme.brightness,
                enabled: false,
              ).tint,
        borderRadius: shape,
        border: Border.all(color: GlassChipTokens.edge(dark)),
        boxShadow: GlassChipTokens.shadow(dark),
      ),
      child: Center(
        child: refreshing
            ? SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: theme.colorScheme.primary,
                ),
              )
            : Transform.rotate(
                // 下拉中箭头朝下，过阈值翻成「松手刷新」。
                angle: progress * math.pi,
                child: Transform.scale(
                  scale: 1 - 0.25 * progress,
                  child: AppIcon(AppIcons.expandMore, size: 18),
                ),
              ),
      ),
    );
    if (glass) {
      capsule = ClipRRect(
        borderRadius: shape,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 4.5, sigmaY: 4.5),
          child: capsule,
        ),
      );
    }
    return capsule;
  }
}
