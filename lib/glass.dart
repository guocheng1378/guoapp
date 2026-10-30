import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'fog_legacy.dart';
import 'glass_preferences.dart';
import 'soft_glass.dart';

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
  /// 双态玻璃胶囊（demo 分组胶囊真值）：底色直接取
  /// [GlassChipTokens.pill]（不经瓷面 alpha 调制），白描边，开启玻璃时
  /// 带 σ18 真磨砂——底栏、玻璃菜单、搜索框、操作条与 chipTheme 同源。
  pill,

  /// 旧滑动栏瓷面档（板面残余）：微透白瓷。
  chip,

  /// 横向长条（TV 分类底板）。
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
/// **配方已收敛到 [SoftGlassSpec]**（清透磨砂）：浓度/描边/磨砂强度不再
/// 各写一份，全部实时派生自柔光玻璃参数通道——调参台一拖，全 app 胶囊
/// 同步变。此处只保留「形状/字号/选中态/投影」这类与材质无关的常量，
/// 以及为兼容既有调用点保留的派生函数。
abstract final class GlassChipTokens {
  /// 未选底色浓度（浅色）——派生自柔光玻璃配方。
  static double get tintAlphaLight => SoftGlassStore.state.value.tintLight;

  /// 未选底色浓度（深色）——派生自柔光玻璃配方。
  static double get tintAlphaDark => SoftGlassStore.state.value.tintDark;

  /// 胶囊圆角与字号（滑动栏基准）。
  static const double radius = GlassTokens.radiusChipSmall;
  static const double fontSize = 14;

  /// 未选描边强度（浅色）——派生自柔光玻璃配方。
  static double get edgeAlphaLight => SoftGlassStore.state.value.edge;

  /// 未选描边强度（深色）——深色按浅色的一半跟随。
  static double get edgeAlphaDark => SoftGlassStore.state.value.edge * 0.5;

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

  /// —— 双态玻璃胶囊（清透磨砂配方）——
  /// 未选=清透玻璃（浅 0.14 / 深 0.22）+真磨砂 σ14+柔光三特征；
  /// 选中=深色实底（要可读）。
  static const Color pillSelectedLight = Color(0xA6000000);
  static const Color pillSelectedDark = Color(0xB8FFFFFF);

  /// 未选胶囊底色（派生自柔光玻璃配方）。
  static Color pill(bool dark) => SoftGlassTokens.tint(
    SoftGlassStore.state.value,
    dark ? Brightness.dark : Brightness.light,
  );

  static Color pillSelected(bool dark) =>
      dark ? pillSelectedDark : pillSelectedLight;

  /// 双态描边：派生自柔光玻璃描边配方，选中态略亮作轮廓强调。
  static Color pillEdge(bool dark, {required bool selected}) {
    final spec = SoftGlassStore.state.value;
    final base = SoftGlassTokens.edge(
      spec,
      dark ? Brightness.dark : Brightness.light,
    ).a;
    return Colors.white.withValues(
      alpha: (selected ? base * 1.2 : base).clamp(0.0, 1.0).toDouble(),
    );
  }

  /// 接近度亮起描边（demo chips 真值：白描边 0.25+0.55h；h=滚动
  /// 距离/50 clamp 0..1，内容一推出、滚回顶部即熄灭）。暗色 demo
  /// 无真值，按同幅收敛。
  /// h=0 时与 [pillEdge] 完全一致，视觉基线不变。
  static Color pillEdgeLit(
    bool dark, {
    required bool selected,
    required double h,
  }) {
    final base = pillEdge(dark, selected: selected).a;
    return Colors.white.withValues(
      alpha: ((dark ? 0.45 : 0.55) * h + base).clamp(0.0, 1.0),
    );
  }
}

