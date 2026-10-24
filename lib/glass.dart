import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'fog_tuning.dart';
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

  /// —— 双态玻璃胶囊（base(2).apk demo 真值）——
  /// 未选=白玻璃 48%+深字，选中=深色玻璃 65%+白字；暗色反转
  /// （未选黑玻璃 40%+亮字，选中白玻璃 72%+深字）。
  /// 全 App 胶囊与按钮的统一材质源：[GlassChip]、[GlassSurface] 的
  /// [GlassTint.pill] 档、app_theme chipTheme 与按钮主题全走本组。
  static const Color pillLight = Color(0x7AFFFFFF);
  static const Color pillSelectedLight = Color(0xA6000000);
  static const Color pillDark = Color(0x66000000);
  static const Color pillSelectedDark = Color(0xB8FFFFFF);

  static Color pill(bool dark) => dark ? pillDark : pillLight;

  static Color pillSelected(bool dark) =>
      dark ? pillSelectedDark : pillSelectedLight;

  /// 双态描边：demo 白描边 0.25 起步，选中态略亮作轮廓强调。
  static Color pillEdge(bool dark, {required bool selected}) =>
      Colors.white.withValues(
        alpha: dark
            ? (selected ? 0.40 : 0.10)
            : (selected ? 0.30 : 0.25),
      );

  /// 接近度亮起描边（demo chips 真值：白描边 0.25+0.55h；h=滚动
  /// 距离/50 clamp 0..1，内容一推出、滚回顶部即熄灭）。暗色 demo
  /// 无真值，按既有 0.10/0.40 起步、以 0.45 同幅收敛。
  /// h=0 时与 [pillEdge] 完全一致，视觉基线不变。
  static Color pillEdgeLit(
    bool dark, {
    required bool selected,
    required double h,
  }) {
    final base = dark ? (selected ? 0.40 : 0.10) : (selected ? 0.30 : 0.25);
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
    final chip = AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      // demo chips：水平 18、垂直 9 → 高约 40；dense 档收窄到 12/5。
      padding: dense
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 5)
          : const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
      decoration: BoxDecoration(
        color: glass
            ? (selected
                  ? GlassChipTokens.pillSelected(dark)
                  : GlassChipTokens.pill(dark))
            : fallback.tint,
        borderRadius: shape,
        border: Border.all(
          color: glass
              ? GlassChipTokens.pillEdgeLit(
                  dark,
                  selected: selected,
                  h: proxH,
                )
              : fallback.edge,
        ),
      ),
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
    if (!glass) return chip;
    // 真磨砂：每颗胶囊自带 σ18 模糊（demo chips 真值）。铁律：
    // BackdropFilter 的范围=当前裁剪区域，必须被外层 ClipRRect 圈住。
    return ClipRRect(
      borderRadius: shape,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: chip,
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
              if (proxListenable != null) proxListenable!,
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
  });

  final Widget child;
  final ValueListenable<double> prox;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final shape = BorderRadius.circular(radius);
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPreferences.enabled,
      builder: (context, glass, _) {
        final fallback = GlassSurface.palette(
          GlassVariant.surface,
          theme.brightness,
          enabled: false,
        );
        final inner = ListenableBuilder(
          listenable: prox,
          builder: (context, _) => DecoratedBox(
            decoration: BoxDecoration(
              color: glass ? GlassChipTokens.pill(dark) : fallback.tint,
              borderRadius: shape,
              border: Border.all(
                color: glass
                    ? GlassChipTokens.pillEdgeLit(
                        dark,
                        selected: false,
                        h: prox.value,
                      )
                    : fallback.edge,
              ),
            ),
            child: child,
          ),
        );
        if (!glass) return inner;
        // 铁律：BackdropFilter 的范围=当前裁剪区域，必须被外层
        // ClipRRect 圈住（child 侧裁剪裁不住滤镜）。
        return ClipRRect(
          borderRadius: shape,
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
            child: inner,
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
        // 瓷面（对齐小米主题商店胶囊/底栏）：去掉 BackdropFilter，
        // 改为半透实底——雾面场景背后已被 TopFog 恒定雾面糊过，透出的
        // 是柔雾而非锐利内容；非雾面场景则是小米式微透瓷面。
        // 底色档位由 [tint] 枚举决定；pill 档直接取双态胶囊配方
        // （不经瓷面 alpha 调制），关闭玻璃时保持 palette 的
        // 不透明降级配色，浮层不会被压回半透明。
        final pill = tint == GlassTint.pill;
        final Color fill;
        if (pill) {
          fill = glass ? GlassChipTokens.pill(dark) : colors.tint;
        } else {
          final alpha = switch (tint) {
            // pill 档在上方 if 分支已短路，此处仅为穷举。
            GlassTint.pill => 0.0,
            GlassTint.chip => dark
                ? GlassChipTokens.tintAlphaDark
                : GlassChipTokens.tintAlphaLight,
            GlassTint.bar => dark ? 0.30 : GlassChipTokens.tintAlphaLight,
            GlassTint.sheet => dark ? 0.66 : 0.80,
            GlassTint.dialog => dark ? 0.45 : 0.55,
            GlassTint.card => dark ? 0.72 : 0.82,
          };
          fill = !glass ? colors.tint : colors.tint.withValues(alpha: alpha);
        }
        final edge = pill && glass
            ? GlassChipTokens.pillEdge(dark, selected: false)
            : colors.edge;
        final shape = borderRadius ?? BorderRadius.circular(radius);
        final decoration = BoxDecoration(
          color: fill,
          border: bordered
              ? Border.all(color: edge, width: GlassTokens.borderWidth)
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

        final surface = DecoratedBox(
          decoration: decoration,
          child: content,
        );
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
            // pill 档开启玻璃时带 σ18 真磨砂（与 GlassChip 同配方）。
            // 铁律：BackdropFilter 的范围=当前裁剪区域，必须在 ClipRRect 内。
            child: pill && glass
                ? BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                    child: surface,
                  )
                : surface,
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
/// 呈现雾面；受「玻璃效果」开关总控，关闭后完全穿透。
///
/// 形态（base(2).apk 雾面 demo 真值，MIUI 主题商店同款「恒定雾化、
/// 色跟内容走」）：整条 ClipRect 内单层 BackdropFilter——blur σ46 与
/// 饱和度 1.45 的色彩矩阵经 ImageFilter.compose 同帧生效（先模糊后提
/// 饱和，透出的内容色更「湿」），随后三层混色平涂（薄奶白提亮、白
/// softLight 提密保色、灰 softLight 给玻璃深度），底缘 24px ShaderMask
/// 羽化收尾。暗色主题整体按 0.78 比例收敛浓度。
class TopFog extends StatelessWidget {
  const TopFog({this.tint, super.key});

  /// 动态取色采样色（null=纯白现状）。由 FogTintSampler 节流采样
  /// 内容区像素平均色输出，经调参台 tintMix 与白混合作提亮层基色。
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: GlassPreferences.enabled,
      builder: (context, glass, _) {
        if (!glass) return const SizedBox.shrink();
        final dark = Theme.of(context).brightness == Brightness.dark;
        // BackdropFilter 的模糊范围是「当前裁剪区域」：外层 ClipRect
        // 圈住整条雾面，否则整屏糊（铁律，FogFab 曾踩过）。
        //
        // ⚠️ blur 必须直挂 ClipRect，中间不能隔 saveLayer 类 widget
        //（ShaderMask/Opacity/ColorFiltered——曾用 ShaderMask 做底缘
        // 羽化，结果 blur 被关进空 offscreen buffer、采样不到底下内
        // 容，雾面只剩 tint 白蒙，真机实锤海报文字清晰如常=雾感丢失）。
        // 羽化改由 _TopFogTintPainter 在 tint 层内部实现。
        //
        // 全部参数来自雾面调参台（FogTuningStore，设置页入口），滑块
        // 拖动实时生效；默认值=发布真值。
        return ValueListenableBuilder<FogTuningState>(
          valueListenable: FogTuningStore.state,
          builder: (context, tuning, _) {
            return ClipRect(
              child: BackdropFilter(
                filter: ImageFilter.compose(
                  outer: ColorFilter.matrix(tuning.colorMatrix()),
                  inner: ImageFilter.blur(
                    sigmaX: tuning.blurSigma,
                    sigmaY: tuning.blurSigma,
                  ),
                ),
                // 单 CustomPaint 直吃紧约束（不要包 Stack——无子级
                // 时 CustomPaint 会缩到 0×0，tint 层直接消失）。
                child: CustomPaint(
                  painter:
                      _TopFogTintPainter(dark: dark, tuning: tuning, tint: tint),
                ),
              ),
            );
          },
        );
      },
    );
  }
}

