import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/glass_preferences.dart';
import 'package:duanju_app/soft_glass.dart';
import 'package:duanju_app/soft_glass_screen.dart';

void main() {
  tearDown(() async {
    await GlassPreferences.setEnabled(true);
  });

  test('默认配方：清透磨砂基准值', () {
    const spec = SoftGlassSpec.fallback;
    expect(spec.tintLight, 0.14);
    expect(spec.tintDark, 0.22);
    expect(spec.blurSigma, 14);
    expect(spec.innerShadow, 0.12);
    expect(spec.innerHighlight, 0.08);
    expect(spec.edge, 0.14);
    expect(spec.saturation, 0.05);
  });

  test('非法值逐字段回落（单字段坏值不拖垮整组）', () {
    final spec = SoftGlassSpec.fromJson({
      'tintLight': 'abc',
      'tintDark': 0.9,
      'blurSigma': -5,
      'edge': null,
    });
    expect(spec.tintLight, SoftGlassSpec.fallback.tintLight);
    expect(spec.tintDark, SoftGlassSpec.maxTintDark);
    expect(spec.blurSigma, 0);
    expect(spec.edge, SoftGlassSpec.fallback.edge);
    expect(spec.innerShadow, SoftGlassSpec.fallback.innerShadow);
    expect(spec.innerHighlight, SoftGlassSpec.fallback.innerHighlight);
    expect(spec.saturation, SoftGlassSpec.fallback.saturation);
  });

  test('JSON 往返 + 值相等语义（fromJson 每次新实例）', () {
    final spec = SoftGlassSpec(
      tintLight: 0.2,
      tintDark: 0.3,
      blurSigma: 9,
      innerShadow: 0.15,
      innerHighlight: 0.11,
      edge: 0.4,
      saturation: 0.07,
    );
    final back = SoftGlassSpec.fromJsonString(spec.toJsonString());
    expect(back, spec);
    expect(back.hashCode, spec.hashCode);
    expect(back.equals(spec), isTrue);
    expect(back.copyWith(blurSigma: 1), isNot(spec));
  });

  test('持久化：落盘后「重启」可恢复配方', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    SoftGlassStore.resetLoadedFlag();
    await SoftGlassStore.save(
      const SoftGlassSpec(tintLight: 0.33, blurSigma: 7),
    );
    // 模拟重启：内存回落默认，再从盘上恢复。
    SoftGlassStore.resetLoadedFlag();
    SoftGlassStore.state.value = SoftGlassSpec.fallback;
    await SoftGlassStore.load(prefs);
    expect(SoftGlassStore.state.value.tintLight, 0.33);
    expect(SoftGlassStore.state.value.blurSigma, 7);
  });

  testWidgets('玻璃总开关：关闭后玻璃面不再有 BackdropFilter（降级不透明）', (
    tester,
  ) async {
    await GlassPreferences.setEnabled(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SoftGlassSurface(child: Text('玻璃'))),
      ),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);

    await GlassPreferences.setEnabled(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('玻璃'), findsOneWidget);
  });

  testWidgets('材质配方实时生效：改配方后玻璃面立即重建', (tester) async {
    await GlassPreferences.setEnabled(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SoftGlassSurface(child: Text('玻璃'))),
      ),
    );
    await tester.pump();
    final before = find.byType(BackdropFilter);
    expect(before, findsOneWidget);

    SoftGlassStore.apply(const SoftGlassSpec(blurSigma: 0));
    await tester.pump();
    // σ=0 → 不再渲染模糊层（清透到底）。
    expect(find.byType(BackdropFilter), findsNothing);

    SoftGlassStore.apply(SoftGlassSpec.fallback);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
  });

  testWidgets('调参台：滑块实时改配方（只动内存），预设落盘并顶起主题信号', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    SoftGlassStore.resetLoadedFlag();
    SoftGlassStore.state.value = SoftGlassSpec.fallback;
    final revisionBefore = SoftGlassStore.revision.value;

    await tester.pumpWidget(const MaterialApp(home: SoftGlassScreen()));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('soft-glass-slider-blur-sigma')), findsOneWidget);
    expect(find.byKey(const ValueKey('soft-glass-preset-平衡')), findsOneWidget);

    final slider = find.byKey(const ValueKey('soft-glass-slider-blur-sigma'));
    // 拖动中（未松手）：只改内存，不落盘、不重建主题。
    final gesture = await tester.startGesture(tester.getCenter(slider));
    await gesture.moveBy(const Offset(40, 0));
    await tester.pumpAndSettle();
    expect(SoftGlassStore.state.value.blurSigma, isNot(14));
    expect(SoftGlassStore.revision.value, revisionBefore);
    // 松手：落盘 + 主题重建信号自增。
    await gesture.up();
    await tester.pumpAndSettle();
    expect(SoftGlassStore.revision.value, greaterThan(revisionBefore));

    // 点预设 → 落盘 + 配方回到该档。
    await tester.tap(find.byKey(const ValueKey('soft-glass-preset-平衡')));
    await tester.pumpAndSettle();
    expect(SoftGlassStore.state.value.blurSigma, 14);
    expect(SoftGlassStore.revision.value, greaterThan(revisionBefore));
  });

  testWidgets('调参台：复制参数写入剪贴板', (tester) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        calls.add(call);
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    // 页面是懒加载 ListView：视口放大后底部按钮才进树。
    tester.view.physicalSize = const Size(900, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const MaterialApp(home: SoftGlassScreen()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('soft-glass-copy')));
    await tester.pumpAndSettle();

    final clip = calls
        .where((call) => call.method == 'Clipboard.setData')
        .toList();
    expect(clip, isNotEmpty);
    final args = (clip.first.arguments as Map).cast<String, Object?>();
    expect((args['text'] as String).contains('blurSigma'), isTrue);
  });
}
