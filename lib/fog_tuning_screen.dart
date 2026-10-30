import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fog_legacy.dart';
import 'fog_tuning.dart';

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
      // 调参台自身顶栏不加雾面：页面里唯一的 TopFog 必须是预览区那一条，
      // 否则调参时会分不清顶部那条是页面顶栏还是参数效果。
      appBar: AppBar(title: const Text('旧雾面调参（遗留）')),
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
          _sectionTitle(context, '模糊'),
          _TuningSlider(
            label: '模糊半径',
            hint: '越大越糊；官方雾面带真值 σ20（渐变模糊：顶边满值→底边渐隐）',
            value: _tuning.blurSigma,
            min: 0,
            max: FogTuningState.maxBlurSigma,
            divisions: 30,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => _apply(_tuning.copyWith(blurSigma: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(blurSigma: v)),
          ),
          _sectionTitle(context, '雾形'),
          _TuningSlider(
            label: '上浓下淡',
            hint: '雾的气感；0=均匀玻璃板。顶部恒为官方基准浓度，'
                '本值只控制底部衰减（顶部放大会把层 alpha 顶爆成黑蒙版）',
            value: _tuning.verticalGrad,
            min: 0,
            max: 1,
            divisions: 20,
            format: (v) => v.toStringAsFixed(2),
            onChanged: (v) => _apply(_tuning.copyWith(verticalGrad: v)),
            onChangeEnd: (v) => _commit(_tuning.copyWith(verticalGrad: v)),
          ),
          _TuningSlider(
            label: '雾面高度',
            hint: '0 = 雾带底边贴住分组栏底边（不再向下多挂一条）；正=向下延伸；负=收窄',
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
  // MIUI 雾面带真值档：σ20 + 底色隐身 + 无矩阵 + 三层混色。
  // 预设只表达浓度/雾形配方，雾面高度显式归 0（不随发布默认 +56
  // 延伸——预设语义不含高度）。
  (
    '更浓雾',
    FogTuningState(
      blurSigma: 20.0,
      feather: 96,
      verticalGrad: 1.0,
      fogHeight: 0,
    ),
  ),
  (
    '更透',
    FogTuningState(
      blurSigma: 12.0,
      feather: 32,
      verticalGrad: 0.7,
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
              child: ColoredBox(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
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
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SizedBox(
                height: fogBand,
                child: const LegacyTopFog(),
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