/// 全 App 胶囊的唯一实现（双态玻璃胶囊，base(2).apk demo 真值）：
/// 未选=白玻璃+深字，选中=深色玻璃+白字（暗色反转白玻璃+深字）；
/// 玻璃开启时每颗自带 σ18 真磨砂，关闭后降级为不透明瓷面。
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
    this.dense = false,
    this.proxListenable,
    this.inheritBlur = false,
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

  /// 紧凑档（手机横屏分类条用）：内边距 18/9 → 12/5，视觉高度约
  /// 35px → 25px；未传时视觉完全不变。
  final bool dense;

  /// 接近度信号（demo 真值，首页吸顶分类条传入）：内容滚动时白描边
  /// 随 h=滚动距离/50 亮起（0.25→0.80），滚回顶部熄灭。其余场景不传
  /// =保持静态描边，视觉不变。
  final ValueListenable<double>? proxListenable;

  /// 继承上层整条模糊（同层只允许一个 BackdropFilter）：置 true 时胶囊
  /// 不自带 σ 磨砂，只画 tint + 柔光特征——背后已有整条模糊层时避免
  /// 二次采样发灰。默认 false＝自带真磨砂。
  final bool inheritBlur;

  Widget _chip(
    ThemeData theme,
    bool dark,
    BorderRadius shape,
    bool glass, [
    double proxH = 0,
  ]) {
    final fallback = GlassSurface.palette(
      GlassVariant.surface,
      theme.brightness,
      enabled: false,
    );
    // 未选=清透磨砂胶囊；选中=实底（保证文字可读）。描边随接近度亮起。
    final fill = glass
        ? (selected
              ? GlassChipTokens.pillSelected(dark)
              : GlassChipTokens.pill(dark))
        : fallback.tint;
    final edge = glass
        ? GlassChipTokens.pillEdgeLit(dark, selected: selected, h: proxH)
        : fallback.edge;
    return SoftGlassSurface(
      shape: SoftGlassShape.rounded,
      radius: shape.topLeft.x,
      tint: fill,
      edgeColor: edge,
      // 真磨砂：每颗胶囊自带 σ（清透磨砂配方，默认 14）。铁律：
      // BackdropFilter 直挂裁剪祖先，柔光特征层画在其兄弟位置。
      // inheritBlur：上层已有整条模糊时不重复采样（同层单 backdrop）。
      selfBlur: glass && !inheritBlur,
      // demo chips：水平 18、垂直 9 → 高约 40；dense 档收窄到 12/5。
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
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
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(GlassChipTokens.radius);
    return Semantics(
      button: true,
      selected: selected,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: onTap,
          borderRadius: shape,
          // 命中区撑高后水波也要保持胶囊形，否则是一根圆角矩形。
          customBorder: hitTarget > 0 ? const StadiumBorder() : null,
          // 按住/悬停高亮：选中深玻璃上用白色提亮，未选白玻璃上用主色。
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
          child: ListenableBuilder(
            listenable: Listenable.merge([
              GlassPreferences.enabled,
              ?proxListenable,
            ]),
            builder: (context, _) {
              final chip = _chip(
                theme,
                dark,
                shape,
                GlassPreferences.enabled.value,
                proxListenable?.value ?? 0,
              );
              return hitTarget > 0
                  ? SizedBox(height: hitTarget, child: Center(child: chip))
                  : chip;
            },
          ),
        ),
      ),
    );
  }
}

/// 顶栏雾玻璃胶囊岛（demo 搜索胶囊位配方）：σ18 真磨砂 + 半透白/黑
/// 玻璃底 + 白描边随接近度亮起（chips 真值 0.25+0.55h，回顶熄灭）。
///
/// 替代顶栏原 GlassSurface 瓷面岛——瓷面半透白底（0.72 白）叠在雾面
/// 上读作「一层透明膜」；磨砂后与分类胶囊同材质、与雾面同底，顶栏
/// 区域回归雾面本色。关闭玻璃后降级为不透明瓷面。
class FogPill extends StatelessWidget {
  const FogPill({
    super.key,
    required this.child,
    required this.prox,
    this.radius = 24,
    this.inheritBlur = false,
  });

  final Widget child;
  final ValueListenable<double> prox;
  final double radius;

  /// 继承上层整条模糊（顶栏用）：上层已有一层 BackdropFilter 糊过整个顶栏，
  /// 胶囊再自带一层 = 同层双采样 → 发灰。置 true 时胶囊只画 tint + 柔光
  /// 特征（清透但不再二次模糊）；置 false 时胶囊自带 σ 真磨砂（浮岛场景：
  /// 背后没有整条模糊层）。
  final bool inheritBlur;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPreferences.enabled,
      builder: (context, glass, _) {
        final fallback = GlassSurface.palette(
          GlassVariant.surface,
          theme.brightness,
          enabled: false,
        );
        return ListenableBuilder(
          listenable: prox,
          builder: (context, _) => SoftGlassSurface(
            // 真胶囊（MIUI 液态玻璃默认形态）：圆角半径 = 短边一半。
            shape: SoftGlassShape.capsule,
            tint: glass ? GlassChipTokens.pill(dark) : fallback.tint,
            // 白描边随接近度亮起（回顶熄灭）——清透玻璃靠轮廓立形。
            edgeColor: glass
                ? GlassChipTokens.pillEdgeLit(dark, selected: false, h: prox.value)
                : fallback.edge,
            selfBlur: glass && !inheritBlur,
            child: child,
          ),
        );
      },
    );
  }
}

