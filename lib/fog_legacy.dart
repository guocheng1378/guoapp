import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:haze/haze.dart';

import 'fog_tuning.dart';
import 'glass_preferences.dart';

/// 顶栏雾面（现役唯一顶栏蒙版）：**MIUI 雾面带真值直译 + 渐变模糊**。
///
/// 模糊层 = `haze` 0.5.0 的 [Haze]（照搬官方用法：指定 edge + sigma，
/// child 画在效果之上）。[Haze] 用 fragment shader 做**真·可变半径高斯**：
/// σ 从顶边满值连续衰减到 0（几何级数 ramp、末端精确归零，无可见台阶），
/// 与下方 tint 层的羽化同一条 falloff。
///
/// tint 层 = **零黑配方**（v2239）：只提亮、不压暗 —— 白 30% + 冷灰 20% 的
/// `screen` 层（见 [_LegacyTopFogTintPainter]）。官方三层混色里层1/层3 都是
/// 压暗层，在**深色海报**上必然压出黑带（用户连续三轮反馈"还有一层黑"），
/// 官方 demo 之所以不显黑是因其背景是浅色 MIUI 壁纸。
///
/// 官方真值来源 = 用户从 MIUI 主题商店包里挖出的 `theme_store_demo`
/// `home_page._fogHeader`（逐行核对）：
/// - 模糊 σ **20**（`ImageFilter.blur(sigmaX: 20, sigmaY: 20)`；注释「半径真值
///   round(20 × density + 0.5) = 20dp」）——注意 σ30 是**圆形按钮** FogButton
///   的值，别混；
/// - **底色隐身**：整条没有自己的底色，内容色彩从模糊层透出；
/// - 混色 = 系统三层 `ColorBlendToken.l`（手机档，v=1 全强度）：
///   层1 `#1A000000` darken（Flutter 无 plusDarker → 降级）、
///   层2 `#996C6C6C` luminosity、层3 `#99060606` softLight，三层**铺满整条**；
/// - 状态栏区再压一层 `#47000000`（高度 = 状态栏高）。
///
/// 官方三层 + 状态栏压暗的**原样留档**在 painter 末尾注释里（要严格照搬时
/// 启用即可）；当前默认走零黑配方。
///
/// 我们额外保留的两项**改良**（不是官方，去掉会重现老问题）：
/// 底缘羽化 160px（官方是硬边 → 用户反复投诉"明显的分界线"）、
/// 上浓下淡雾形（用户 2150 定调）。
///
/// 结构铁律：整条 ClipRect 内单层模糊（下方内容），随后在 tint 层内平涂。
/// ⚠️ blur 必须直挂裁剪祖先，中间不能隔 saveLayer 类 widget
/// （ShaderMask/Opacity/ColorFiltered——曾用 ShaderMask 做底缘羽化，结果
/// blur 被关进空 offscreen buffer、采样不到底下内容，雾感只剩白蒙）。羽化改由
/// painter 在 tint 层内部用 shader 渐隐实现。
class LegacyTopFog extends StatelessWidget {
  const LegacyTopFog({super.key});

