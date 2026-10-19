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

  testWidgets('头部连点 5 次触发激活彩蛋并关闭浮卡', (tester) async {
    final anchorKey = GlobalKey(debugLabel: 'anchor');
    var unlocked = 0;

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
                      onActivate: () => unlocked++,
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

    // 4 次 + 间隔超时：计数重置，不触发。
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('真果鉴'));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.tap(find.text('真果鉴'));
    await tester.pumpAndSettle();
    expect(unlocked, 0);
    expect(find.text('查看许可'), findsOneWidget);

    // 1.6 秒内连点 5 次：触发回调、只触发一次、浮卡自动关闭。
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('真果鉴'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(unlocked, 1);
    expect(find.text('查看许可'), findsNothing);
  });
}
