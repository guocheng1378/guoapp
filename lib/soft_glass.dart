import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folme.dart';
import 'glass_preferences.dart';
import 'motion.dart';
import 'motion_performance.dart';
import 'route_transition.dart';

/// 柔光玻璃（HyperOS 4「生命感美学 · 柔光玻璃」）材质唯一真源。
///
/// 全 app 的胶囊、面板、卡片、列表行、底栏、菜单、播放器控件都从这里取
/// 配方——不再各写各的 tint/圆角/描边。此前 `glass.dart` 里有 4 套并行
/// 配方（`GlassChipTokens.pill*`、`GlassSurface._glassTint`、`GlassTint`
/// 六档枚举、各处手写 tint），观感漂移且无法统一调参，现已收敛到本文件。
///
/// 三个关键词（对应澎湃 OS 4 官方口径）：
/// - **清透**：tint 极低（浅 0.14 / 深 0.22），背后内容仍可辨；
/// - **磨砂**：真 `BackdropFilter`（σ 14 甜区，>16 背后文字糊成色块）；
/// - **玻璃感**：上内阴影 + 下内高光 + 渐变描边三特征（缺一项就退回乳白雾）。
///
/// 铁律（同 glass.dart）：`BackdropFilter` 必须**直挂裁剪祖先**，中间不能隔
/// `ShaderMask`/`Opacity`/`ColorFiltered` 等 saveLayer 类 widget，否则 blur
/// 被关进空 offscreen buffer、采样不到底下内容、模糊静默失效。故柔光特征层
/// 一律画在 `BackdropFilter` 的**兄弟位置**。

/// 柔光玻璃的形状档位。
enum SoftGlassShape {
  /// 胶囊（真胶囊：圆角半径 = 短边一半，MIUI 液态玻璃默认形态）。
  capsule,

  /// 圆角矩形。
  rounded,

  /// 正圆。
  circle,
}

/// 柔光玻璃的全部可调参数（浅/深两套配方独立）。
///
/// 语义说明：
/// - [tintLight] / [tintDark]：底色浓度，**清透度主控**（值越低越透）；
/// - [blurSigma]：磨砂强度（0 = 纯透明不磨砂，14 为甜区）；
/// - [innerShadow] / [innerHighlight]：上内阴影 / 下内高光（玻璃厚度感）；
/// - [edge]：渐变描边强度（深色按 0.5× 跟随）；
/// - [saturation]：主色染色比例，以「掺主色」近似官方 vibrancy
///   （backdrop 侧彩度受 Flutter 机制限制：`ColorFiltered` 是 saveLayer 类
///   widget，会隔断 `BackdropFilter`；`ImageFilter.matrix` 在 Impeller 上
///   支持度不确定，故一律在 tint 侧做）。
class SoftGlassSpec {
  const SoftGlassSpec({
    this.tintLight = 0.14,
    this.tintDark = 0.22,
    this.blurSigma = 14,
    this.innerShadow = 0.12,
    this.innerHighlight = 0.08,
    this.edge = 0.14,
    this.saturation = 0.05,
  });

  /// 浅色主题底色浓度（0.04~0.40）。默认 0.14：清透但仍读作玻璃。
  final double tintLight;

  /// 深色主题底色浓度（0.08~0.50）。默认 0.22：深色下要多一点才不透明。
  final double tintDark;

  /// 磨砂半径 σ（0~24）。默认 14：磨砂成立且背后文字仍可辨。
  final double blurSigma;

  /// 上内阴影强度（0~0.30）。默认 0.12。
  final double innerShadow;

  /// 下内高光强度（0~0.24）。默认 0.08。
  final double innerHighlight;

  /// 渐变描边强度（0~0.60）。默认 0.28。
  final double edge;

  /// 主色染色比例（0~0.16）。默认 0.05。
  final double saturation;

  /// 发布默认（清透磨砂 · 平衡档）。
  static const SoftGlassSpec fallback = SoftGlassSpec();

