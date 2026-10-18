import 'dart:ui';

import 'package:flutter/material.dart';

import 'glass_preferences.dart';

/// 玻璃浮层的两类使用场景。
enum GlassVariant {
  /// 浮在 App 内容之上：底栏、弹窗、多选条、吸顶栏，随深浅主题瓷面。
  surface,

  /// 浮在视频画面之上：播放器控制层、选集/倍速弹窗，统一深色瓷面。
  overlay,
}

/// 统一的瓷面令牌。
///
/// 所有浮层共用同一套底色/描边/圆角档位，避免各自手写半透明容器导致
/// 视觉割裂；新增瓷面表面时请优先复用这里的常量。
abstract final class GlassTokens {
  /// 横向栏（底栏、播放器顶/底栏、多选条）。
  static const double radiusBar = 28;

  /// 底部弹窗（仅上方圆角由调用方通过 borderRadius 指定）。
  static const double radiusSheet = 28;

  /// 药丸/圆形控件（播放器图标按钮）。
  static const double radiusChip = 22;

  /// 分类/筛选胶囊（滑动栏、排序面板同款）。
  static const double radiusChipSmall = 18;

  static const double borderWidth = 1;
  static const double highlightHeight = 2.5;
}

/// 瓷面底色档位：按表面积从「胶囊」到「信息卡」逐档变实，
/// 避免每个调用方手写裸 alpha 造成同材质不同观感。
enum GlassTint {
  /// 胶囊/小控件（滑动栏、菜单项、搜索框、圆钮）：微透白瓷。
  chip,

  /// 横向长条（底栏、多选条、详情底部条、TV 分类底板）。
  bar,

  /// 底部大面板（排序面板）。
  sheet,

  /// 弹窗（GlassDialogShell 默认）。
  dialog,

  /// 文字信息卡（关于、资料、启动屏提示卡）。
  card,
}

/// 全 App 胶囊的唯一配方（滑动栏瓷面）：
/// 未选=微透白瓷+白描边+轻影，选中=黑瓷白字（暗色反转白瓷黑字）。
///
/// 滑动栏 _StoreChip、app_theme chipTheme、排序面板 _filterChip、
/// 底栏选中项、GlassSurface.palette 全部引用本组常量——
/// 改胶囊观感只改这里，不允许第二套胶囊视觉。
abstract final class GlassChipTokens {
  /// 未选瓷面底色透明度。
  static const double tintAlphaLight = 0.72;
  static const double tintAlphaDark = 0.08;

  /// 胶囊圆角与字号（滑动栏基准）。
  static const double radius = GlassTokens.radiusChipSmall;
  static const double fontSize = 14;

  /// 未选描边（白描边是瓷面轮廓的主要来源）。
  static const double edgeAlphaLight = 0.50;
  static const double edgeAlphaDark = 0.08;

  /// 选中瓷面：浅色黑瓷 / 暗色白瓷（反转）。
  static const Color selectedLight = Color(0xFF1C1C1E);
  static const Color selectedDark = Color(0xFFFFFFFF);

  /// 未选轻影（选中态无影）。
  static const double shadowAlphaLight = 0.06;
  static const double shadowAlphaDark = 0.20;
  static const double shadowBlur = 8;
  static const Offset shadowOffset = Offset(0, 2);

  /// 未选瓷面底色。
  static Color tint(bool dark) =>
      Colors.white.withValues(alpha: dark ? tintAlphaDark : tintAlphaLight);

  /// 未选描边色。
  static Color edge(bool dark) =>
      Colors.white.withValues(alpha: dark ? edgeAlphaDark : edgeAlphaLight);

  /// 选中底色。
  static Color selected(bool dark) => dark ? selectedDark : selectedLight;

  /// 选中前景（字/图标）。
  static Color onSelected(bool dark) => dark ? selectedLight : selectedDark;

  /// 未选轻影。
  static List<BoxShadow> shadow(bool dark) => [
    BoxShadow(
      color: Colors.black.withValues(
        alpha: dark ? shadowAlphaDark : shadowAlphaLight,
      ),
      blurRadius: shadowBlur,
      offset: shadowOffset,
    ),
  ];
}

