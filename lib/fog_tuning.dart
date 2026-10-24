import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 雾面（TopFog）全部可调参数。
///
/// 设计动机：雾面浓度/形态已经历多轮「改码→构建→装机→截图→用户反馈」
/// 循环（0.17→0.34→0.92→0.55…），每轮都要猜数字。调参台把所有真值
/// 暴露成滑块实时生效，用户自行定调后一键复制参数固化。
///
/// 字段口径：
/// - 三层 tint 直接暴露**最终 alpha**（不含旧的 master 系数——那只是
///   三层共同缩放，滑块空间里没有存在意义）。默认值 = v2157 固化
///   自用户调参台回发（0.34/1.0/0.16）。
/// - 暗色主题按 [darkScale] 比例跟随（历史惯例 暗=亮×0.78），不单独
///   暴露暗色滑块。
/// - [verticalGrad] 是「雾形」维度：0 = 均匀（玻璃板感），
///   1 = 雾形全开——雾的「上浓下淡」气感，是「一块玻璃」与「一层
///   雾」的形态级差异（用户定调方向）。
/// - [topBoost] 是顶部增幅强度：雾形只提供梯度方向，顶部增浓多少
///   倍单独可调（topMul = 1 + topBoost × verticalGrad）。硬编码
///   +50% 在低基础浓度底子上顶部无感（用户实测「上面不浓」），
///   抽成滑块（v2157 用户定调顶格 3.0，雾形顶格时顶部 4×）。
class FogTuningState {
  /// 默认值 = v2157 用户调参台回发的 10 参数（调参台「复制参数」
  /// 回发固化流程的落点），新装机/恢复默认即此配方。
  const FogTuningState({
    this.blurSigma = 3.0,
    this.saturation = 1.6,
    this.whiteNormal = 0.34,
    this.whiteSoftLight = 1.0,
    this.graySoftLight = 0.16,
    this.feather = 120,
    this.verticalGrad = 1.0,
    this.topBoost = 3.0,
    this.tintMix = 0.10,
    this.fogHeight = -14,
  });

  /// 模糊半径（σ）。用户定调量程 0–3（demo 原始真值 46 在实机过糊，
  /// 有效观感区间就是小 σ；0=不糊只剩 tint 白蒙，3=量程顶格最雾）。
  final double blurSigma;

  /// 饱和度矩阵强度：1=当前矩阵（色更「湿」），0=无矩阵，>1 超调。
  final double saturation;

  /// 薄奶白 normal 平涂提亮层。
  final double whiteNormal;

  /// 白 softLight 提密保色层。
  final double whiteSoftLight;

  /// 灰 softLight 玻璃「厚度」层。
  final double graySoftLight;

  /// 底缘羽化高度（px）。0=硬切边。
  final double feather;

  /// 垂直浓度渐变强度（0 均匀 → 1 上浓下淡全开）。
  final double verticalGrad;

  /// 顶部增幅：topMul = 1 + topBoost × verticalGrad。0=雾形只衰减
  /// 底部；默认 3.0 = 雾形顶格时顶部 4 倍（用户定调顶格）。
  final double topBoost;

  /// 动态取色浓度：0–1。雾面提亮层基色从纯白向「内容实时采样平均
  /// 色」靠拢的比例（采样由 FogTintSampler 提供，null 时回落纯白）。
  /// 0 = 现状纯白雾；默认 0.10（轻取色，色相隐约跟随内容）。
  final double tintMix;

  /// 雾面高度调节量（px）：双向——正档在「状态栏+顶栏」（首页吸顶
  /// 头为整条吸顶头）基础上把雾面带向下多盖一段（糊化、染色、雾形、
  /// 羽化整体跟随加高）；负档把雾面收窄（底缘上移，经 [bandHeight]
  /// 最多收到 0）；0 = 现状高度。v2154 新增，v2156 扩双向（用户定调
  /// 「高度要往上调不是往下」= 负档收窄雾面）。
  final double fogHeight;

  /// 暗色主题整体浓度比例（历史惯例 0.78）。
  static const double darkScale = 0.78;

  /// 当前发布默认（v2157：用户调参台回发 10 参数固化）。
  static const FogTuningState fallback = FogTuningState();

  /// blur σ 合理上限（用户定调 0–3；超过没有观感意义且更吃性能）。
  static const double maxBlurSigma = 3.0;

  /// 顶部增幅上限（雾形顶格时顶部最多 4 倍）。
  static const double maxTopBoost = 3.0;

  /// 底缘羽化量程上限（用户 80 顶格不够，扩到 120）。
  static const double maxFeather = 120;

  /// 动态取色浓度上限（1=完全采用采样色相，经 sampler 端亮度整形）。
  static const double maxTintMix = 1.0;

  /// 雾面高度正档上限（px）。吸顶头约 176px，再延伸 240 到半屏。
  static const double maxFogHeight = 240;

  /// 雾面高度负档下限（px）：正好把 110px 基准雾带收到 0（用户定调
  /// 「高度要往上调」= 负档收窄雾面）。
  static const double minFogHeight = -110;

