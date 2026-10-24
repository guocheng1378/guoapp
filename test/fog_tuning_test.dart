import 'package:duanju_app/fog_tuning.dart';
import 'package:duanju_app/fog_tuning_screen.dart';
import 'package:duanju_app/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  tearDown(() {
    // 静态通道跨用例共享，恢复发布默认避免污染后续用例前提。
    FogTuningStore.state.value = FogTuningState.fallback;
  });

  group('FogTuningState 序列化与插值', () {
    test('发布默认值（v2157：用户调参台回发 10 参数固化）', () {
      const s = FogTuningState.fallback;
      expect(s.blurSigma, 3.0);
      expect(FogTuningState.maxBlurSigma, 3.0);
      expect(s.saturation, 1.6);
      expect(s.whiteNormal, closeTo(0.34, 1e-9));
      expect(s.whiteSoftLight, closeTo(1.0, 1e-9));
      expect(s.graySoftLight, closeTo(0.16, 1e-9));
      expect(s.feather, 120);
      expect(s.verticalGrad, 1.0);
      // 顶部增幅顶格 3.0：雾形顶格时顶部 4×。
      expect(s.topBoost, 3.0);
      expect(FogTuningState.maxTopBoost, 3.0);
      expect(FogTuningState.maxFeather, 120);
      // 动态取色 0.10：轻取色；0=现状纯白雾。
      expect(s.tintMix, closeTo(0.10, 1e-9));
      expect(FogTuningState.maxTintMix, 1.0);
      // 雾面高度默认 −14（负档收窄雾带）；量程 −110–240px 双向。
      expect(s.fogHeight, -14);
      expect(FogTuningState.minFogHeight, -110);
      expect(FogTuningState.maxFogHeight, 240);
    });

    test('toJsonString / fromJsonString 往返值相等', () {
      const s = FogTuningState(
        blurSigma: 2.4,
        saturation: 1.1,
        whiteNormal: 0.16,
        whiteSoftLight: 0.32,
        graySoftLight: 0.14,
        feather: 28,
        verticalGrad: 0.7,
        topBoost: 2.2,
        tintMix: 0.8,
        fogHeight: 96,
      );
      expect(FogTuningState.fromJsonString(s.toJsonString()).equals(s), isTrue);
      // 负档（收窄雾面）同样往返无损。
      const neg = FogTuningState(fogHeight: -48);
      expect(
        FogTuningState.fromJsonString(neg.toJsonString()).equals(neg),
        isTrue,
      );
    });

    test('防御解析：坏值 clamp、缺字段回落默认', () {
      final s = FogTuningState.fromJson(const <String, Object?>{
        'blurSigma': 999,
        'verticalGrad': -5,
        'whiteNormal': 10,
        'saturation': 1,
        'whiteSoftLight': 0.2,
        'graySoftLight': 0.1,
        'feather': 999,
        'topBoost': 99,
        'tintMix': 5,
        'fogHeight': 999,
      });
      expect(s.blurSigma, FogTuningState.maxBlurSigma);
      expect(s.verticalGrad, 0);
      expect(s.whiteNormal, 0.6);
      expect(s.feather, FogTuningState.maxFeather);
      expect(s.topBoost, FogTuningState.maxTopBoost);
      expect(s.tintMix, FogTuningState.maxTintMix);
      expect(s.fogHeight, FogTuningState.maxFogHeight);

      // 负向越界 clamp 到 minFogHeight（旧存量 0–240 值天然兼容）。
      final negative = FogTuningState.fromJson(const <String, Object?>{
        'fogHeight': -999,
      });
      expect(negative.fogHeight, FogTuningState.minFogHeight);

      final empty = FogTuningState.fromJson(const <String, Object?>{});
      expect(empty.equals(FogTuningState.fallback), isTrue);
    });

    test('colorMatrix：saturation=0 恒等，1=demo 真值，0.5 中点', () {
      const zero = FogTuningState(saturation: 0);
      final identity = zero.colorMatrix();
      expect(identity, const <double>[1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0]);

      const full = FogTuningState(saturation: 1);
      final demo = full.colorMatrix();
      expect(demo[0], closeTo(1.35415, 1e-6));
      expect(demo[6], closeTo(1.12825, 1e-6));
      expect(demo[12], closeTo(1.4176, 1e-6));

      const half = FogTuningState(saturation: 0.5);
      expect(half.colorMatrix()[0], closeTo((1 + 1.35415) / 2, 1e-6));
    });

    test('bandHeight：负档收窄雾带、clamp≥0 防负高度', () {
      const base = 110.0;
      expect(const FogTuningState(fogHeight: 0).bandHeight(base), 110);
      // 发布默认 fogHeight=-14：110px 基准雾带收窄到 96px。
      expect(FogTuningState.fallback.bandHeight(base), 96);
      expect(const FogTuningState(fogHeight: 90).bandHeight(base), 200);
      expect(const FogTuningState(fogHeight: -30).bandHeight(base), 80);
      expect(const FogTuningState(fogHeight: -110).bandHeight(base), 0);
      expect(const FogTuningState(fogHeight: -200).bandHeight(base), 0);
      expect(const FogTuningState(fogHeight: 240).bandHeight(base), 350);
    });
  });

  group('FogTuningStore 持久化', () {
    test('save 写盘 JSON 可再读', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      const tuned = FogTuningState(blurSigma: 2.4, verticalGrad: 0.8);
      await FogTuningStore.save(tuned);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('fog_tuning.v1'), tuned.toJsonString());
      expect(FogTuningStore.state.value.equals(tuned), isTrue);
    });

    test('load 从持久化恢复（_loaded 守卫内首个 load 生效）', () async {
      const tuned = FogTuningState(blurSigma: 2.2, verticalGrad: 0.5);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fog_tuning.v1': tuned.toJsonString(),
      });
      await FogTuningStore.load(await SharedPreferences.getInstance());
      expect(FogTuningStore.state.value.equals(tuned), isTrue);
    });
  });

  group('调参台界面', () {
    // 页面 ListView 懒加载：默认 800x600 视口放不下整页，且页面滚动
    // 手势会被预览卡内层 ListView 抢走——直接放大视口让全内容进树
    //（步进器用例要触达页尾「雾面高度」滑块，视口给足 2600）。
    Future<void> mountScreen(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const MaterialApp(home: FogTuningScreen()));
      await tester.pumpAndSettle();
    }

    testWidgets('预览区叠真实 TopFog，拖动滑块实时写入参数通道', (tester) async {
      // 默认 σ3 已顶格，置低值再拖才能断言「向右变糊」。
      FogTuningStore.state.value = const FogTuningState(blurSigma: 0.5);
      await mountScreen(tester);

      expect(find.byType(TopFog), findsOneWidget);
      expect(find.text('出手 · 共74集'), findsOneWidget);
      expect(find.text('模糊半径'), findsOneWidget);
      // 页面 ListView 懒加载：视口外区块（雾形等）不在树里，属预期。

      final center = tester.getCenter(find.byType(Slider).first);
      await tester.dragFrom(center, const Offset(80, 0));
      await tester.pumpAndSettle();

      expect(
        FogTuningStore.state.value.blurSigma,
        greaterThan(0.5),
        reason: '拖动中 _apply 必须实时更新共享通道（真实首页雾面同步响应）',
      );
    });

    testWidgets('恢复默认回到发布真值', (tester) async {
      FogTuningStore.state.value =
          const FogTuningState(blurSigma: 2.8, verticalGrad: 1);
      await mountScreen(tester);

      await tester.tap(find.text('恢复默认'));
      await tester.pumpAndSettle();

      expect(FogTuningStore.state.value.equals(FogTuningState.fallback), isTrue);
    });

    testWidgets('复制参数把当前 JSON 送进剪贴板', (tester) async {
      // SystemChannels.platform 出站消息在 widget test 中会永久挂起，
      //（SystemChrome 同坑）必须 mock 成功信封。
      Object? copied;
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.platform.name,
        (ByteData? msg) async {
          final call = const JSONMethodCodec().decodeMethodCall(msg!);
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map<Object, Object?>)['text'];
          }
          return const JSONMethodCodec().encodeSuccessEnvelope(null);
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMessageHandler(SystemChannels.platform.name, null));

      await mountScreen(tester);

      await tester.tap(find.text('复制参数'));
      await tester.pumpAndSettle();

      expect(copied, FogTuningStore.state.value.toJsonString());
      // 消化 SnackBar 4s 自动消失 timer，避免 pending timer 红。
      await tester.pump(const Duration(seconds: 5));
    });

    /// 定位指定滑块 label 正下方的粗调 ± 按钮：页面上多个滑块共用
    /// 同名图标（const Icon 规范化后甚至是同一实例，byWidget 会歧义
    /// 命中全部），按「label 底边之下、top 最小」的几何最近者选取。
    Future<void> tapStep(
      WidgetTester tester,
      String label, {
      required bool plus,
    }) async {
      final labelBottom = tester.getBottomRight(find.text(label)).dy;
      Element? target;
      var bestTop = double.infinity;
      for (final e
          in find.byIcon(plus ? Icons.add : Icons.remove).evaluate()) {
        final finder = find.byElementPredicate((el) => identical(el, e));
        final top = tester.getTopLeft(finder).dy;
        if (top >= labelBottom - 4 && top < bestTop) {
          target = e;
          bestTop = top;
        }
      }
      expect(target, isNotNull, reason: '$label 下方应有粗调按钮');
      await tester.tap(
        find.byElementPredicate((el) => identical(el, target)),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('粗调步进器：模糊半径 +1 档 = 量程十等分 0.3', (tester) async {
      // σ 默认顶格 3，置 0.5 再 +1 档（步长 (3-0)/10）。
      FogTuningStore.state.value = const FogTuningState(blurSigma: 0.5);
      await mountScreen(tester);

      await tapStep(tester, '模糊半径', plus: true);

      expect(FogTuningStore.state.value.blurSigma, closeTo(0.8, 1e-9));
    });

    testWidgets('雾面高度粗调：+1 档 0→24，−1 档 0→−24（负档收窄）', (tester) async {
      // 发布默认已非全 0（v2157 固化），显式置全 min 档验证步进语义。
      FogTuningStore.state.value = const FogTuningState(
        blurSigma: 0,
        saturation: 0,
        whiteNormal: 0,
        whiteSoftLight: 0,
        graySoftLight: 0,
        feather: 0,
        verticalGrad: 0,
        topBoost: 0,
        tintMix: 0,
        fogHeight: 0,
      );
      await mountScreen(tester);
      // 其它在 min 档的滑块也显示 ×0（verticalGrad 同为 0 档）。
      expect(find.text('×0'), findsWidgets);

      await tapStep(tester, '雾面高度', plus: true);
      expect(FogTuningStore.state.value.fogHeight, 24);
      expect(find.text('×+1'), findsOneWidget);

      await tapStep(tester, '雾面高度', plus: false);
      expect(FogTuningStore.state.value.fogHeight, 0);

      await tapStep(tester, '雾面高度', plus: false);
      expect(FogTuningStore.state.value.fogHeight, -24);
      expect(find.text('×-1'), findsOneWidget);
    });
  });
}