  static const double maxTintLight = 0.40;
  static const double maxTintDark = 0.50;
  static const double maxBlurSigma = 24;
  static const double maxInnerShadow = 0.30;
  static const double maxInnerHighlight = 0.24;
  static const double maxEdge = 0.60;
  static const double maxSaturation = 0.16;

  SoftGlassSpec copyWith({
    double? tintLight,
    double? tintDark,
    double? blurSigma,
    double? innerShadow,
    double? innerHighlight,
    double? edge,
    double? saturation,
  }) => SoftGlassSpec(
    tintLight: tintLight ?? this.tintLight,
    tintDark: tintDark ?? this.tintDark,
    blurSigma: blurSigma ?? this.blurSigma,
    innerShadow: innerShadow ?? this.innerShadow,
    innerHighlight: innerHighlight ?? this.innerHighlight,
    edge: edge ?? this.edge,
    saturation: saturation ?? this.saturation,
  );

  Map<String, Object> toJson() => <String, Object>{
    'tintLight': tintLight,
    'tintDark': tintDark,
    'blurSigma': blurSigma,
    'innerShadow': innerShadow,
    'innerHighlight': innerHighlight,
    'edge': edge,
    'saturation': saturation,
  };

  /// 防御性解析：缺失/非法字段逐个回落默认，单字段坏值不拖垮整组。
  factory SoftGlassSpec.fromJson(Map<String, Object?> json) {
    double read(String key, double fallback, double min, double max) {
      final v = json[key];
      if (v is num) return v.toDouble().clamp(min, max);
      return fallback;
    }

    const d = SoftGlassSpec.fallback;
    return SoftGlassSpec(
      tintLight: read('tintLight', d.tintLight, 0, maxTintLight),
      tintDark: read('tintDark', d.tintDark, 0, maxTintDark),
      blurSigma: read('blurSigma', d.blurSigma, 0, maxBlurSigma),
      innerShadow: read('innerShadow', d.innerShadow, 0, maxInnerShadow),
      innerHighlight: read(
        'innerHighlight',
        d.innerHighlight,
        0,
        maxInnerHighlight,
      ),
      edge: read('edge', d.edge, 0, maxEdge),
      saturation: read('saturation', d.saturation, 0, maxSaturation),
    );
  }

  String toJsonString() => jsonEncode(toJson());

  factory SoftGlassSpec.fromJsonString(String raw) =>
      SoftGlassSpec.fromJson(jsonDecode(raw) as Map<String, Object?>);

  /// 全字段值相等（fromJson 每次新实例，实例判等必错）。
  bool equals(SoftGlassSpec other) =>
      tintLight == other.tintLight &&
      tintDark == other.tintDark &&
      blurSigma == other.blurSigma &&
      innerShadow == other.innerShadow &&
      innerHighlight == other.innerHighlight &&
      edge == other.edge &&
      saturation == other.saturation;

  @override
  bool operator ==(Object other) =>
      other is SoftGlassSpec && equals(other);

  @override
  int get hashCode => Object.hash(
    tintLight,
    tintDark,
    blurSigma,
    innerShadow,
    innerHighlight,
    edge,
    saturation,
  );
}

/// 柔光玻璃参数的运行时通道：调参台写入、全 app 玻璃面监听，实时生效；
/// 重启从 SharedPreferences 恢复。
abstract final class SoftGlassStore {
  static const String _key = 'soft_glass.v1';

  static final ValueNotifier<SoftGlassSpec> state =
      ValueNotifier<SoftGlassSpec>(SoftGlassSpec.fallback);

  /// 主题重建信号：材质定稿（落盘）时自增——MaterialApp 据此重建主题，
  /// 让 M3 组件槽位（卡片/开关/滑块…）跟着换色。调参拖动过程中只走
  /// [apply]（内存实时），不触发整壳重建。
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// 实时预览：只改内存（不落盘、不触发主题重建）。
  static void apply(SoftGlassSpec value) => state.value = value;

