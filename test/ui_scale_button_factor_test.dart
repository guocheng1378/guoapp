import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/ui_scale.dart';

void main() {
  Future<double> factorFor(WidgetTester tester, double textScale) async {
    double? factor;
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Builder(
            builder: (context) {
              factor = UiScale.buttonFactor(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    return factor ?? -1;
  }

  testWidgets('按钮跟随倍率夹在 0.9~1.1（缩文字不缩按钮会割裂，全量跟随会挤爆窄屏）', (
    tester,
  ) async {
    expect(await factorFor(tester, 0.5), 0.9);
    expect(await factorFor(tester, 0.85), 0.9);
    expect(await factorFor(tester, 1.0), 1.0);
    expect(await factorFor(tester, 1.3), 1.1);
    expect(await factorFor(tester, 2.0), 1.1);
  });
}