/// 瓷面表面：半透明实底 + 细描边 + 顶部高光 + 悬浮投影（对齐小米主题商店
/// 胶囊/底栏的「白瓷」语言，不做逐层模糊）。
///
/// 例外：[GlassTint.pill] 档是双态玻璃胶囊材质（分类条 [GlassChip] 同源），
/// 开启玻璃时带 σ18 真磨砂。
///
/// 背后已绘制内容（雾面场景已被 TopFog 恒定雾面糊过）会透过底色微微显影，
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
        // 底色档位由 [tint] 枚举决定；pill 档直接取双态胶囊配方
        // （清透磨砂），关闭玻璃时保持 palette 的不透明降级配色，浮层不会
        // 被压回半透明。
        final pill = tint == GlassTint.pill;
        final Color fill;
        if (pill) {
          fill = glass ? GlassChipTokens.pill(dark) : colors.tint;
        } else {
          // 面板类档位在玻璃开启时降一档浓度：真磨砂已经糊过一层，
          // 再叠原来的 0.80/0.82 会把磨砂完全盖住（读作实心瓷面）。
          // 降幅仍高于历史「0.34 太透」那一档，可读性不丢。
          final alpha = switch (tint) {
            GlassTint.pill => 0.0,
            GlassTint.chip => dark
                ? GlassChipTokens.tintAlphaDark
                : GlassChipTokens.tintAlphaLight,
            GlassTint.bar => dark ? 0.30 : GlassChipTokens.tintAlphaLight,
            GlassTint.sheet => dark ? 0.48 : 0.56,
            GlassTint.dialog => dark ? 0.38 : 0.44,
            GlassTint.card => dark ? 0.54 : 0.62,
          };
          fill = !glass ? colors.tint : colors.tint.withValues(alpha: alpha);
        }
        final edge = pill && glass
            ? GlassChipTokens.pillEdge(dark, selected: false)
            : colors.edge;
        // 形态：**大容器一律方形圆角矩形**。
        //
        // 用户 2026-10-29 定调：「那些大胶囊换成方的」。药丸只留给**紧凑小件**
        // （菜单项、标签、圆形 loading 等，调用点用 borderRadius 指定圆角矩形
        // 或直接用 SoftGlassShape.capsule）；凡是宽扁的容器级玻璃（底栏、详情
        // 工具条、搜索框、弹窗、面板、卡片、列表）读作「一块方玻璃板」，不是
        // 药丸。borderRadius 显式指定时（底部弹窗只圆上角）保持原样。
        final shape = borderRadius != null
            ? SoftGlassShape.rounded
            : (tint == GlassTint.pill
                  ? SoftGlassShape.capsule
                  : SoftGlassShape.rounded);
        // 面板类自带真磨砂；chip/bar 保持微透瓷面（继承父级，不重复采样）。
        final selfBlur = glass &&
            (pill ||
                tint == GlassTint.sheet ||
                tint == GlassTint.dialog ||
                tint == GlassTint.card);
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

        return SoftGlassSurface(
          shape: shape,
          radius: radius,
          borderRadius: borderRadius,
          tint: fill,
          edgeColor: bordered ? edge : Colors.transparent,
          selfBlur: selfBlur,
          elevated: elevated,
          padding: EdgeInsets.zero,
          constraints: constraints,
          child: content,
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

/// AppBar flexibleSpace 的贴顶**雾面**（现役唯一顶栏蒙版）。
///
/// 形态 = `LegacyTopFog`：**渐变模糊**（haze）+ 官方系统三层混色 + 状态栏
/// 压暗 + 底缘羽化 + 上浓下淡（可调维度在 `fog_tuning.v1`）。
///
/// 2026-10-29 用户定调「以前的雾色和渐变没有删除吗」：**渐变蒙版整档删除**
/// （`top_gradient.dart` / `top_bar_style.dart` 已移除）。原因：主色渐变 + 光斑
/// 与雾面的灰层/白层互相抵消 → 顶栏读作一条灰粉色带，既不是雾也没有通透感。
///
/// 2026-10-29（v2236）「把旧的删除、照搬官方不要改」：删掉遗留的白平涂 /
/// 灰厚度层 / 灰平涂底 / 饱和矩阵 / 动态取色染色（含 [tint] 参数与
/// `FogTintSampler` 采样链）——官方雾面带没有这些，叠加只会互相抵消。
///
/// 类名保留 `TopFog` 是为了让 20+ 处调用点与既有测试断言零改动。
///
/// 关键性质：雾面**属于玻璃体系**（受「玻璃效果」总控，关闭时整条收起）。
class TopFog extends StatelessWidget {
  const TopFog({super.key});

  @override
  Widget build(BuildContext context) => const LegacyTopFog();
}


