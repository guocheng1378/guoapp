import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'app_scaffold.dart';
import 'fog_tuning_screen.dart';
import 'soft_glass.dart';
import 'soft_glass_screen.dart';

/// 外观调参统一入口：把材质调参台（柔光玻璃 / 顶栏雾面）与玻璃总开关收在
/// 一处。顶栏渐变档已于 2026-10-29 整档删除，顶栏只剩三层混色雾面。
class AppearanceScreen extends StatelessWidget {
  const AppearanceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return AppScaffold(
      title: '外观调参',
      subtitle: '柔光玻璃 · 顶栏雾面',
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: SoftGlassCard(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              children: [
                _entry(
                  context,
                  icon: AppIcon(AppIcons.blur),
                  title: '柔光玻璃材质',
                  subtitle: '清透磨砂：底色浓度 / 磨砂半径 / 柔光三特征',
                  onTap: () => _push(context, const SoftGlassScreen()),
                ),
                _divider(),
                _entry(
                  context,
                  icon: AppIcon(AppIcons.tune),
                  title: '顶栏雾面',
                  subtitle: '状态栏→顶栏的整条雾带：糊化、染色、雾形、羽化',
                  onTap: () => _push(context, const FogTuningScreen()),
                ),
              ],
            ),
          ),
        ),
        const SoftGlassSectionTitle(text: '当前配方'),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: SoftGlassCard(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: ValueListenableBuilder<SoftGlassSpec>(
              valueListenable: SoftGlassStore.state,
              builder: (context, spec, _) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    softGlassSummary(),
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '玻璃总开关在「设置与备份 → 玻璃效果」；关闭后所有玻璃面'
                    '降级为不透明浮层。',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _entry(
    BuildContext context, {
    required Widget icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return SoftGlassListTile(
      title: title,
      subtitle: subtitle,
      leading: icon,
      trailing: AppIcon(AppIcons.chevronRight),
      onTap: onTap,
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.only(left: 56),
    child: Divider(height: 1, thickness: 0.6),
  );

  void _push(BuildContext context, Widget page) {
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

/// 柔光玻璃当前配方的单行摘要（设置页副标题用）。
String softGlassSummary() {
  final spec = SoftGlassStore.state.value;
  return 'σ ${spec.blurSigma.toStringAsFixed(1)} · '
      '浅 ${spec.tintLight.toStringAsFixed(2)} / 深 ${spec.tintDark.toStringAsFixed(2)}';
}
