import 'dart:convert';

import 'package:duanju_app/fog_legacy.dart';
import 'package:duanju_app/fog_tuning.dart';
import 'package:duanju_app/fog_tuning_screen.dart';
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
    test('发布默认值（v2236：官方直译档，遗留层参数已删除）', () {
      const s = FogTuningState.fallback;
      // 模糊 σ = 20（官方 home_page._fogHeader: ImageFilter.blur(sigmaX: 20)）。
      // σ30 是圆形按钮 FogButton 的值，不是雾面带的。
      expect(s.blurSigma, 20.0);
      expect(FogTuningState.maxBlurSigma, 20.0);
      // 底缘羽化 48（v2240：浓度盖到分组栏底、贴底收尾干脆）。
      expect(s.feather, 48);
      expect(FogTuningState.maxFeather, 160);
      // 上浓下淡：顶部恒为官方基准浓度，只让底部衰减（顶部放大会把层 alpha
      // 顶爆成黑蒙版）。
      expect(s.verticalGrad, 1.0);
      // 雾面高度默认 0（v2240：雾带底边正好贴住分组栏底边，不再向下多挂
      // 一条）；量程 −110–240px 双向。
      expect(s.fogHeight, 0);
      expect(FogTuningState.minFogHeight, -110);
      expect(FogTuningState.maxFogHeight, 240);
    });

    test('遗留层参数已从模型里删除（照搬官方，不要旧的）', () {
      final json = FogTuningState.fallback.toJson();
      for (final legacy in const <String>[
        'whiteNormal',
        'whiteSoftLight',
        'graySoftLight',
        'fogBase',
        'saturation',
        'tintMix',
        'topBoost',
      ]) {
        expect(
          json.containsKey(legacy),
          isFalse,
          reason: '$legacy 是历轮自加的遗留层，官方雾面带没有',
        );
      }
      // 模型只剩 4 个维度。
      expect(json.keys.length, 4);
    });

    test('toJsonString / fromJsonString 往返值相等', () {
      const s = FogTuningState(
        blurSigma: 2.4,
        feather: 28,
        verticalGrad: 0.7,
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

    test('防御解析：坏值 clamp、缺字段回落默认、旧遗留键被忽略', () {
      final s = FogTuningState.fromJson(const <String, Object?>{
        'blurSigma': 999,
        'verticalGrad': -5,
        'feather': 999,
        'fogHeight': 999,
        // 旧档遗留键：模型里已无这些字段 → 必须被忽略（不是崩、不是残留）。
        'whiteNormal': 10,
        'saturation': 1,
        'whiteSoftLight': 0.2,
        'graySoftLight': 0.1,
        'fogBase': 0.65,
        'tintMix': 5,
        'topBoost': 99,
      });
      expect(s.blurSigma, FogTuningState.maxBlurSigma);
      expect(s.verticalGrad, 0);
      expect(s.feather, FogTuningState.maxFeather);
      expect(s.fogHeight, FogTuningState.maxFogHeight);

      // 负向越界 clamp 到 minFogHeight（旧存量 0–240 值天然兼容）。
      final negative = FogTuningState.fromJson(const <String, Object?>{
        'fogHeight': -999,
      });
      expect(negative.fogHeight, FogTuningState.minFogHeight);

      final empty = FogTuningState.fromJson(const <String, Object?>{});
      expect(empty.equals(FogTuningState.fallback), isTrue);
    });

    test('bandHeight：负档收窄雾带、clamp≥0 防负高度', () {
      const base = 110.0;
      expect(const FogTuningState(fogHeight: 0).bandHeight(base), 110);
      // 发布默认 fogHeight=0：110px 基准雾带底边正好贴分组栏底边。
      expect(FogTuningState.fallback.bandHeight(base), 110);
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
      // 取一组**不触发迁移**的值（= 发布默认档，只改 verticalGrad），验证
      // load 是原样恢复而不是走收敛。
      const tuned = FogTuningState(verticalGrad: 0.5);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fog_tuning.v1': tuned.toJsonString(),
      });
      await FogTuningStore.load(await SharedPreferences.getInstance());
      expect(FogTuningStore.state.value.equals(tuned), isTrue);
    });

    test('load 把旧档收敛到官方直译档（σ20 + 遗留层全清 + 雾高正档）', () async {
      // 旧档 = 2233 收敛值（含灰平涂底 / 饱和矩阵 / 白灰层 / 取色浓度，
      // 这些键在模型里已不存在 → 读出来天然是官方直译档）。
      SharedPreferences.setMockInitialValues(<String, Object>{
        'fog_tuning.v1': jsonEncode(<String, Object>{
          'blurSigma': 30.0,
          'saturation': 1.6,
          'fogBase': 0.65,
          'whiteNormal': 0.3,
          'whiteSoftLight': 1.0,
          'graySoftLight': 0.08,
          'tintMix': 0.5,
          'topBoost': 1.6,
          'fogHeight': -14,
          'feather': 160,
        }),
      });
      FogTuningStore.resetLoadedFlag();
      await FogTuningStore.load(await SharedPreferences.getInstance());
      final v = FogTuningStore.state.value;
      // σ 漂移 → 官方真值 20。
      expect(v.blurSigma, 20.0);
      // 羽化 = 旧发布默认 160 → 收回到新默认 48（浓度盖到分组栏底）。
      expect(v.feather, 48);
      // 雾高 -14 是用户侧负档（收窄），不是旧发布默认 56 → 保留不收敛。
      expect(v.fogHeight, -14);
      // 遗留键不再出现在落盘结果里。
      final keys = v.toJson().keys.toSet();
      expect(keys.contains('fogBase'), isFalse);
      expect(keys.contains('saturation'), isFalse);
      expect(keys.contains('whiteNormal'), isFalse);
      expect(keys.contains('topBoost'), isFalse);
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
      // 默认 σ20 已顶格，置低值再拖才能断言「向右变糊」。
      FogTuningStore.state.value = const FogTuningState(blurSigma: 0.5);
      await mountScreen(tester);

      expect(find.byType(LegacyTopFog), findsOneWidget);
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

    testWidgets('调参台不再有遗留层滑块（旧的已删除）', (tester) async {
      await mountScreen(tester);
      for (final legacy in const <String>[
        '饱和',
        '灰平涂浓度',
        '奶白层',
        '白 softLight',
        '灰 softLight',
        '取色浓度',
        '顶部增幅',
      ]) {
        expect(
          find.text(legacy),
          findsNothing,
          reason: '$legacy 是遗留层滑块，v2236 已删除',
        );
      }
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

    testWidgets('粗调步进器：模糊半径 +1 档 = 量程十等分 2.0', (tester) async {
      // σ 量程 0–20（官方真值），置 0.5 再 +1 档（步长 (20-0)/10 = 2.0）。
      FogTuningStore.state.value = const FogTuningState(blurSigma: 0.5);
      await mountScreen(tester);

      await tapStep(tester, '模糊半径', plus: true);

      expect(FogTuningStore.state.value.blurSigma, closeTo(2.5, 1e-9));
    });

    testWidgets('雾面高度粗调：+1 档 0→24，−1 档 0→−24（负档收窄）', (tester) async {
      // 发布默认已非全 0（发布默认档），显式置全 min 档验证步进语义。
      FogTuningStore.state.value = const FogTuningState(
        blurSigma: 0,
        feather: 0,
        verticalGrad: 0,
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