/// 全 App 胶囊的唯一实现（滑动栏瓷面）：未选微透白瓷+白描边+轻影，
/// 选中黑瓷白字（暗色反转白瓷黑字）。
///
/// 滑动栏分类、排序面板筛选、以及 app_theme chipTheme 覆盖的 Material
/// Chip 系全部同源；需要新胶囊时直接复用本组件，不要另写配方。
class GlassChip extends StatelessWidget {
  const GlassChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.trailing,
    this.fontSize = 14,
    this.hitTarget = 0,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  /// 选中态尾随控件（如排序面板的对勾），颜色自动取选中前景色。
  final Widget? trailing;
  final double fontSize;

  /// 透明命中区高度（>0 时把可点区域撑到该高度，视觉胶囊尺寸不变，
  /// 解决 ~31px 胶囊低于 48px 可点性标准的问题；水波同步改胶囊形）。
  final double hitTarget;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
      decoration: BoxDecoration(
        color: selected
            ? GlassChipTokens.selected(dark)
            : GlassChipTokens.tint(dark),
        borderRadius: BorderRadius.circular(GlassChipTokens.radius),
        border: selected ? null : Border.all(color: GlassChipTokens.edge(dark)),
        boxShadow: selected ? null : GlassChipTokens.shadow(dark),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              color: selected
                  ? GlassChipTokens.onSelected(dark)
                  : theme.colorScheme.onSurface,
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 4),
            trailing!,
          ],
        ],
      ),
    );
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(GlassChipTokens.radius),
          // 命中区撑高后水波也要保持胶囊形，否则是一根圆角矩形。
          customBorder:
              hitTarget > 0 ? const StadiumBorder() : null,
          // 按住/悬停高亮：选中黑瓷上用白色提亮，未选白瓷上用主色。
          overlayColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.pressed)) {
              return selected
                  ? Colors.white.withValues(alpha: .14)
                  : theme.colorScheme.primary.withValues(alpha: .16);
            }
            if (states.contains(WidgetState.hovered) ||
                states.contains(WidgetState.focused)) {
              return selected
                  ? Colors.white.withValues(alpha: .08)
                  : theme.colorScheme.primary.withValues(alpha: .08);
            }
            return null;
          }),
          child: hitTarget > 0
              ? SizedBox(height: hitTarget, child: Center(child: chip))
              : chip,
        ),
      ),
    );
  }
}

/// 瓷面表面：半透明实底 + 细描边 + 顶部高光 + 悬浮投影（对齐小米主题商店
/// 胶囊/底栏的「白瓷」语言，不做逐层模糊）。
///
/// 背后已绘制内容（雾面场景已被 TopFog σ4.5 糊过）会透过底色微微显影，
/// 子内容始终清晰；深浅主题自动切换底色与描边透明度；设置关闭玻璃后整体
/// 降级为不透明面。
class GlassSurface extends StatelessWidget {
  const GlassSurface({
    super.key,
    required this.child,
    this.variant = GlassVariant.surface,
    this.radius = GlassTokens.radiusChip,
    this.borderRadius,
    this.topHighlight = false,
    this.elevated = true,
    this.bordered = true,
    this.padding = EdgeInsets.zero,
    this.constraints,
    this.tint = GlassTint.chip,
  });

  final Widget child;
  final GlassVariant variant;

  /// 四角统一圆角；需要只圆某几角（如底部弹窗）时改用 [borderRadius]。
  final double radius;
  final BorderRadius? borderRadius;
  final bool topHighlight;
  final bool elevated;
  final bool bordered;
  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  /// 瓷面底色档位（默认胶囊档）；关闭玻璃时仍降级为 palette 不透明配色。
  final GlassTint tint;

  /// palette 缓存：组合只有 (variant, brightness, enabled) 三种维度
  /// 共 8 种，每个 GlassSurface 实例都算一遍纯属浪费。
  static final Map<
    (GlassVariant, Brightness, bool),
    ({Color tint, Color edge, Color sheen})
  >
  _paletteCache = {};

