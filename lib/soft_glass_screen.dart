import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_scaffold.dart';
import 'soft_glass.dart';

/// 柔光玻璃材质调参台：7 个参数实时预览 + 4 预设 + 落盘/复制/恢复默认。
///
/// 与雾面调参台（`fog_tuning_screen.dart`）、顶栏渐变调参台
/// （`top_gradient_screen.dart`）同构：拖动即实时预览（只改内存），
/// 松手才落盘（`SoftGlassStore.save` 同时触发主题槽位重建）。
class SoftGlassScreen extends StatefulWidget {
  const SoftGlassScreen({super.key});

  @override
  State<SoftGlassScreen> createState() => _SoftGlassScreenState();
}

class _SoftGlassScreenState extends State<SoftGlassScreen> {
  SoftGlassSpec _tuning = SoftGlassStore.state.value;

  /// 拖动中：只更新内存（所有玻璃面实时重建，不落盘、不重建主题）。
  void _apply(SoftGlassSpec next) {
    setState(() => _tuning = next);
    SoftGlassStore.apply(next);
  }

  /// 松手：落盘 + 主题槽位重建。
  Future<void> _commit(SoftGlassSpec next) async {
    setState(() => _tuning = next);
    await SoftGlassStore.save(next);
  }

  Future<void> _reset() async {
    await SoftGlassStore.reset();
    if (!mounted) return;
    setState(() => _tuning = SoftGlassStore.state.value);
  }

  Future<void> _copy() async {
    await Clipboard.setData(
      ClipboardData(text: SoftGlassStore.state.value.toJsonString()),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制材质参数（JSON）')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: '柔光玻璃材质',
      subtitle: '清透磨砂 · 澎湃 OS 4 风格',
      children: [
        const _Preview(),
        const SoftGlassSectionTitle(text: '预设'),
        _presetRow(context),
        const SoftGlassSectionTitle(text: '参数'),
        _slider(
          context,
          key: 'tint-light',
          label: '浅色浓度',
          value: _tuning.tintLight,
          max: SoftGlassSpec.maxTintLight,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(tintLight: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(tintLight: v)),
        ),
        _slider(
          context,
          key: 'tint-dark',
          label: '深色浓度',
          value: _tuning.tintDark,
          max: SoftGlassSpec.maxTintDark,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(tintDark: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(tintDark: v)),
        ),
        _slider(
          context,
          key: 'blur-sigma',
          label: '磨砂半径 σ',
          value: _tuning.blurSigma,
          max: SoftGlassSpec.maxBlurSigma,
          digits: 1,
          onChanged: (v) => _apply(_tuning.copyWith(blurSigma: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(blurSigma: v)),
        ),
        _slider(
          context,
          key: 'inner-shadow',
          label: '上内阴影',
          value: _tuning.innerShadow,
          max: SoftGlassSpec.maxInnerShadow,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(innerShadow: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(innerShadow: v)),
        ),
        _slider(
          context,
          key: 'inner-highlight',
          label: '下内高光',
          value: _tuning.innerHighlight,
          max: SoftGlassSpec.maxInnerHighlight,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(innerHighlight: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(innerHighlight: v)),
        ),
        _slider(
          context,
          key: 'edge',
          label: '渐变描边',
          value: _tuning.edge,
          max: SoftGlassSpec.maxEdge,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(edge: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(edge: v)),
        ),
        _slider(
          context,
          key: 'saturation',
          label: '主色染色',
          value: _tuning.saturation,
          max: SoftGlassSpec.maxSaturation,
          digits: 2,
          onChanged: (v) => _apply(_tuning.copyWith(saturation: v)),
          onChangeEnd: (v) => _commit(_tuning.copyWith(saturation: v)),
        ),
        const SizedBox(height: 20),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  key: const ValueKey('soft-glass-reset'),
                  onPressed: _reset,
                  icon: const Icon(Icons.restart_alt),
                  label: const Text('恢复默认'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton.icon(
                  key: const ValueKey('soft-glass-copy'),
                  onPressed: _copy,
                  icon: const Icon(Icons.copy_all_outlined),
                  label: const Text('复制参数'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _presetRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final preset in _presets)
            ActionChip(
              key: ValueKey('soft-glass-preset-${preset.name}'),
              label: Text(preset.name),
              onPressed: () async {
                await SoftGlassStore.save(preset.spec);
                if (!mounted) return;
                setState(() => _tuning = SoftGlassStore.state.value);
              },
            ),
        ],
      ),
    );
  }

  Widget _slider(
    BuildContext context, {
    required String key,
    required String label,
    required double value,
    required double max,
    required int digits,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(label, style: theme.textTheme.bodyMedium),
          ),
          Expanded(
            child: Slider(
              key: ValueKey('soft-glass-slider-$key'),
              value: value.clamp(0.0, max),
              max: max,
              onChanged: onChanged,
              onChangeEnd: onChangeEnd,
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              value.toStringAsFixed(digits),
              textAlign: TextAlign.right,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 浅/深双栏预览：背后放浓色仿海报内容，玻璃面压在上面看清透度。
class _Preview extends StatelessWidget {
  const _Preview();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          Expanded(child: _PreviewCard(brightness: Brightness.light)),
          const SizedBox(width: 12),
          Expanded(child: _PreviewCard(brightness: Brightness.dark)),
        ],
      ),
    );
  }
}

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({required this.brightness});

  final Brightness brightness;

  @override
  Widget build(BuildContext context) {
    final dark = brightness == Brightness.dark;
    return Theme(
      data: dark ? ThemeData.dark() : ThemeData.light(),
      child: Container(
        height: 132,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: dark
                ? const [Color(0xFF7A2B1E), Color(0xFF241A2B)]
                : const [Color(0xFFFFB59E), Color(0xFF8E5BC7)],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Stack(
          children: [
            // 仿海报文字：磨砂后应糊成色块（σ 大）但仍可辨（σ 甜区）。
            Positioned(
              left: 10,
              top: 10,
              right: 10,
              child: Text(
                '出手一击 03',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.white.withValues(alpha: 0.92),
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 36,
              right: 10,
              bottom: 10,
              child: Align(
                alignment: Alignment.bottomLeft,
                child: SoftGlassSurface(
                  shape: SoftGlassShape.rounded,
                  radius: 16,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Text(
                    '清透磨砂',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: dark ? Colors.white : const Color(0xFF252328),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 预设档位：四档覆盖「极透 → 厚实」。
class _SoftGlassPreset {
  const _SoftGlassPreset(this.name, this.spec);

  final String name;
  final SoftGlassSpec spec;
}

const List<_SoftGlassPreset> _presets = [
  _SoftGlassPreset(
    '极透',
    SoftGlassSpec(
      tintLight: 0.08,
      tintDark: 0.14,
      blurSigma: 8,
      innerShadow: 0.08,
      innerHighlight: 0.06,
      edge: 0.22,
      saturation: 0.03,
    ),
  ),
  _SoftGlassPreset('平衡', SoftGlassSpec.fallback),
  _SoftGlassPreset(
    '厚实',
    SoftGlassSpec(
      tintLight: 0.22,
      tintDark: 0.34,
      blurSigma: 18,
      innerShadow: 0.16,
      innerHighlight: 0.10,
      edge: 0.34,
      saturation: 0.06,
    ),
  ),
  _SoftGlassPreset(
    '主色染色',
    SoftGlassSpec(
      tintLight: 0.14,
      tintDark: 0.22,
      blurSigma: 14,
      innerShadow: 0.12,
      innerHighlight: 0.08,
      edge: 0.30,
      saturation: 0.14,
    ),
  ),
];
