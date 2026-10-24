import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fog_tint_sampler.dart';
import 'fog_tuning.dart';
import 'glass.dart';

/// 雾面调参台：所有雾面参数滑块实时生效（所见即所得），调到满意后
/// 「复制参数」把 JSON 发回开发者固化为发布默认。
///
/// 预览区是一块可滚动的仿海报浓色内容，顶部叠真实 TopFog——与首页
/// 同一组件同一参数通道（FogTuningStore），滚上来即验证穿雾效果；
/// 真实首页的雾面同步响应，退出本页立即可见。
class FogTuningScreen extends StatefulWidget {
  const FogTuningScreen({super.key});

  @override
  State<FogTuningScreen> createState() => _FogTuningScreenState();
}

class _FogTuningScreenState extends State<FogTuningScreen> {
  FogTuningState _tuning = FogTuningStore.state.value;

  void _apply(FogTuningState next) {
    setState(() => _tuning = next);
    // 拖动中只更新内存（全部雾面实时重建），松手才写盘。
    FogTuningStore.state.value = next;
  }

  void _commit(FogTuningState next) {
    _apply(next);
    unawaitedSave();
  }

  void unawaitedSave() {
    FogTuningStore.save(_tuning);
  }

  Future<void> _copyParams() async {
    await Clipboard.setData(ClipboardData(text: _tuning.toJsonString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已复制参数 JSON，发给开发者即可固化')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('雾面调参')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          _PreviewCard(tuning: _tuning),
          const SizedBox(height: 16),
          _sectionTitle(context, '预设'),
          Row(
            children: [
              for (final preset in _presets)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ActionChip(
                    label: Text(preset.$1),
                    onPressed: () => _commit(preset.$2),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _sectionTitle(context, '模糊与饱和'),
          _TuningSlider(
            label: '模糊半径',
            hint: '越大越糊；0=只剩白蒙',
            value: _tuning.blurSigma,
            min: 0,
            max: FogTuningState.maxBlurSigma,
            divisions: 30,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => _apply(_tuning.copyWith(blurSigma: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(blurSigma: v)),
          ),
          _TuningSlider(
            label: '饱和',
            hint: '透出内容色的「湿度」；0=无色偏',
            value: _tuning.saturation,
            min: 0,
            max: 1.6,
            divisions: 32,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _apply(_tuning.copyWith(saturation: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(saturation: v)),
          ),
          _sectionTitle(context, '白感（三层）'),
          _TuningSlider(
            label: '奶白层',
            hint: '提亮；过高=白板感',
            value: _tuning.whiteNormal,
            min: 0,
            max: 0.5,
            divisions: 50,
            format: (v) => v.toStringAsFixed(3),
            onChanged: (v) => _apply(_tuning.copyWith(whiteNormal: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(whiteNormal: v)),
          ),
          _TuningSlider(
            label: '白 softLight',
            hint: '提密保色',
            value: _tuning.whiteSoftLight,
            min: 0,
            max: 1,
            divisions: 50,
            format: (v) => v.toStringAsFixed(3),
            onChanged: (v) => _apply(_tuning.copyWith(whiteSoftLight: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(whiteSoftLight: v)),
          ),
          _TuningSlider(
            label: '灰 softLight',
            hint: '玻璃厚度',
            value: _tuning.graySoftLight,
            min: 0,
            max: 0.5,
            divisions: 50,
            format: (v) => v.toStringAsFixed(3),
            onChanged: (v) => _apply(_tuning.copyWith(graySoftLight: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(graySoftLight: v)),
          ),
          _sectionTitle(context, '动态取色'),
          _TuningSlider(
            label: '取色浓度',
            hint: '雾面染色跟随滚动内容的强度；0=纯白雾',
            value: _tuning.tintMix,
            min: 0,
            max: FogTuningState.maxTintMix,
            divisions: 20,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _apply(_tuning.copyWith(tintMix: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(tintMix: v)),
          ),
          _sectionTitle(context, '雾形'),
          _TuningSlider(
            label: '上浓下淡',
            hint: '雾的气感；0=均匀玻璃板',
            value: _tuning.verticalGrad,
            min: 0,
            max: 1,
            divisions: 20,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _apply(_tuning.copyWith(verticalGrad: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(verticalGrad: v)),
          ),
          _TuningSlider(
            label: '顶部增幅',
            hint: '雾形全开时顶部额外增浓倍数；0=只衰减底部',
            value: _tuning.topBoost,
            min: 0,
            max: FogTuningState.maxTopBoost,
            divisions: 30,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => _apply(_tuning.copyWith(topBoost: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(topBoost: v)),
          ),
          _TuningSlider(
            label: '雾面高度',
            hint: '负=收窄（底缘上移，最少收到 0）；正=向下延伸；0=现状',
            value: _tuning.fogHeight,
            min: FogTuningState.minFogHeight,
            max: FogTuningState.maxFogHeight,
            divisions: 35,
            neutral: 0,
            format: (v) => '${v.round()}px',
            onChanged: (v) => _apply(_tuning.copyWith(fogHeight: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(fogHeight: v)),
          ),
          _TuningSlider(
            label: '底缘羽化',
            hint: '雾面底边消散宽度',
            value: _tuning.feather,
            min: 0,
            max: FogTuningState.maxFeather,
            divisions: 24,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) => _apply(_tuning.copyWith(feather: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(feather: v)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => _commit(FogTuningState.fallback),
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('恢复默认'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  onPressed: _copyParams,
                  icon: const Icon(Icons.copy_rounded),
                  label: const Text('复制参数'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '预览区可上下滑动验证穿雾；真实首页的雾面与本页同步生效。'
            '参数自动保存，重启保留。×N=粗调档位（量程十等分）。',

            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: cs.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(top: 16, bottom: 4),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .titleSmall
              ?.copyWith(fontWeight: FontWeight.w600),
        ),
      );
}

typedef _Preset = (String, FogTuningState);

const List<_Preset> _presets = <_Preset>[
  ('发布默认', FogTuningState.fallback),
  // blur σ 量程 0–3（用户定调）：「更雾」σ 顶格后靠加重 tint 浓度区分。
  // 预设只表达浓度/雾形配方，雾面高度显式归 0（不随发布默认 -14
  // 收窄——预设语义不含高度）。
  (
    '更雾',
    FogTuningState(
      blurSigma: 3.0,
      saturation: 1.1,
      whiteNormal: 0.22,
      whiteSoftLight: 0.48,
      graySoftLight: 0.2,
      feather: 28,
      verticalGrad: 0.7,
      fogHeight: 0,
    ),
  ),
  (
    '薄纱',
    FogTuningState(
      blurSigma: 1.2,
      saturation: 0.9,
      whiteNormal: 0.1,
      whiteSoftLight: 0.22,
      graySoftLight: 0.09,
      feather: 32,
      verticalGrad: 0.5,
      fogHeight: 0,
    ),
  ),
];

/// 仿首页滚动态的预览：浓色海报内容可滚动，顶部叠真实 TopFog。
class _PreviewCard extends StatefulWidget {
  const _PreviewCard({required this.tuning});

  final FogTuningState tuning;

  @override
  State<_PreviewCard> createState() => _PreviewCardState();
}

class _PreviewCardState extends State<_PreviewCard> {
  /// 预览区实时采样色：FogTintSampler 节流采样海报内容，驱动预览
  /// TopFog 染色——所见即所得（与首页同一采样通道）。
  final ValueNotifier<Color?> _tint = ValueNotifier<Color?>(null);

  @override
  void dispose() {
    _tint.dispose();
    super.dispose();
  }

  static const List<(Color, Color, String)> _posters = <(Color, Color, String)>[
    (Color(0xFFB3261E), Color(0xFF7A1610), '出手 · 共74集'),
    (Color(0xFF1565C0), Color(0xFF0D3B7A), '皎皎月色 · 共70集'),
    (Color(0xFF6A1B9A), Color(0xFF3D1057), '爱意凋亡 · 共44集'),
  ];

  @override
  Widget build(BuildContext context) {
    // 雾带高度跟随「雾面高度」参数（110=状态栏+顶栏基准；所见即所得）。
    // bandHeight：负档收窄（底缘上移），clamp≥0 防负高度。
    final fogBand = widget.tuning.bandHeight(110);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: SizedBox(
        height: 360,
        child: Stack(
          children: [
            Positioned.fill(
              // 采样只包内容层（TopFog 在 boundary 外，无反馈循环）；
              // 行带取海报区（顶部雾带+空白背景避开）。
              child: FogTintSampler(
                tint: _tint,
                sampleBandStart: 0.35,
                sampleBandEnd: 0.8,
                child: ColoredBox(
                  color:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                  child: ListView(
                    padding: EdgeInsets.only(top: fogBand),
                    children: [
                      for (final (a, b, title) in _posters)
                        Container(
                          height: 200,
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(12),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [a, b],
                            ),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            title,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      const SizedBox(height: 24),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: fogBand,
                child: ValueListenableBuilder<Color?>(
                  valueListenable: _tint,
                  builder: (_, tint, _) => TopFog(tint: tint),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TuningSlider extends StatelessWidget {
  const _TuningSlider({
    required this.label,
    required this.hint,
    required this.value,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.onChanged,
    required this.onChangeEnd,
    this.neutral,
  });

  final String label;
  final String hint;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final String Function(double) format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  /// 粗调 ×0 档基准值（默认量程下限；雾面高度传 0 得正负对称档）。
  final double? neutral;

  /// 粗调步长：neutral→max 十等分（全滑块统一 ×±10 档）。
  double get _stepSize => (max - (neutral ?? min)) / 10;

  /// 当前粗调档位 ×N（带符号；细调值按最近档取整显示）。
  String get _stepLabel {
    final n = ((value - (neutral ?? min)) / _stepSize).round();
    return n == 0 ? '×0' : (n > 0 ? '×+$n' : '×$n');
  }

  /// 粗调 ±1 档：滑块本体保持细调，按钮直接 commit（落盘）。
  void _stepBy(int dir) {
    final raw = value + dir * _stepSize;
    final next = raw < min ? min : (raw > max ? max : raw);
    if (next != value) onChangeEnd(next);
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(label, style: Theme.of(context).textTheme.bodyMedium),
            const Spacer(),
            Text(
              format(value),
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: cs.primary, fontFeatures: const [
                FontFeature.tabularFigures(),
              ]),
            ),
          ],
        ),
        Row(
          children: [
            Expanded(
              child: Text(hint,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: cs.onSurfaceVariant)),
            ),
            const SizedBox(width: 8),
            Text(
              _stepLabel,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                    color: cs.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
            ),
          ],
        ),
        Row(
          children: [
            IconButton(
              tooltip: '粗调 −1 档',
              onPressed: value <= min ? null : () => _stepBy(-1),
              icon: const Icon(Icons.remove),
              visualDensity: VisualDensity.compact,
            ),
            Expanded(
              child: Slider(
                value: value.clamp(min, max),
                min: min,
                max: max,
                divisions: divisions,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
            IconButton(
              tooltip: '粗调 +1 档',
              onPressed: value >= max ? null : () => _stepBy(1),
              icon: const Icon(Icons.add),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
      ],
    );
  }
}