  /// 取当前主题下的玻璃配色，供必须手写背景的场景（如系统弹窗 shape）复用。
  ///
  /// [enabled] 为 false 时返回不透明等价配色（与降级后的 GlassSurface 一致）。
  static ({Color tint, Color edge, Color sheen}) palette(
    GlassVariant variant,
    Brightness brightness, {
    bool enabled = true,
  }) => _paletteCache.putIfAbsent((variant, brightness, enabled), () {
    return _palette(variant, brightness, enabled: enabled);
  });

  static ({Color tint, Color edge, Color sheen}) _palette(
    GlassVariant variant,
    Brightness brightness, {
    required bool enabled,
  }) {
    final dark = brightness == Brightness.dark;
    if (!enabled) {
      return switch (variant) {
        GlassVariant.surface => (
          tint: dark ? const Color(0xFF16171B) : const Color(0xFFFAF8F6),
          edge: Colors.white.withValues(alpha: dark ? 0.08 : 0.30),
          sheen: Colors.white.withValues(alpha: dark ? 0.10 : 0.35),
        ),
        GlassVariant.overlay => (
          tint: const Color(0xE616171B),
          edge: Colors.white.withValues(alpha: 0.10),
          sheen: Colors.white.withValues(alpha: 0.14),
        ),
      };
    }
    return switch (variant) {
      GlassVariant.surface => (
        tint: _glassTint(
          base: dark ? const Color(0xFF16171B) : const Color(0xFFFAF8F6),
          dark: dark,
          alpha: dark ? 0.28 : 0.34,
        ),
        // 描边对齐分类胶囊：白描边是瓷面轮廓的主要来源。
        edge: GlassChipTokens.edge(dark),
        sheen: Colors.white.withValues(alpha: dark ? 0.45 : 0.60),
      ),
      GlassVariant.overlay => (
        tint: _glassTint(
          base: const Color(0xFF101114),
          dark: true,
          // 瓷面去掉 blur 后，播放器控制层底色要实（0.62 黑），
          // 否则视频画面直接透上来，控件发飘。
          alpha: 0.62,
        ),
        edge: Colors.white.withValues(alpha: 0.26),
        sheen: Colors.white.withValues(alpha: 0.45),
      ),
    };
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    return ListenableBuilder(
      listenable: GlassPreferences.enabled,
      builder: (context, _) {
        final dark = brightness == Brightness.dark;
        final glass = GlassPreferences.enabled.value;
        final colors = palette(variant, brightness, enabled: glass);
        // 瓷面（对齐小米主题商店胶囊/底栏）：去掉 BackdropFilter，
        // 改为半透实底——雾面场景背后已被 TopFog σ4.5 糊过，透出的
        // 是柔雾而非锐利内容；非雾面场景则是小米式微透瓷面。
        // 底色档位由 [tint] 枚举决定；关闭玻璃时保持 palette 的
        // 不透明降级配色，浮层不会被压回半透明。
        final alpha = switch (tint) {
          GlassTint.chip => dark
              ? GlassChipTokens.tintAlphaDark
              : GlassChipTokens.tintAlphaLight,
          GlassTint.bar => dark ? 0.30 : GlassChipTokens.tintAlphaLight,
          GlassTint.sheet => dark ? 0.66 : 0.80,
          GlassTint.dialog => dark ? 0.45 : 0.55,
          GlassTint.card => dark ? 0.72 : 0.82,
        };
        final fill = !glass
            ? colors.tint
            : colors.tint.withValues(alpha: alpha);
        final shape = borderRadius ?? BorderRadius.circular(radius);
        final decoration = BoxDecoration(
          color: fill,
          border: bordered
              ? Border.all(color: colors.edge, width: GlassTokens.borderWidth)
              : null,
        );
        // 精简路径：无顶部高光且无内边距时，不再包 Stack/Padding 两层。
        final content = topHighlight || padding != EdgeInsets.zero
            ? Stack(
                children: [
                  if (topHighlight)
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      height: GlassTokens.highlightHeight,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              colors.sheen,
                              colors.sheen.withValues(alpha: 0),
                            ],
                          ),
                        ),
                      ),
                    ),
                  Padding(padding: padding, child: child),
                ],
              )
            : child;

        return Container(
          constraints: constraints,
          decoration: BoxDecoration(
            borderRadius: shape,
            boxShadow: elevated
                ? [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
                      blurRadius: 24,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: shape,
            child: DecoratedBox(
              decoration: decoration,
              child: content,
            ),
          ),
        );
      },
    );
  }

  /// 玻璃底色：基础色向品牌主色轻微靠拢，形成澎湃式“染色玻璃”；
  /// 染色极浅（约 4%），主要质感仍来自低 alpha 下的背景色透射。
  static Color _glassTint({
    required Color base,
    required bool dark,
    required double alpha,
  }) {
    final primary = dark ? const Color(0xFFFF765F) : const Color(0xFFAD3826);
    return Color.lerp(base, primary, dark ? 0.04 : 0.035)!
        .withValues(alpha: alpha);
  }
}

