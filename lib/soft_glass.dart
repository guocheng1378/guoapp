import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'folme.dart';
import 'glass_preferences.dart';
import 'motion.dart';
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
  static final Listenable _listenable = Listenable.merge([
    SoftGlassStore.state,
    GlassPreferences.enabled,
    RouteTransitionSignal.reversing,
  ]);

  @override
  Widget build(BuildContext context) {
    final brightness = Theme.of(context).brightness;
    final primary = Theme.of(context).colorScheme.primary;
    return ListenableBuilder(
      // 材质配方与玻璃总开关都要实时生效：调参台拖动 / 设置页切换开关
      // → 所有玻璃面立即重建（不重启）。回退动画期间再叠加一路信号，
      // 用于把重玻璃临时降级（见 [RouteTransitionSignal]）。
      listenable: _listenable,
      builder: (context, _) {
        final spec = SoftGlassStore.state.value;
        final glass = GlassPreferences.enabled.value;
        final dark = brightness == Brightness.dark;
        // 回退动画期：整页每帧重绘，任何模糊都会放大成本 → 临时去掉
        // 磨砂与内阴影（动画结束下一帧自动恢复）。
        final cheap = RouteTransitionSignal.reversing.value;
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
        final blur = (glass && !cheap)
            ? (sigma ?? spec.blurSigma).clamp(0.0, SoftGlassSpec.maxBlurSigma)
            : 0.0;
        final radiusValue = SoftGlassTokens.radius(shape, radius, Size.zero);
        final body = Stack(
          children: [
            if (selfBlur && blur > 0.01)
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
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
  });

  final SoftGlassSpec spec;
  final SoftGlassShape shape;
  final Radius radius;
  final BorderRadius? borderRadius;
  final Color edgeColor;

  /// 降级模式：跳过内阴影/内高光（两次大半径 `MaskFilter.blur`），
  /// 只留渐变描边。回退动画期整页每帧重绘，模糊成本被放大，必须砍掉。
  final bool cheap;

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
    final path = _path(size);
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
    // 渐变描边：上缘亮、下缘淡。
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
              edgeColor,
              edgeColor.withValues(alpha: edgeColor.a * 0.15),
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
      oldDelegate.cheap != cheap;
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
