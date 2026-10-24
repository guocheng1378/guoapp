import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'motion_tokens.dart';

export 'motion_tokens.dart';

/// 按压回弹：按下缩到 [pressedScale]，松手轻弹回 1.0。
///
/// 用 [Listener] 纯观察指针事件，不参与手势竞争——
/// 可以安全包在任何交互组件（InkWell/遥控焦点卡）外层。
class PressableScale extends StatefulWidget {
  const PressableScale({
    super.key,
    this.pressedScale = 0.96,
    this.enabled = true,
    required this.child,
  });

  final double pressedScale;
  final bool enabled;
  final Widget child;

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale> {
  bool _down = false;

  void _set(bool value) {
    if (_down == value) return;
    setState(() => _down = value);
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.inTest) return widget.child;
    return Listener(
      onPointerDown: widget.enabled ? (_) => _set(true) : null,
      onPointerUp: widget.enabled ? (_) => _set(false) : null,
      onPointerCancel: widget.enabled ? (_) => _set(false) : null,
      child: AnimatedScale(
        scale: _down ? widget.pressedScale : 1,
        duration: MotionDurations.micro,
        curve: MotionCurves.press,
        child: widget.child,
      ),
    );
  }
}

/// 列表错峰入场：淡入 + 自下 20px 滑入。
///
/// 延迟 = min(index * 30ms, 240ms)，动画时长 [MotionDurations.base]，
/// 有限时长、总延迟封顶，pumpAndSettle 可收敛；测试环境直接静态渲染。
class StaggeredListItem extends StatefulWidget {
  const StaggeredListItem({
    super.key,
    required this.index,
    required this.child,
  });

  final int index;
  final Widget child;

  @override
  State<StaggeredListItem> createState() => _StaggeredListItemState();
}

class _StaggeredListItemState extends State<StaggeredListItem>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: MotionDurations.base,
    value: Motion.inTest ? 1 : 0,
  );

  late final CurvedAnimation _curve = CurvedAnimation(
    parent: _controller,
    curve: MotionCurves.standard,
  );

  bool _armed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_armed) return;
    _armed = true;
    if (Motion.inTest) return;
    // 列表 item 滚出视口会被回收、拉回时重建。若此刻重播入场动画，
    // 快速滚动时路过的卡片会反复闪动；滚动进行中新建的 item 直接
    // 以完成态渲染，只有页面静止时的首次构建才播错峰入场。
    final scrolling =
        Scrollable.maybeOf(context)?.position.isScrollingNotifier.value ??
            false;
    if (scrolling) {
      _controller.value = 1;
      return;
    }
    final delay = Duration(
      milliseconds: math.min(widget.index * 30, 240),
    );
    Future<void>.delayed(delay, () {
      if (mounted) _controller.forward();
    });
  }

  @override
  void dispose() {
    _curve.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.inTest) return widget.child;
    return FadeTransition(
      opacity: _curve,
      child: AnimatedBuilder(
        animation: _curve,
        builder: (context, child) => Transform.translate(
          offset: Offset(0, 20 * (1 - _curve.value)),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

/// 骨架屏微光盒子：1200ms 循环微光，测试环境返回静态底色（不循环）。
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    this.width,
    this.height = 16,
    this.radius = 8,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  AnimationController _makeController() {
    final controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (!Motion.inTest) controller.repeat();
    return controller;
  }

  late final AnimationController _controller = _makeController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final base = BoxDecoration(
      color: colors.surfaceContainerHighest.withValues(alpha: .55),
      borderRadius: BorderRadius.circular(widget.radius),
    );
    if (Motion.inTest) {
      return Container(width: widget.width, height: widget.height, decoration: base);
    }
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        final t = _controller.value;
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: base.copyWith(
            gradient: LinearGradient(
              begin: Alignment(-1 + 2 * t, 0),
              end: Alignment(0 + 2 * t, 0),
              colors: [
                Colors.transparent,
                colors.onSurface.withValues(alpha: .06),
                Colors.transparent,
              ],
            ),
          ),
        );
      },
    );
  }
}

/// 全局页面转场：淡入 + 0.97→1 微缩放，时长 [MotionDurations.page]。
///
/// 挂到 `pageTransitionsTheme` 后所有 MaterialPageRoute 自动生效。
class FadeScalePageTransitionsBuilder extends PageTransitionsBuilder {
  const FadeScalePageTransitionsBuilder();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(
      parent: animation,
      curve: MotionCurves.standard,
      reverseCurve: MotionCurves.exit,
    );
    return FadeTransition(
      opacity: curved,
      child: ScaleTransition(
        scale: Tween<double>(begin: 0.97, end: 1).animate(curved),
        child: child,
      ),
    );
  }
}

/// 内容淡切：子树替换时以 [MotionDurations.base] 交叉淡入淡出。
class FadeSwitcher extends StatelessWidget {
  const FadeSwitcher({super.key, this.duration, required this.child});

  final Duration? duration;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: duration ?? MotionDurations.base,
      switchInCurve: MotionCurves.standard,
      switchOutCurve: MotionCurves.exit,
      child: child,
    );
  }
}