  static bool _loaded = false;

  /// 启动时从持久化恢复（main.dart 与 GlassPreferences.load 同点调用）。
  static Future<void> load(SharedPreferences prefs) async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return;
      final saved = SoftGlassSpec.fromJsonString(raw);
      final next = _migrate(saved);
      state.value = next;
      if (!next.equals(saved)) {
        try {
          await prefs.setString(_key, next.toJsonString());
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 旧档收敛：描边过重时收细（2026-10-29「还有明显的分界线」）。
  ///
  /// 玻璃面的渐变描边在**大面板**上会读成一条明确的矩形边线——与「独立胶囊」
  /// 的形态诉求冲突。旧档 edge 0.28 收到 0.14，胶囊轮廓靠形态本身而不是
  /// 描边来表达。
  static SoftGlassSpec _migrate(SoftGlassSpec v) {
    final d = SoftGlassSpec.fallback;
    if (v.edge <= d.edge) return v;
    return v.copyWith(edge: d.edge);
  }

  /// 供测试重置「已恢复」标记（模拟重启后重新读盘）。
  @visibleForTesting
  static void resetLoadedFlag() => _loaded = false;

  /// 写盘并通知全部玻璃面刷新；写失败仅静默（下次启动不记忆）。
  static Future<void> save(SoftGlassSpec value) async {
    state.value = value;
    revision.value++;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.toJsonString());
    } catch (_) {}
  }

  /// 恢复发布默认。
  static Future<void> reset() => save(SoftGlassSpec.fallback);
}

/// 柔光玻璃的档位与派生色：所有玻璃面共用同一套计算，避免各写各的。
abstract final class SoftGlassTokens {
  /// 自带 backdrop 的大面积容器（底栏整条、菜单面板、顶栏岛、卡片）。
  static const bool selfBlur = true;

  /// 继承父级磨砂的小元素（分类 chip、列表行、菜单行、播放器按钮）：
  /// 不再自带 `BackdropFilter`——底下已经是磨砂过的内容，视觉等价但省一次
  /// 采样；同一视觉层出现两个 backdrop 会造成**双重模糊发灰**（不清透）。
  static const bool inheritBlur = false;

  /// 底色：白/黑掺主色（染色 = vibrancy 近似），浓度按主题取。
  static Color tint(
    SoftGlassSpec spec,
    Brightness brightness, {
    Color? primary,
  }) {
    final dark = brightness == Brightness.dark;
    final base = dark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
    final alpha = dark ? spec.tintDark : spec.tintLight;
    final stained = primary == null
        ? base
        : Color.lerp(base, primary, spec.saturation.clamp(0.0, 1.0))!;
    return stained.withValues(alpha: alpha.clamp(0.0, 1.0));
  }

  /// 描边色：上缘亮、下缘淡（深色按 0.5× 跟随）。
  static Color edge(SoftGlassSpec spec, Brightness brightness) {
    final dark = brightness == Brightness.dark;
    return Colors.white.withValues(
      alpha: (dark ? spec.edge * 0.5 : spec.edge).clamp(0.0, 1.0),
    );
  }

  /// 形状对应的圆角半径。
  static Radius radius(SoftGlassShape shape, double radius, Size size) {
    switch (shape) {
      case SoftGlassShape.capsule:
        return Radius.circular(math.min(size.width, size.height) / 2);
      case SoftGlassShape.rounded:
        return Radius.circular(radius);
      case SoftGlassShape.circle:
        return Radius.circular(math.min(size.width, size.height) / 2);
    }
  }
}

