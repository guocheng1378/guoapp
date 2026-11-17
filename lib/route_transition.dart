import 'package:flutter/material.dart';

import 'motion_tokens.dart';

/// 全局路由观察器：首页用它感知「上层页面被 pop、自己重新成为当前页」，
/// 及时收掉被 FocusScope 还给搜索框的文本焦点（否则输入法会跟着弹回来）。
final RouteObserver<PageRoute<dynamic>> appRouteObserver =
    RouteObserver<PageRoute<dynamic>>();

/// 路由**回退**（返回上一屏）动画进行中的全局信号。
///
/// 背景（真机实测到的卡顿链）：
/// - 回退转场给整页加 `FadeTransition` → opacity < 1 时整页进 `saveLayer`，
///   页内所有 `RepaintBoundary` 缓存失效，整页子树每帧重新 paint；
/// - 页面里的玻璃面背后每帧都在变，`BackdropFilter` 需要重新采样背景。
///
/// 对策：**保留模糊**（模糊是这套材质的本体，抹掉就是换了套 UI），只在
/// 回退时把 σ 乘 `MotionPerformance.motionSigmaScale` 降采样 + 跳过内阴影
/// /内高光两次大半径 `MaskFilter.blur`，动画结束的下一帧恢复满档。
///
/// 进场（push）**不降级**：全局广播一次「转场中」会让屏幕上每一枚玻璃面
/// 整棵子树重建，代价远高于高斯核缩小省下的采样量，实测反而更卡。
abstract final class RouteTransitionSignal {
  /// 回退中为 true（供玻璃面/顶栏监听）。
  static final ValueNotifier<bool> reversing = ValueNotifier<bool>(false);

  /// 并发计数（多条路由同时回退时不会提前解除降级）。
  static int _depth = 0;

  /// 当前是否处于回退动画中。
  static bool get isReversing => reversing.value;

  /// 标记一次回退动画开始。
  static void beginReverse() {
    _depth++;
    if (_depth == 1) reversing.value = true;
  }

  /// 标记一次回退动画结束（计数不足时忽略，避免误减）。
  static void endReverse() {
    if (_depth <= 0) return;
    _depth--;
    if (_depth == 0) reversing.value = false;
  }

  /// 测试用：直接置位/复位（绕过计数）。
  @visibleForTesting
  static void debugSetReversing(bool value) {
    _depth = value ? 1 : 0;
    reversing.value = value;
  }

}

/// 全局页面转场：纯淡入淡出，时长 [MotionDurations.page]。
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
    // 只做淡入淡出：缩放会让整页每帧重绘（矩阵连续变化时 FadeTransition 的
    // 缓存层失效，页内玻璃面随之每帧重采样），是回退/切页卡顿的主要来源。
    return _RouteTransitionScope(
      animation: animation,
      child: FadeTransition(opacity: curved, child: child),
    );
  }
}

/// 转场作用域：把「回退 / 进场动画进行中」广播给全局信号。
///
/// 只监听动画**状态**（不逐帧 tick）：回退开始置位、结束复位。
class _RouteTransitionScope extends StatefulWidget {
  const _RouteTransitionScope({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_RouteTransitionScope> createState() => _RouteTransitionScopeState();
}

class _RouteTransitionScopeState extends State<_RouteTransitionScope> {
  /// 本次是否已持有回退降级名额（保证 begin/end 严格配对）。
  bool _holding = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
    _sync();
  }

  @override
  void didUpdateWidget(covariant _RouteTransitionScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.animation != widget.animation) {
      oldWidget.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
      _sync();
    }
  }

  void _onStatus(AnimationStatus status) => _sync();

  void _sync() {
    final reverse = widget.animation.status == AnimationStatus.reverse;
    if (reverse && !_holding) {
      _holding = true;
      RouteTransitionSignal.beginReverse();
    } else if (!reverse && _holding) {
      _holding = false;
      RouteTransitionSignal.endReverse();
    }
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    if (_holding) {
      _holding = false;
      RouteTransitionSignal.endReverse();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
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
