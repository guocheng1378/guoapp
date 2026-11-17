import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/glass_preferences.dart';
import 'package:duanju_app/motion.dart';
import 'package:duanju_app/route_transition.dart';
import 'package:duanju_app/soft_glass.dart';

/// 回退卡顿回归：回退动画期只**降采样**（σ×0.7 + 去内阴影），
/// 模糊必须保留——旧实现把磨砂直接抹成 0，被用户判定为不可接受。
void main() {
  // 玻璃开关走 SharedPreferences：测试环境没有平台实现，不 mock 会挂起。
  SharedPreferences.setMockInitialValues({});

  tearDown(() async {
    RouteTransitionSignal.debugSetReversing(false);
    await GlassPreferences.setEnabled(true);
  });

  /// 取玻璃面的柔光特征 painter（唯一那颗 CustomPaint）。
  SoftGlassPainter glassPainter(WidgetTester tester) {
    final paint = tester.widget<CustomPaint>(
      find
          .descendant(
            of: find.byType(SoftGlassSurface),
            matching: find.byType(CustomPaint),
          )
          .first,
    );
    return paint.painter! as SoftGlassPainter;
  }

  test('信号计数成对：嵌套回退不会提前解除降级', () {
    RouteTransitionSignal.beginReverse();
    expect(RouteTransitionSignal.isReversing, isTrue);
    RouteTransitionSignal.beginReverse();
    RouteTransitionSignal.endReverse();
    expect(RouteTransitionSignal.isReversing, isTrue);
    RouteTransitionSignal.endReverse();
    expect(RouteTransitionSignal.isReversing, isFalse);
    // 多退一次不会把状态搞成负数。
    RouteTransitionSignal.endReverse();
    expect(RouteTransitionSignal.isReversing, isFalse);
  });

  testWidgets('回退动画期：磨砂保留，只跳内阴影；结束后恢复满档', (tester) async {
    await GlassPreferences.setEnabled(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SoftGlassSurface(child: Text('玻璃'))),
      ),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(glassPainter(tester).cheap, isFalse);

    RouteTransitionSignal.debugSetReversing(true);
    await tester.pump();
    // 模糊绝不撤掉（用户明确要求保留）。
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(find.text('玻璃'), findsOneWidget);
    // 降级的只有两次大半径 MaskFilter（内阴影/内高光）。
    expect(glassPainter(tester).cheap, isTrue);

    RouteTransitionSignal.debugSetReversing(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
    expect(glassPainter(tester).cheap, isFalse);
  });

  testWidgets('转场接线：pop 动画期间全局信号置位，动画结束复位', (tester) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        theme: ThemeData(
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: <TargetPlatform, PageTransitionsBuilder>{
              TargetPlatform.android: FadeScalePageTransitionsBuilder(),
            },
          ),
        ),
        home: const Scaffold(body: Center(child: Text('首页'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(RouteTransitionSignal.isReversing, isFalse);

    navKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Center(child: Text('二级页'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('二级页'), findsOneWidget);
    expect(RouteTransitionSignal.isReversing, isFalse);

    navKey.currentState!.pop();
    await tester.pump();
    // 反向动画进行中 → 重玻璃降级。
    expect(RouteTransitionSignal.isReversing, isTrue);
    await tester.pumpAndSettle();
    expect(RouteTransitionSignal.isReversing, isFalse);
  });
}