/// 柔光玻璃表面：底色 + 真磨砂 + 柔光三特征（上内阴影/下内高光/渐变描边）。
///
/// 结构（严格满足 BackdropFilter 铁律）：
/// ```text
/// ClipRRect
/// └─ Stack([
///     BackdropFilter(σ)           ← 直挂裁剪祖先，兄弟位置
///     CustomPaint(柔光三特征)      ← 兄弟，不被 blur
///     Padding(child)              ← 内容在最上
///   ])
/// ```
class SoftGlassSurface extends StatelessWidget {
  const SoftGlassSurface({
    super.key,
    required this.child,
    this.selfBlur = SoftGlassTokens.selfBlur,
    this.sigma,
    this.shape = SoftGlassShape.capsule,
    this.radius = 18,
    this.borderRadius,
    this.tint,
    this.edgeColor,
    this.edgeProx,
    this.edgeFor,
    this.selected = false,
    this.padding = EdgeInsets.zero,
    this.constraints,
    this.decorative = true,
    this.pressHighlight = false,
    this.elevated = false,
  });

  /// 子部件（不自带 backdrop，继承父级磨砂）。
  const SoftGlassSurface.inherit({
    super.key,
    required this.child,
    this.sigma,
    this.shape = SoftGlassShape.capsule,
    this.radius = 18,
    this.borderRadius,
    this.tint,
    this.edgeColor,
    this.edgeProx,
    this.edgeFor,
    this.selected = false,
    this.padding = EdgeInsets.zero,
    this.constraints,
    this.decorative = true,
    this.pressHighlight = false,
    this.elevated = false,
  }) : selfBlur = SoftGlassTokens.inheritBlur;

  final Widget child;

  /// 自带 `BackdropFilter`（true）还是继承父级磨砂（false）。
  final bool selfBlur;

  /// 覆盖本次的磨砂 σ（null = 用 [SoftGlassStore] 的当前值）。
  final double? sigma;

  final SoftGlassShape shape;

  /// 圆角档（仅 [SoftGlassShape.rounded] 生效）。
  final double radius;

  /// 非均匀圆角（优先于 [shape]/[radius]，如底部弹窗只圆上方两角）。
  final BorderRadius? borderRadius;

  /// 覆盖底色（null = 按主题 + spec 计算）。
  final Color? tint;

  /// 覆盖描边色（null = 按主题 + spec 计算）。用于「接近度亮起」这类
  /// 随滚动变化的描边。
  final Color? edgeColor;

  /// 描边「接近度」信号（0..1）：传入时描边亮度由 painter 直接监听该信号
  /// 重绘，**不再重建整个玻璃面**。
  ///
  /// 为什么必须走 painter：[edgeColor] 是一条随滚动连续变化的 1px 描边，
  /// 若由上层 `ListenableBuilder` 驱动，每次取值变化都会重建
  /// `ClipPath + Stack + AnimatedContainer + CustomPaint` 整棵子树。首页
  /// 分类条 20+ 颗胶囊 × 滚动前 50px 的 10 个档位 = 两三百次子树重建，
  /// 每次都要重建裁剪层 → 滚动起手必掉帧（这才是滚动卡顿的主源，
  /// 与模糊无关：把模糊关掉也照样卡）。
  final ValueListenable<double>? edgeProx;

  /// 由 [edgeProx] 的当前值算描边色（null = 直接用 [edgeColor]）。
  final Color Function(double prox)? edgeFor;

  /// 选中态（实底 + 选中前景，保证可读）。
  final bool selected;

  final EdgeInsetsGeometry padding;
  final BoxConstraints? constraints;

  /// 是否画柔光三特征（内阴影/内高光/描边）。
  final bool decorative;

  /// 是否叠加「点按有光」交互高光。
  final bool pressHighlight;

  /// 是否带悬浮投影。
  final bool elevated;