/// 雾面三层混色 tint（demo _BandTintPainter 真值；全部参数来自雾面
/// 调参台，默认=发布真值；暗色按 0.78 比例收敛）。
class _TopFogTintPainter extends CustomPainter {
  _TopFogTintPainter({
    required this.dark,
    required this.tuning,
    required this.tint,
  });

  final bool dark;
  final FogTuningState tuning;

  /// 动态取色采样色（null=纯白）；与白按 tintMix 混合作第 1 层基色。
  final Color? tint;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    final a = dark ? FogTuningState.darkScale : 1.0;
    // 底缘羽化在 tint 层内部做（shader 渐隐）；blur 层不羽化——
    // σ46 的边缘 clamp 采样本就向原图过渡，配合 tint 渐隐无硬切感。
    final feather = tuning.feather.clamp(0.0, size.height);
    final fadeStart = ((size.height - feather) / size.height).clamp(0.0, 1.0);
    // 垂直雾形：0=均匀玻璃板；1=雾形全开（上浓下淡，用户定调）。
    // 顶部增幅由 topBoost 独立调节（低浓度底子下 +50% 顶部无感，
    // 用户实测；默认 1.5 = 雾形顶格时顶部 2.5×），底缘前只留 25%。
    final vg = tuning.verticalGrad.clamp(0.0, 1.0);
    final topMul = 1.0 + tuning.topBoost * vg;
    final bottomMul = 1.0 - 0.75 * vg;
    Paint layer(Color base, double alphaMul, [BlendMode? mode]) {
      final color = base.withValues(alpha: alphaMul * a);
      final p = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          stops: [0.0, fadeStart, 1.0],
          colors: [
            color.withValues(alpha: color.a * topMul),
            color.withValues(alpha: color.a * bottomMul),
            base.withValues(alpha: 0),
          ],
        ).createShader(rect);
      if (mode != null) p.blendMode = mode;
      return p;
    }

    // 1) 薄奶白：normal 平涂提亮；动态取色时基色向采样色靠拢
    //（tintMix 控制，0=纯白）。2) 白 softLight 的基色同样随 tint 靠
    //拢（模式与 α 不变）——用户把 whiteSoftLight 拉满时纯白层会把
    // 第 1 层仅剩的色相稀释殆尽（真机实测 tintMix 顶格无感的主因
    // 之一），两层同染后色相立得住。
    final baseWhite = tint == null
        ? Colors.white
        : Color.lerp(Colors.white, tint, tuning.tintMix.clamp(0.0, 1.0))!;
    canvas.drawRect(rect, layer(baseWhite, tuning.whiteNormal));
    // 2) 白 softLight：提密同时保住透出内容的色相。
    canvas.drawRect(
      rect,
      layer(baseWhite, tuning.whiteSoftLight, BlendMode.softLight),
    );
    // 3) 灰 softLight：玻璃「厚度」层。
    canvas.drawRect(
      rect,
      layer(const Color(0xFF6B6B6B), tuning.graySoftLight, BlendMode.softLight),
    );
  }

  @override
  bool shouldRepaint(_TopFogTintPainter oldDelegate) =>
      oldDelegate.dark != dark ||
      oldDelegate.tint != tint ||
      !oldDelegate.tuning.equals(tuning);
}
