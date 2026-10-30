import 'package:flutter/material.dart';

/// 路由**回退**（返回上一屏）动画进行中的全局信号。
///
/// 背景（真机实测到的卡顿链）：
/// - 回退转场给整页加 `ScaleTransition`（0.97→1）→ 变换每帧变化，页内
///   所有 `RepaintBoundary` 缓存失效，整页子树每帧重新 paint；
/// - 页面里的玻璃面（胶囊岛/分类条/底栏/面板）每个都带
///   `BackdropFilter`（真磨砂 σ14）+ 两次大半径 `MaskFilter.blur`
///   （柔光内阴影/内高光）→ 每帧都要重新采样背景 + 重新模糊 → 在中高端
///   机上也明显掉帧，表现为「返回上一屏卡一下」。
///
/// 对策：回退动画期间把这些**重玻璃**临时降级为「不透明底色 + 纯描边」
/// （零模糊、零 MaskFilter），动画结束的下一帧立即恢复。进出场动画
/// （push）**不降级**——否则页面刚出现的一瞬玻璃会变实底，肉眼可见闪变。
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