  /// 玻璃面监听的信号源（材质配方 / 玻璃总开关 / 回退动画降级）。
  ///
  /// 静态缓存：`Listenable.merge` 每次新建会让 `ListenableBuilder` 反复
  /// remove/add 监听，且是纯开销——三路都是单例，合并一次即可。
  /// 只挂「低频」信号：材质配方、玻璃总开关、轻量玻璃开关、回退动画。
  ///
  /// 不要挂逐帧或每次进场都翻的信号——`ListenableBuilder` 一响，屏幕上
  /// 每一枚玻璃面都要整棵子树重建（含 BackdropFilter / CustomPaint /
  /// AnimatedContainer），一屏几十枚就是一帧掉到底。进/出场降级曾挂在
  /// `RouteTransitionSignal.transitioning` 上，实测比它省下的高斯采样还贵。
  static final Listenable _listenable = Listenable.merge([
    SoftGlassStore.state,
    GlassPreferences.enabled,
    RouteTransitionSignal.reversing,
    MotionPerformance.lowPower,
  ]);

  /// 模糊核按 σ 复用：ImageFilter 不可变，每次 build 新建只会制造 GC
  /// 压力。调参台拖动、滚动接近度、弹窗动画都会高频走到这里。
  static final Map<double, ImageFilter> _blurFilters = <double, ImageFilter>{};

  static ImageFilter _blurFilter(double sigma) {
    // 量化到 0.1：避免浮点 σ 把缓存撑成无限表，肉眼无差。
    final key = (sigma * 10).roundToDouble() / 10;
    if (_blurFilters.length > 64) _blurFilters.clear();
    return _blurFilters.putIfAbsent(
      key,
      () => ImageFilter.blur(sigmaX: key, sigmaY: key),
    );
  }

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final primary = Theme.of(context).colorScheme.primary;
    // 弹窗（PopupRoute）转场用 Fade+Scale：Opacity 层把每枚胶囊的
    // BackdropFilter 与裁剪祖先隔开、Scale 每帧让缓存失效，N 枚胶囊
    // 等于每帧 N 次背景重采样 + 2N 次大半径内阴影模糊。动画期间把玻璃
    // 临时降级为纯底色 + 描边，动画结束的下一帧自动恢复真磨砂。
    final route = ModalRoute.of(context);
    final popup = route is PopupRoute ? route.animation : null;
    if (popup == null) return _surface(context, brightness, primary, false);
    // 两棵子树预先建好，动画每帧只在二者间切一次引用：同一实例连续帧
    // 会被 Element 的 widget 相等短路，不再逐帧重建整枚玻璃面。
    final settled = _surface(context, brightness, primary, false);
    final animating = _surface(context, brightness, primary, true);
    return AnimatedBuilder(
      animation: popup,
      builder: (context, _) =>
          popup.status != AnimationStatus.completed ? animating : settled,
    );
  }

  Widget _surface(
    BuildContext context,
    Brightness brightness,
    Color primary,
    bool animating,
  ) {
    return ListenableBuilder(
      // 材质配方与玻璃总开关都要实时生效：调参台拖动 / 设置页切换开关
      // → 所有玻璃面立即重建（不重启）。回退动画期间再叠加一路信号，
      // 用于把重玻璃临时降级（见 [RouteTransitionSignal]）。
      listenable: _listenable,
      builder: (context, _) {
        final spec = SoftGlassStore.state.value;
        final glass = GlassPreferences.enabled.value;
        final dark = brightness == Brightness.dark;
        // 动效期（回退/进场/弹窗动画）与「轻量玻璃」开关：**只降采样，
        // 绝不关模糊**。模糊是这套材质的本体——把它抹成 0 等于换了一套 UI，
        // 而实测把模糊关掉页照样卡（真正的大头是每档重建整棵胶囊子树，
        // 见 [edgeProx]），所以这里改为保留模糊、只缩 σ 并跳过两次大半径
        // `MaskFilter.blur`（内阴影/内高光，动画期肉眼无从分辨）。
        final motion = RouteTransitionSignal.reversing.value || animating;
        final cheap = motion || MotionPerformance.lowPower.value;
        final sigmaScale = MotionPerformance.lowPower.value
            ? MotionPerformance.lowPowerSigmaScale
            : (motion ? MotionPerformance.motionSigmaScale : 1.0);
        // 玻璃关闭 → 降级为不透明浮层（低端设备更流畅，且不再采样背景）。
        final fallback = dark
            ? const Color(0xFF1E2026)
            : const Color(0xFFF2EEEB);
        final base =
            tint ??
            (glass
                ? SoftGlassTokens.tint(spec, brightness, primary: primary)
                : fallback);
        final edgeColor =
            this.edgeColor ??
            (glass
                ? SoftGlassTokens.edge(spec, brightness)
                : (dark ? Colors.white24 : Colors.black12));
        // σ=0 是「用户显式要清透到底」的唯一合法零模糊路径（调参台可设）。
        final baseSigma = (sigma ?? spec.blurSigma).clamp(
          0.0,
          SoftGlassSpec.maxBlurSigma,
        );
        final blur = (glass && baseSigma > 0.01)
            ? baseSigma * sigmaScale
            : 0.0;
        final radiusValue = SoftGlassTokens.radius(shape, radius, Size.zero);
        final body = Stack(
          children: [
            if (selfBlur && blur > 0.01)
              Positioned.fill(
                child: BackdropFilter(
                  filter: _blurFilter(blur),
                  child: const SizedBox.expand(),
                ),
              ),
            // tint 底色画在模糊层**之上**：内容先被糊化，再蒙一层清透底色。
            Positioned.fill(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                decoration: BoxDecoration(color: base),
              ),
            ),
            if (decorative)
              Positioned.fill(
                child: CustomPaint(
                  painter: SoftGlassPainter(
                    spec: spec,
                    shape: shape,
                    radius: radiusValue,
                    borderRadius: borderRadius,
                    edgeColor: edgeColor,
                    cheap: cheap,
                    // 玻璃关闭时描边走静态色，不挂接近度监听。
                    edgeProx: glass ? edgeProx : null,
                    edgeFor: glass ? edgeFor : null,
                  ),
                ),
              ),
            Padding(padding: padding, child: child),
          ],
        );
        final clipped = ClipPath(
          clipper: _SoftGlassClipper(
            shape: shape,
            radius: radius,
            borderRadius: borderRadius,
          ),
          child: body,
        );
        final sized = constraints == null
            ? clipped
            : ConstrainedBox(constraints: constraints!, child: clipped);
        if (!elevated) return sized;
        return Container(
          decoration: BoxDecoration(
            borderRadius:
                borderRadius ?? BorderRadius.circular(radiusValue.x),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: dark ? 0.24 : 0.10),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: sized,
        );
      },
    );
  }
}

