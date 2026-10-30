import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 雾面（TopFog）全部可调参数。
///
/// **2026-10-29（v2236）按用户定调「把旧的删除、照搬官方不要改」收口**：
/// 只保留 MIUI 雾面带真值直译档**真正在用**的维度，删掉历轮自加的遗留层
/// （白平涂 / 白 softLight / 灰 softLight / 灰平涂底 / 饱和矩阵 / 动态取色染色）。
///
/// 保留的 4 个维度与它们对应的官方行为：
/// - [blurSigma] 20 = 官方 `ImageFilter.blur(σ20)`（渐变模糊由 `haze` 提供，
///   σ 从顶边满值连续衰减到 0）；
/// - [feather] 底缘羽化 160px = **我们加的改良**（官方是硬边 → 用户反复
///   投诉"明显的分界线"）；
/// - [verticalGrad] 上浓下淡雾形 = **我们加的改良**（用户 2150 定调），
///   实现方式 = **只让底部衰减**（顶部恒为官方基准浓度）：顶部一旦乘算放大，
///   官方层3 `#99060606` 的 alpha 0.6 会被顶到 >1 → clamp 成不透明近黑
///   → 顶部盖出一层"黑蒙版"；
/// - [fogHeight] 雾面带高度（正档向下延伸 / 负档收窄）。
///
/// 删掉的遗留层（各自都是"官方没有、我们自加"的历史方案）：
/// - `whiteNormal` / `whiteSoftLight` / `graySoftLight`：奶白平涂与灰厚度层
///   （官方雾面带没有白平涂，加了就读作白板）；
/// - `fogBase`：65% 纯灰平涂底（那是我们 demo 自己 2026-10-20 加的，
///   官方是"底色隐身"）；
/// - `saturation`：demo 色彩矩阵（官方雾面带无矩阵；矩阵只作用在模糊后的
///   内容上，无法叠进 tint 层）；
/// - `tintMix` + 动态取色采样链（`FogTintSampler`）：只服务上面的白平涂层，
///   白平涂删除后无消费者 → 整条链一并删除；
/// - `topBoost`（顶部额外增浓倍数）：乘算会把层 alpha 顶爆 → 见 [verticalGrad]。
class FogTuningState {
  /// 发布默认值 = MIUI 雾面带真值直译档 + 自加改良（羽化 / 上浓下淡）。
  const FogTuningState({
    this.blurSigma = 20.0,
    this.feather = 48,
    this.verticalGrad = 1.0,
    this.fogHeight = 0,
  });

  /// 模糊半径（σ）。官方雾面带真值 20（`ImageFilter.blur(sigmaX: 20)`），
  /// 上限同为 20。
  ///
  /// ⚠️ 实际生效值由 `haze` 的 `fitSigma` 决定：上限 = 雾带高度 × 7.87%
  /// （雾带 ~80 逻辑像素 → σ 上限 ≈ 6.3）。传 20 是"要满值"，真实强度看
  /// 雾带总高。
  final double blurSigma;

  /// 底缘羽化高度（px）。0=硬切边。
  ///
  /// v2239：160 → **48**。羽化比雾带还长时会把浓度提前吃掉 → 分组栏那段
  /// 就没有雾、看着"雾没盖到分组栏底部"。48 = 浓度一直盖到分组栏底边、
  /// 底缘再干脆收尾。
  final double feather;

  /// 垂直浓度渐变强度（0 均匀 → 1 上浓下淡全开）。
  ///
  /// 实现：顶部 = 官方基准浓度（恒定），底部 = 基准 × (1 − 0.75 × 本值)。
  final double verticalGrad;

  /// 雾面高度调节量（px）：双向——正档在「状态栏+顶栏」基础上把雾面带向下
  /// 多盖一段；负档把雾面收窄（经 [bandHeight] 最多收到 0）。
  ///
  /// v2239 默认 **0** = 雾面带底边**正好贴住分组栏底边**（不再向下多盖
  /// 56px，避免分组栏底与内容区之间挂一条雾）。
  final double fogHeight;

