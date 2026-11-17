import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 「轻量玻璃」全局开关（原「动效降级」，已改为**保留模糊**）。
///
/// 早期版本开启后会把磨砂模糊直接抹成 0（纯底色 + 描边）。实测结论：
/// - 视觉上等于换了一套 UI（用户：「模糊没有了不行」）；
/// - 性能上并没有变流畅——真正的大头是滚动时每档接近度重建整棵胶囊
///   子树（见 `SoftGlassSurface.edgeProx`），与模糊无关。
///
/// 现在的语义：**模糊永远保留**，只把 σ 乘一个系数、并跳过两次大半径
/// `MaskFilter.blur`（内阴影/内高光）。给极端低端机留的出口，不是默认档。
///
/// 与 [GlassPreferences.enabled] 的区别：后者是「玻璃 vs 不透明浮层」的视觉
/// 选择（关掉仍有柔和质感），本开关是「同一套玻璃、更省的渲染」。
abstract final class MotionPerformance {
  /// v2：旧键 `motion.lowPower` 的语义是「把模糊抹成 0」，已被用户判定
  /// 不可接受。换键后老装机上残留的「已开启」自动失效（默认回到满档玻璃），
  /// 不会再有人带着一个看不见的「零模糊」开关跑。
  static const String _key = 'motion.lowPower.v2';

  /// 路由转场（回退/进场/弹窗动画）期间的模糊 σ 系数。
  ///
  /// 0.55：σ 18 → 9.9，仍是明确的磨砂（不是清透），高斯核采样量按
  /// σ² 降到约 30%；动画结束回 1.0 的落差在运动中几乎不可辨（两端都是
  /// 磨砂）。弹层（站源菜单/筛选浮卡一屏十几枚胶囊各自采样）最吃这个。
  static const double motionSigmaScale = 0.55;

  /// 「轻量玻璃」开关打开时的 σ 系数（模糊更浅但仍在）。
  static const double lowPowerSigmaScale = 0.5;

  /// true=轻量玻璃（σ 减半 + 去内阴影，模糊不消失）。
  static final ValueNotifier<bool> lowPower = ValueNotifier(false);

  /// 启动时从持久化恢复（main.dart 与 GlassPreferences.load 同点调用）。
  static Future<void> load(SharedPreferences prefs) async {
    lowPower.value = prefs.getBool(_key) ?? false;
  }

  /// 写盘并通知全部玻璃面刷新；写失败仅静默（下次启动不记忆）。
  static Future<void> setLowPower(bool value) async {
    final previous = lowPower.value;
    lowPower.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setBool(_key, value)) {
        lowPower.value = previous;
      }
    } catch (_) {
      // 写盘失败要回滚：否则界面显示「已开启」、重启却回到旧值，用户无法
      // 判断到底是没生效还是没保存。
      lowPower.value = previous;
    }
  }
}
