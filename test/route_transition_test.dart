import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/glass_preferences.dart';
import 'package:duanju_app/motion.dart';
import 'package:duanju_app/route_transition.dart';
import 'package:duanju_app/soft_glass.dart';

/// 回退卡顿回归：回退动画期把「重玻璃」降级（去模糊 + 去内阴影），
/// 动画结束下一帧自动恢复。
void main() {
  // 玻璃开关走 SharedPreferences：测试环境没有平台实现，不 mock 会挂起。
  SharedPreferences.setMockInitialValues({});

  tearDown(() async {
    RouteTransitionSignal.debugSetReversing(false);
    await GlassPreferences.setEnabled(true);
  });

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

  testWidgets('回退动画期：玻璃面撤掉 BackdropFilter，结束后恢复', (tester) async {
    await GlassPreferences.setEnabled(true);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SoftGlassSurface(child: Text('玻璃'))),
      ),
    );
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);

    RouteTransitionSignal.debugSetReversing(true);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsNothing);
    expect(find.text('玻璃'), findsOneWidget);

    RouteTransitionSignal.debugSetReversing(false);
    await tester.pump();
    expect(find.byType(BackdropFilter), findsOneWidget);
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