/// 柔光三特征绘制器：上内阴影 + 下内高光 + 渐变描边。
///
/// 原理与参照源 `InnerShadow`（Compose 版「填原形 → Clear 擦除偏移形 → 模糊
/// → 裁回原形」）等价：Flutter 侧改为「裁到原形内 → 画偏移后的形状轮廓并加
/// `MaskFilter.blur`」，偏移方向决定阴影落在哪一侧：
/// - 形状**下移** r 后描边 → 其上边缘落进原形内侧 → **上内阴影**；
/// - 形状**上移** r 后描边 → 其下边缘落进原形内侧 → **下内高光**。
class SoftGlassPainter extends CustomPainter {
  const SoftGlassPainter({
    required this.spec,
    required this.shape,
    required this.radius,
    required this.borderRadius,
    required this.edgeColor,
    this.cheap = false,
    this.edgeProx,
    this.edgeFor,
  }) : super(repaint: edgeProx);

  final SoftGlassSpec spec;
  final SoftGlassShape shape;
  final Radius radius;
  final BorderRadius? borderRadius;
  final Color edgeColor;

  /// 降级模式：跳过内阴影/内高光（两次大半径 `MaskFilter.blur`），
  /// 只留渐变描边。**不影响磨砂**——模糊永远保留，见 [SoftGlassSurface]。
  final bool cheap;

  /// 描边亮度信号：值变化只触发本 painter 重绘（1px 描边），不重建
  /// 玻璃面子树，也不重采样 backdrop。
  final ValueListenable<double>? edgeProx;
  final Color Function(double prox)? edgeFor;