/// 对话框玻璃外壳：dialogTheme 已将弹窗背景透明化，AlertDialog/SimpleDialog
/// 返回值包一层本组件即可获得瓷面质感（圆角/投影/描边统一）。
class GlassDialogShell extends StatelessWidget {
  const GlassDialogShell({
    super.key,
    required this.child,
    this.constraints,
    this.tint = GlassTint.dialog,
  });

  final Widget child;
  final BoxConstraints? constraints;
  final GlassTint tint;

  @override
  Widget build(BuildContext context) {
    return GlassSurface(
      variant: GlassVariant.surface,
      radius: GlassTokens.radiusSheet,
      topHighlight: true,
      // 默认收到半屏宽：AlertDialog 默认 560 在宽屏上几乎全宽，
      // 瓷壳会撑成一条超长胶囊。
      constraints: constraints ?? const BoxConstraints(maxWidth: 280),
      // 弹窗与胶囊菜单同一材质语言。
      tint: tint,
      child: Material(type: MaterialType.transparency, child: child),
    );
  }
}

/// AppBar flexibleSpace 的贴顶雾面：内容上滑穿过状态栏与顶栏区域时
/// 呈现雾面，随深浅主题换底色；受「玻璃效果」开关总控，关闭后完全穿透。
///
/// 形态：整块恒定 σ4.5 的 blur + 同高度纯色白蒙，底缘硬切——自上而下
/// 衰减会让条行比顶栏清（读作「雾面不连续」），白蒙做渐变收尾则会与
/// blur 硬切速度不一致留下横带，故两者都取一整块。
class TopFog extends StatelessWidget {
  const TopFog({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPreferences.enabled,
      builder: (context, glass, _) {
        if (!glass) return const SizedBox.shrink();
        final dark = Theme.of(context).brightness == Brightness.dark;
        final base = dark ? Colors.black : Colors.white;
        // 对齐小米主题商店真机实测：雾面=恒定 σ4.5 的一整块，状态栏
        // →AppBar→分类条糊度完全一致（中途无衰减带——衰减会让条行
        // 比顶栏清，读作「雾面不连续」），条底直接硬切、无渐隐尾。
        // σ2 起才有可感知雾感，糊影要 σ4+ 才「化开」。
        Widget layer(double top, double height, double sigma) => Positioned(
              left: 0,
              right: 0,
              top: top,
              height: height,
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
                  child: const SizedBox.expand(),
                ),
              ),
            );
        return ClipRect(
          child: LayoutBuilder(
            builder: (context, c) {
              final h = c.maxHeight;
              return Stack(
              children: [
                layer(0, h, 4.5),
                // 白蒙=纯色一整块（消除渐变分层）：blur 与白蒙同高度、
                // 底缘同时硬切，只留一条与 UI 结构对齐的干净边线（小米
                // 同款）——任何中途收尾都会在亮暗之间留一条横带。
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: base.withValues(alpha: dark ? 0.11 : 0.14),
                    ),
                  ),
                ),
              ],
              );
            },
          ),
        );
      },
    );
  }
}
