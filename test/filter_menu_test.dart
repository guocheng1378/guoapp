import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/catalog_sort.dart';
import 'package:duanju_app/catalog_sort_sheet.dart';

void main() {
  testWidgets('筛选浮卡点选即生效并保持打开', (tester) async {
    final updates = <CatalogView>[];
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
                    onPressed: () => showCatalogFilterMenu(
                      context: context,
                      anchorKey: anchorKey,
                      current: const CatalogView(),
                      onChanged: updates.add,
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

    // 两节都渲染：排序 6 项 + 剧集状态 4 项（「全部」与「已完结」等不重名）。
    expect(find.text('源站顺序'), findsOneWidget);
    expect(find.text('剧集状态'), findsOneWidget);
    expect(updates, isEmpty);

    // 点「热度」→ 立即回调 heat，浮层保持打开。
    await tester.tap(find.text('热度'));
    await tester.pumpAndSettle();
    expect(updates, hasLength(1));
    expect(updates.single.sort, CatalogSort.heat);
    expect(updates.single.release, '');
    expect(find.text('热度'), findsOneWidget, reason: '点选后浮层应保持打开');

    // 再点「连载中」→ release 维度叠加生效。
    await tester.tap(find.text('连载中'));
    await tester.pumpAndSettle();
    expect(updates, hasLength(2));
    expect(updates.last.sort, CatalogSort.heat);
    expect(updates.last.release, 'ongoing');

    // barrier 可点按关闭。
    await tester.tapAt(const Offset(20, 500));
    await tester.pumpAndSettle();
    expect(find.text('热度'), findsNothing);
  });
}