  /// demo 真值矩阵（σ46 伴生的饱和+轻色偏矩阵）。
  static const List<double> _demoMatrix = <double>[
    1.35415, -0.32175, -0.0324, 0, 0, //
    -0.09585, 1.12825, -0.0324, 0, 0, //
    -0.09585, -0.32175, 1.4176, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  /// 恒等矩阵（saturation=0 时的插值端点）。
  static const List<double> _identityMatrix = <double>[
    1, 0, 0, 0, 0, //
    0, 1, 0, 0, 0, //
    0, 0, 1, 0, 0, //
    0, 0, 0, 1, 0,
  ];

  /// 按强度插值生成色彩矩阵。
  List<double> colorMatrix() {
    final t = saturation.clamp(0.0, 2.0);
    return <double>[
      for (var i = 0; i < _demoMatrix.length; i++)
        _identityMatrix[i] + (_demoMatrix[i] - _identityMatrix[i]) * t,
    ];
  }

  FogTuningState copyWith({
    double? blurSigma,
    double? saturation,
    double? whiteNormal,
    double? whiteSoftLight,
    double? graySoftLight,
    double? feather,
    double? verticalGrad,
    double? topBoost,
    double? tintMix,
    double? fogHeight,
  }) => FogTuningState(
        blurSigma: blurSigma ?? this.blurSigma,
        saturation: saturation ?? this.saturation,
        whiteNormal: whiteNormal ?? this.whiteNormal,
        whiteSoftLight: whiteSoftLight ?? this.whiteSoftLight,
        graySoftLight: graySoftLight ?? this.graySoftLight,
        feather: feather ?? this.feather,
        verticalGrad: verticalGrad ?? this.verticalGrad,
        topBoost: topBoost ?? this.topBoost,
        tintMix: tintMix ?? this.tintMix,
        fogHeight: fogHeight ?? this.fogHeight,
      );

  Map<String, Object> toJson() => <String, Object>{
        'blurSigma': blurSigma,
        'saturation': saturation,
        'whiteNormal': whiteNormal,
        'whiteSoftLight': whiteSoftLight,
        'graySoftLight': graySoftLight,
        'feather': feather,
        'verticalGrad': verticalGrad,
        'topBoost': topBoost,
        'tintMix': tintMix,
        'fogHeight': fogHeight,
      };

  /// 防御性解析：缺失/非法字段逐个回落默认，单字段坏值不拖垮整组。
  factory FogTuningState.fromJson(Map<String, Object?> json) {
    double read(String key, double fallback, double min, double max) {
      final v = json[key];
      if (v is num) return v.toDouble().clamp(min, max);
      return fallback;
    }

    // 缺字段回落值与发布默认同源（引用 fallback 常量，改默认只改
    // 构造一处，fromJson 不再单独维护字面量）。
    const d = FogTuningState.fallback;
    return FogTuningState(
      blurSigma: read('blurSigma', d.blurSigma, 0, maxBlurSigma),
      saturation: read('saturation', d.saturation, 0, 2),
      whiteNormal: read('whiteNormal', d.whiteNormal, 0, 0.6),
      whiteSoftLight: read('whiteSoftLight', d.whiteSoftLight, 0, 1),
      graySoftLight: read('graySoftLight', d.graySoftLight, 0, 0.6),
      feather: read('feather', d.feather, 0, maxFeather),
      verticalGrad: read('verticalGrad', d.verticalGrad, 0, 1),
      topBoost: read('topBoost', d.topBoost, 0, maxTopBoost),
      tintMix: read('tintMix', d.tintMix, 0, maxTintMix),
      fogHeight: read('fogHeight', d.fogHeight, minFogHeight, maxFogHeight),
    );
  }

  factory FogTuningState.fromJsonString(String raw) =>
      FogTuningState.fromJson(jsonDecode(raw) as Map<String, Object?>);

  String toJsonString() => jsonEncode(toJson());

  /// 套用到基准高度上：正档向下延伸、负档收窄，下限 0（防负高度
  /// 断言崩）。
  double bandHeight(double base) {
    final h = base + fogHeight;
    return h < 0 ? 0 : h;
  }

  /// 全字段值相等（fromJson 每次新实例，实例判等必错）。
  bool equals(FogTuningState other) =>
      blurSigma == other.blurSigma &&
      saturation == other.saturation &&
      whiteNormal == other.whiteNormal &&
      whiteSoftLight == other.whiteSoftLight &&
      graySoftLight == other.graySoftLight &&
      feather == other.feather &&
      verticalGrad == other.verticalGrad &&
      topBoost == other.topBoost &&
      tintMix == other.tintMix &&
      fogHeight == other.fogHeight;
}

/// 雾面参数的运行时通道：调参台写入、全部 TopFog 监听，实时生效；
/// 重启从 SharedPreferences 恢复。
abstract final class FogTuningStore {
  static const String _key = 'fog_tuning.v1';

  static final ValueNotifier<FogTuningState> state =
      ValueNotifier<FogTuningState>(FogTuningState.fallback);

  static bool _loaded = false;

  /// 启动时从持久化恢复（main.dart 与 GlassPreferences.load 同点调用）。
  static Future<void> load(SharedPreferences prefs) async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = prefs.getString(_key);
      if (raw == null) return;
      state.value = FogTuningState.fromJsonString(raw);
    } catch (_) {}
  }

  /// 写盘并通知全部雾面刷新；写失败仅静默（下次启动不记忆）。
  static Future<void> save(FogTuningState value) async {
    state.value = value;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key, value.toJsonString());
    } catch (_) {}
  }

  /// 恢复发布默认。
  static Future<void> reset() => save(FogTuningState.fallback);
}