  /// 当前发布默认（官方直译档）。
  static const FogTuningState fallback = FogTuningState();

  /// blur σ 上限（MIUI 雾面带真值 20）。
  static const double maxBlurSigma = 20.0;

  /// 底缘羽化量程上限（px）。
  static const double maxFeather = 160;

  /// 雾面高度正档上限（px）。吸顶头约 176px，再延伸 240 到半屏。
  static const double maxFogHeight = 240;

  /// 雾面高度负档下限（px）：正好把 110px 基准雾带收到 0。
  static const double minFogHeight = -110;

  FogTuningState copyWith({
    double? blurSigma,
    double? feather,
    double? verticalGrad,
    double? fogHeight,
  }) => FogTuningState(
        blurSigma: blurSigma ?? this.blurSigma,
        feather: feather ?? this.feather,
        verticalGrad: verticalGrad ?? this.verticalGrad,
        fogHeight: fogHeight ?? this.fogHeight,
      );

  Map<String, Object> toJson() => <String, Object>{
        'blurSigma': blurSigma,
        'feather': feather,
        'verticalGrad': verticalGrad,
        'fogHeight': fogHeight,
      };

  /// 防御性解析：缺失/非法字段逐个回落默认，单字段坏值不拖垮整组。
  ///
  /// 旧档 JSON 里的遗留键（`whiteNormal` / `whiteSoftLight` /
  /// `graySoftLight` / `fogBase` / `saturation` / `tintMix`）**直接被忽略**
  /// → 读出来就是官方直译档，不需要额外的迁移分支。
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
      feather: read('feather', d.feather, 0, maxFeather),
      verticalGrad: read('verticalGrad', d.verticalGrad, 0, 1),
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
      feather == other.feather &&
      verticalGrad == other.verticalGrad &&
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
      final saved = FogTuningState.fromJsonString(raw);
      final next = _migrate(saved);
      state.value = next;
      if (!next.equals(saved)) {
        try {
          await prefs.setString(_key, next.toJsonString());
        } catch (_) {}
      }
    } catch (_) {}
  }

  /// 旧档收敛：把「旧发布默认档的羽化 / 雾高 / σ」收回到当前发布默认
  /// （v2240：羽化 160→48、雾高 +56→0、σ 非 20→20）。
  ///
  /// 只匹配**旧发布默认值**（feather==160 / fogHeight==56），用户用调参台
  /// 主动调出来的其它值不动——避免误伤。遗留层与 topBoost 键已在上游删除参数
  /// 时由 fromJson 忽略，无需迁移分支。
  ///
  /// 羽化与上浓下淡是我们加的改良（非官方），但**默认值形态会随观感迭代**：
  /// v2240 把羽化从 160 收到 48（浓度盖到分组栏底、贴底收尾干脆）、雾高从
  /// +56 收到 0（雾带底边正好贴分组栏底边，不再向下多挂一条）。
  static FogTuningState _migrate(FogTuningState v) {
    final d = FogTuningState.fallback;
    final sigmaDrift = v.blurSigma != d.blurSigma;
    final featherOldDefault = v.feather == 160;
    final heightOldDefault = v.fogHeight == 56;
    if (!sigmaDrift && !featherOldDefault && !heightOldDefault) {
      return v;
    }
    return v.copyWith(
      blurSigma: sigmaDrift ? d.blurSigma : v.blurSigma,
      feather: featherOldDefault ? d.feather : v.feather,
      fogHeight: heightOldDefault ? d.fogHeight : v.fogHeight,
    );
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

  /// 供测试重置「已恢复」标记（同一测试文件里需要多次从盘上恢复时用）。
  @visibleForTesting
  static void resetLoadedFlag() => _loaded = false;
}