  /// 运行时自检：**只打一次**。
  ///
  /// `haze` 的降级警告包在 `assert()` 里 → release 包不打印 → 无法从 logcat
  /// 判断「真机到底走的是 fragment shader（真·渐变模糊）还是 bands 多段
  /// fallback（会露出分层台阶）」。这里自己打一行，release 也可见。
  static bool _probed = false;
  static void _probeOnce() {
    if (_probed) return;
    _probed = true;
    debugPrint(
      '[fog] shaderFilterSupported=${ImageFilter.isShaderFilterSupported}',
    );
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPreferences.enabled,
      builder: (context, glass, _) {
        if (!glass) return const SizedBox.shrink();
        _probeOnce();
        // 模糊范围是「当前裁剪区域」：外层 ClipRect 圈住整条雾面，否则整屏糊。
        //
        // ⚠️ blur 必须直挂裁剪祖先，中间不能隔 saveLayer 类 widget
        //（ShaderMask/Opacity/ColorFiltered——曾用 ShaderMask 做底缘羽化，
        // 结果 blur 被关进空 offscreen buffer、采样不到底下内容，雾面只剩
        // tint 白蒙，真机实锤海报文字清晰如常=雾感丢失）。羽化改由
        // _LegacyTopFogTintPainter 在 tint 层内部实现。
        return ValueListenableBuilder<FogTuningState>(
          valueListenable: FogTuningStore.state,
          builder: (context, tuning, _) {
            return ClipRect(
              child: Haze(
                // 渐变模糊：σ 从顶边满值连续衰减到 0（官方 haze 用法）。
                edge: HazeEdge.top,
                sigma: tuning.blurSigma,
                // 单 CustomPaint 直吃紧约束（不要包 Stack——无子级时
                // CustomPaint 会缩到 0×0，tint 层直接消失）。Haze 的 child 画在
                // 模糊层**之上**，且 child 的尺寸决定模糊区域的尺寸。
                child: CustomPaint(
                  painter: _LegacyTopFogTintPainter(tuning: tuning),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 雾面 tint 层（v2239 起：**零黑**配方）。
///
/// ## 为什么不再照搬官方三层
/// 官方 `ColorBlendToken.l` 三层里，层1 `#1A000000`（darken，**纯黑**）和
/// 层3 `#99060606`（softLight，**近黑 60%**）都是**压暗**层；官方 demo 盖在
/// **浅色 MIUI 壁纸**上只压一点点、读作"雾"。我们的背景是**深色海报/深色
/// 壁纸**——真机实测：内容穿顶时顶部 lum=38（海报原色透出），压暗层会让
/// 顶部**更黑**（softLight 近黑把 cb=0.1 压到 0.048），于是顶栏读作"一层
/// 黑蒙版"。用户连续三轮反馈"还有一层黑"。
///
/// ## 现在的配方：只提亮、不压暗（雾的物理 = 散射光）
/// - 层A `#4DFFFFFF` **screen**（白 30%）：暗部提亮成雾灰，**亮部完全不变**
///   （screen 在 cb=1 时结果仍是 1）→ 浅色壁纸顶栏零变化、深色海报变灰白雾；
/// - 层B `#336C6C6C` **screen**（冷灰 20%）：给雾一点冷灰调，并进一步提亮。
///
/// **顶栏从此不可能出现黑色蒙版**（没有任何压暗/纯黑层）。要还原官方原配方
/// （含 `#1A000000` darken + `#996C6C6C` luminosity + `#99060606` softLight +
/// 状态栏 `#47000000`）见本文件末尾注释。
class _LegacyTopFogTintPainter extends CustomPainter {
  _LegacyTopFogTintPainter({required this.tuning});

  final FogTuningState tuning;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    // 底缘羽化在 tint 层内部做（shader 渐隐）；blur 层不羽化。
    final feather = tuning.feather.clamp(0.0, size.height);
    // 渐变起点：**顶部必须保持基准浓度**（雾在顶边最浓）。
    // 羽化 ≥ 雾带高度时（feather 160 vs 雾带 ~96）起点会算成 0 →
    // 渐变首色被下一色覆盖 → 顶部浓度掉到 25%（"雾没浓度"的真因）。
    // 这里给平台保底 35%：顶部恒基准、底部渐隐到 0。
    final fadeStart = ((size.height - feather) / size.height).clamp(0.0, 1.0);
    final platform = fadeStart <= 0 ? 0.35 : fadeStart;
    // 垂直雾形：0=均匀玻璃板；1=雾形全开（上浓下淡）。
    final vg = tuning.verticalGrad.clamp(0.0, 1.0);
    final bottomMul = 1.0 - 0.75 * vg;
    Paint layer(Color base, [BlendMode? mode]) {
      final p = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, platform, 1.0],
          colors: [
            // clamp 兜底：任何乘算都不得越过 1（越界 = 变成实色遮罩）。
            base.withValues(alpha: base.a.clamp(0.0, 1.0)),
            base.withValues(alpha: (base.a * bottomMul).clamp(0.0, 1.0)),
            base.withValues(alpha: 0),
          ],
        ).createShader(rect);
      if (mode != null) p.blendMode = mode;
      return p;
    }

    // ① 层A：白 22% screen —— 暗部提亮成雾灰，亮部不变（雾的主层）。
    //    v2240 由 30% 降到 22%：用户要「再透点」= 更少遮挡、更通透。
    canvas.drawRect(rect, layer(const Color(0x38FFFFFF), BlendMode.screen));
    // ② 层B：冷灰 12% screen —— 雾的冷灰调 + 进一步提亮（原 20% → 12%）。
    canvas.drawRect(rect, layer(const Color(0x1F6C6C6C), BlendMode.screen));

    // ③ 官方原配方（**默认不启用**，仅留档；用户要"严格照搬官方"时启用）：
    //    canvas.drawRect(rect, layer(const Color(0x1A000000), BlendMode.darken));
    //    canvas.drawRect(rect, layer(const Color(0x996C6C6C), BlendMode.luminosity));
    //    canvas.drawRect(rect, layer(const Color(0x99060606), BlendMode.softLight));
    //    // 官方状态栏压暗（硬边纯黑矩形，v2238 已删）：
    //    final sb = statusBarHeight.clamp(0.0, size.height);
    //    if (sb > 0) {
    //      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, sb),
    //          Paint()..color = const Color(0x47000000));
    //    }
  }

  @override
  bool shouldRepaint(_LegacyTopFogTintPainter oldDelegate) =>
      !oldDelegate.tuning.equals(tuning);
}