  /// 形状路径按尺寸缓存：`paint` 每帧都跑，`Path` 反复构造纯粹是分配开销。
  static final Map<Object, Path> _pathCache = <Object, Path>{};

  Path _cachedPath(Size size) {
    final key = Object.hash(size.width, size.height, shape, radius, borderRadius);
    if (_pathCache.length > 64) _pathCache.clear();
    final cached = _pathCache[key];
    if (cached != null) return cached;
    final path = _path(size);
    _pathCache[key] = path;
    return path;
  }

  /// 形状路径：非均匀圆角优先；胶囊按**实际短边**算半径（真胶囊）。
  static Path pathOf(
    Size size,
    SoftGlassShape shape,
    Radius radius,
    BorderRadius? borderRadius,
  ) {
    final rect = Offset.zero & size;
    if (borderRadius != null) {
      final br = borderRadius;
      return Path()
        ..addRRect(
          RRect.fromRectAndCorners(
            rect,
            topLeft: br.topLeft,
            topRight: br.topRight,
            bottomLeft: br.bottomLeft,
            bottomRight: br.bottomRight,
          ),
        );
    }
    switch (shape) {
      case SoftGlassShape.circle:
        return Path()..addOval(rect);
      case SoftGlassShape.capsule:
        return Path()
          ..addRRect(
            RRect.fromRectAndRadius(
              rect,
              Radius.circular(math.min(size.width, size.height) / 2),
            ),
          );
      case SoftGlassShape.rounded:
        return Path()..addRRect(RRect.fromRectAndRadius(rect, radius));
    }
  }

  Path _path(Size size) => pathOf(size, shape, radius, borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final path = _cachedPath(size);
    final r = math.min(size.width, size.height) * 0.45;
    if (r > 0.5 && !cheap) {
      canvas.save();
      canvas.clipPath(path);
      // 上内阴影：形状下移 r，其上边缘落进原形内侧。
      if (spec.innerShadow > 0.001) {
        canvas.drawPath(
          path.shift(Offset(0, r)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..color = Colors.black.withValues(alpha: spec.innerShadow)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r),
        );
      }
      // 下内高光：形状上移 r，其下边缘落进原形内侧。
      if (spec.innerHighlight > 0.001) {
        canvas.drawPath(
          path.shift(Offset(0, -r)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = r * 2
            ..color = Colors.white.withValues(alpha: spec.innerHighlight)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, r),
        );
      }
      canvas.restore();
    }
    // 渐变描边：上缘亮、下缘淡。接近度亮起直接在这里取值——信号变化只
    // 重绘这条 1px 描边，不重建子树、不重采样 backdrop。
    final edge = edgeProx == null
        ? edgeColor
        : (edgeFor?.call(edgeProx!.value) ?? edgeColor);
    if (spec.edge > 0.001) {
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              edge,
              edge.withValues(alpha: edge.a * 0.15),
            ],
          ).createShader(Offset.zero & size),
      );
    }
  }

  @override
  bool shouldRepaint(SoftGlassPainter oldDelegate) =>
      oldDelegate.spec != spec ||
      oldDelegate.shape != shape ||
      oldDelegate.radius != radius ||
      oldDelegate.borderRadius != borderRadius ||
      oldDelegate.edgeColor != edgeColor ||
      oldDelegate.cheap != cheap ||
      // 接近度信号的取值变化由 `repaint` 直接驱动重绘，这里只比较承载者
      // 是否换了一路信号（同值/同实例不重绘）。
      oldDelegate.edgeProx != edgeProx;
}

/// 柔光形状裁剪器：胶囊半径依赖**实际短边**，必须在布局期由 size 决定，
/// 故用 [ClipPath] 而非 [ClipRRect]（后者拿不到尺寸）。
class _SoftGlassClipper extends CustomClipper<Path> {
  const _SoftGlassClipper({
    required this.shape,
    required this.radius,
    required this.borderRadius,
  });

