import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/about_card.dart';

void main() {
  testWidgets('关于浮卡锚定出现、点空白关闭、查看许可推许可页', (tester) async {
    final anchorKey = GlobalKey(debugLabel: 'anchor');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  key: anchorKey,
                  width: 48,
                  height: 48,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
              Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    onPressed: () => showAboutCard(
                      context: context,
                      anchorKey: anchorKey,
                      appName: '真果鉴',
                      version: '0.2.94',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('真果鉴'), findsOneWidget);
    expect(find.text('0.2.94'), findsOneWidget);
    expect(find.text('查看许可'), findsOneWidget);

    // 点空白处关闭。
    await tester.tapAt(const Offset(20, 500));
    await tester.pumpAndSettle();
    expect(find.text('查看许可'), findsNothing);

    // 再次打开，点「查看许可」→ 浮卡关闭并推入许可页。
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看许可'));
    await tester.pumpAndSettle();
    expect(find.text('查看许可'), findsNothing);
    expect(find.byType(LicensePage), findsOneWidget);
  });
}
