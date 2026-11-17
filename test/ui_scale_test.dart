import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/ui_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  test('normalize 按 5% 步进夹到 85%~130%', () {
    expect(UiScale.normalize(1), 1);
    expect(UiScale.normalize(1.02), 1);
    expect(UiScale.normalize(1.04), 1.05);
    expect(UiScale.normalize(9), 1.3);
    expect(UiScale.normalize(0), 0.85);
    expect(UiScale.normalize(double.nan), 1);
    expect(UiScale.label(1.15), '115%');
    expect(UiScale.label(0.87), '85%');
  });

  testWidgets('apply 把倍率乘到系统字体缩放上', (tester) async {
    UiScale.preview(1.2);
    addTearDown(() => UiScale.current.value = 1);
    late TextScaler scaler;
    await tester.pumpWidget(
      MediaQuery(
        // 系统无障碍字号 2.0：界面缩放要叠在它上面，而不是覆盖掉。
        data: const MediaQueryData(textScaler: TextScaler.linear(2)),
        child: Builder(
          builder: (context) => UiScale.apply(
            context,
            Builder(
              builder: (inner) {
                scaler = MediaQuery.textScalerOf(inner);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    expect(scaler.scale(10), closeTo(24, .01));
  });

  testWidgets('应用外壳把落盘倍率接进 MediaQuery', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    addTearDown(() => UiScale.current.value = 1);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setUiScale(1.2);
    expect(UiScale.current.value, 1.2);

    await tester.pumpWidget(
      DuanjuApp(repository: FixtureRepository(), store: store),
    );
    await tester.pumpAndSettle();
    final context = tester.element(find.byType(HomeScreen));
    expect(MediaQuery.textScalerOf(context).scale(10), closeTo(12, .1));
  });

  testWidgets('倍率为 100% 时不额外包 MediaQuery', (tester) async {
    UiScale.current.value = 1;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(),
        child: Builder(
          builder: (context) => UiScale.apply(
            context,
            const SizedBox.shrink(key: ValueKey('plain')),
          ),
        ),
      ),
    );
    expect(find.byKey(const ValueKey('plain')), findsOneWidget);
  });
}