  final SoftGlassShape shape;
  final double radius;
  final BorderRadius? borderRadius;

  @override
  Path getClip(Size size) => SoftGlassPainter.pathOf(
    size,
    shape,
    Radius.circular(radius),
    borderRadius,
  );

  @override
  bool shouldReclip(_SoftGlassClipper oldClipper) =>
      oldClipper.shape != shape ||
      oldClipper.radius != radius ||
      oldClipper.borderRadius != borderRadius;
}

/// 「点按有光，操作有回应」：跟随指针的局部高光 + 全区轻微增亮。
///
/// 对齐参照源 `InteractiveHighlight`：
/// - 全区白色增亮，`BlendMode.plus`，alpha = 0.04 × progress；
/// - 指针位置径向高光，`BlendMode.plus`，stops = [0: 0.04p, 0.5: 0.04p, 1: 0]
///   → 中心到半径 50% 等亮、外侧淡出；
/// - 半径 = 组件最短边 × 1.2（**半径不扩散**，只变透明度）；
/// - 弹簧 dampingRatio 0.5 / stiffness 300（欠阻尼轻过冲，无固定时长）。
///
/// 绘制顺序对齐官方：光斑先画，内容后画（内容在光之上）。
class SoftGlassPressHighlight extends StatefulWidget {
  const SoftGlassPressHighlight({
    super.key,
    required this.child,
    this.globalAlpha = 0.04,
    this.enabled = true,
  });

  final Widget child;

  /// 全区增亮与光斑的峰值 alpha（官方 0.04）。
  final double globalAlpha;

  final bool enabled;

  @override
  State<SoftGlassPressHighlight> createState() =>
      _SoftGlassPressHighlightState();
}

class _SoftGlassPressHighlightState extends State<SoftGlassPressHighlight>
    with SingleTickerProviderStateMixin {
  late final SpringDriver _progress = SpringDriver(
    this,
    value: 0,
    spring: kSoftGlassPressSpring,
  );
  Offset? _pointer;

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  void _set(bool down, Offset? position) {
    if (!widget.enabled) return;
    if (position != null) _pointer = position;
    _progress.to(down ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    if (Motion.inTest || !widget.enabled) return widget.child;
    return Listener(
      onPointerDown: (e) => _set(true, e.localPosition),
      onPointerMove: (e) => _set(true, e.localPosition),
      onPointerUp: (_) => _set(false, null),
      onPointerCancel: (_) => _set(false, null),
      child: AnimatedBuilder(
        animation: _progress.view,
        builder: (context, child) => CustomPaint(
          painter: _PressHighlightPainter(
            progress: _progress.value,
            pointer: _pointer,
            globalAlpha: widget.globalAlpha,
          ),
          child: child,
        ),
        child: widget.child,
      ),
    );
  }
}

class _PressHighlightPainter extends CustomPainter {
  const _PressHighlightPainter({
    required this.progress,
    required this.pointer,
    required this.globalAlpha,
  });

  final double progress;
  final Offset? pointer;
  final double globalAlpha;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0.001 || size.isEmpty) return;
    final p = progress.clamp(0.0, 1.2);
    final a = globalAlpha * p;
    // 全区增亮。
    canvas.drawRect(
      Offset.zero & size,
      Paint()
        ..color = Colors.white.withValues(alpha: a)
        ..blendMode = BlendMode.plus,
    );
    // 指针径向光斑。
    final center = pointer;
    if (center != null) {
      final radius = math.max(size.shortestSide * 1.2, 1.0);
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawRect(
        Offset.zero & size,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [
              Colors.white.withValues(alpha: a),
              Colors.white.withValues(alpha: a),
              Colors.white.withValues(alpha: 0),
            ],
            stops: const [0.0, 0.5, 1.0],
          ).createShader(rect),
      );
    }
  }

  @override
  bool shouldRepaint(_PressHighlightPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.pointer != pointer ||
      oldDelegate.globalAlpha != globalAlpha;
}
