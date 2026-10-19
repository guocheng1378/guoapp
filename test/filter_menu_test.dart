import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/catalog_sort.dart';
import 'package:duanju_app/catalog_sort_sheet.dart';
import 'package:duanju_app/glass.dart';
import 'package:duanju_app/models.dart';

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

    // 两节都渲染：排序 7 项 + 剧集状态 4 项（「全部」与「已完结」等不重名）。
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

  testWidgets('点选后浮卡内胶囊当场切换选中态', (tester) async {
    final updates = <CatalogView>[];
    final anchorKey = GlobalKey(debugLabel: 'anchor');
    late StateSetter hostSetState;

    await tester.pumpWidget(
      StatefulBuilder(
        builder: (context, setState) {
          hostSetState = setState;
          return MaterialApp(
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
                          // 模拟真实链路：onChanged → store 通知 →
                          // DuanjuApp 重建 MaterialApp → pageBuilder 重跑。
                          onChanged: (view) {
                            updates.add(view);
                            hostSetState(() {});
                          },
                        ),
                        child: const Text('open'),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    GlassChip chipOf(ValueKey<String> key) =>
        tester.widget<GlassChip>(find.byKey(key));
    const sourceChip = ValueKey<String>('filter-sort-source');
    const nameChip = ValueKey<String>('filter-sort-name');

    // 初始：源站顺序选中。
    expect(chipOf(sourceChip).selected, isTrue);
    expect(chipOf(nameChip).selected, isFalse);

    // 点「名称」：浮层保持打开，且胶囊当场切换选中——历史 bug 是
    // pageBuilder 随宿主重建重跑、局部 selected 被重置回源站顺序，
    // 要关闭重开才「追认」新选中。
    await tester.tap(find.byKey(nameChip));
    await tester.pumpAndSettle();
    expect(updates.single.sort, CatalogSort.name);
    expect(find.text('名称'), findsOneWidget, reason: '点选后浮层应保持打开');
    expect(chipOf(nameChip).selected, isTrue);
    expect(chipOf(sourceChip).selected, isFalse);

    // 状态维度同样当场切换。
    await tester.tap(find.byKey(const ValueKey('filter-release-finished')));
    await tester.pumpAndSettle();
    expect(updates.last.release, 'finished');
    expect(
      chipOf(const ValueKey('filter-release-finished')).selected,
      isTrue,
    );
    expect(chipOf(const ValueKey('filter-release-all')).selected, isFalse);
  });

  testWidgets('不可用排序项禁用且不产生回调', (tester) async {
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
                      supported: const {
                        CatalogSort.source,
                        CatalogSort.name,
                        CatalogSort.season,
                      },
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
    expect(updates, isEmpty);

    // 点置灰的「热度」：命中被 IgnorePointer 屏蔽，穿透到 barrier 关闭浮层，
    // 且回调里不出现 heat（若未禁用会回调 heat 且浮层保持打开）。
    await tester.tap(find.text('热度'), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(
      updates.where((view) => view.sort == CatalogSort.heat),
      isEmpty,
      reason: '禁用项不应产生排序回调',
    );
  });

  test('catalogSortSupport 依赖字段全空时禁用对应排序', () {
    const bare = Drama(id: 'd1', source: 's', title: '甲');
    final support = catalogSortSupport([bare, bare]);
    expect(support.contains(CatalogSort.heat), isFalse);
    expect(support.contains(CatalogSort.views), isFalse);
    expect(support.contains(CatalogSort.score), isFalse);
    expect(support.contains(CatalogSort.date), isFalse);
    expect(support.contains(CatalogSort.name), isTrue);
    expect(support.contains(CatalogSort.season), isTrue);
    expect(support.contains(CatalogSort.source), isTrue);

    const rich = Drama(
      id: 'd2',
      source: 's',
      title: '乙',
      heat: '12.3万次播放',
      score: '8.5',
      onlineDate: '2024-01-02',
    );
    final enriched = catalogSortSupport([rich]);
    expect(enriched.contains(CatalogSort.heat), isTrue);
    expect(enriched.contains(CatalogSort.score), isTrue);
    expect(enriched.contains(CatalogSort.date), isTrue);
    expect(enriched.contains(CatalogSort.views), isFalse);
  });

  test('scoreValue 解析与边界', () {
    expect(scoreValue('8.5'), 8.5);
    expect(scoreValue('9.2分'), 9.2);
    expect(scoreValue('0'), 0.0);
    expect(scoreValue(''), isNull);
    expect(scoreValue('暂无'), isNull);
    // 超出 0-10 视为无效（其他字段数值混入时不当评分）。
    expect(scoreValue('12'), isNull);
  });

  test('sortCatalog 地区年份筛选与评分排序', () {
    final items = [
      const Drama(
        id: 'a',
        source: 's',
        title: '甲',
        area: '内地',
        year: '2025',
        score: '8.5',
      ),
      const Drama(
        id: 'b',
        source: 's',
        title: '乙',
        area: '香港',
        year: '2024',
        score: '9.2',
      ),
      const Drama(id: 'c', source: 's', title: '丙', area: '内地', year: '2025'),
      const Drama(id: 'd', source: 's', title: '丁', score: '7.0'),
    ];
    // 地区/年份为精确匹配的本地筛选。
    expect(sortCatalog(items, const CatalogView(area: '内地')).map((d) => d.id), [
      'a',
      'c',
    ]);
    expect(sortCatalog(items, const CatalogView(year: '2024')).map((d) => d.id), [
      'b',
    ]);
    // 评分降序，解析不出的条目排尾（丙无分）。
    expect(
      sortCatalog(items, const CatalogView(sort: CatalogSort.score)).map((
        d,
      ) => d.id),
      ['b', 'a', 'd', 'c'],
    );
    // 筛选与排序可叠加。
    expect(
      sortCatalog(
        items,
        const CatalogView(sort: CatalogSort.score, area: '内地'),
      ).map((d) => d.id),
      ['a', 'c'],
    );
  });

  test('catalogFilterOptions 地区按数量降序、年份数字降序取前 10', () {
    final items = [
      for (var i = 0; i < 5; i++)
        Drama(id: 'a$i', source: 's', title: '$i', area: '内地', year: '2025'),
      for (var i = 0; i < 3; i++)
        Drama(id: 'b$i', source: 's', title: '$i', area: '香港', year: '2024'),
      const Drama(id: 'c', source: 's', title: 'c', area: '美国'),
      // 年份长尾（12 个不同年份）只取前 10。
      for (var i = 0; i < 12; i++)
        Drama(id: 'd$i', source: 's', title: '$i', year: '${2015 + i}'),
    ];
    final options = catalogFilterOptions(items);
    expect(options.areas.first, '内地');
    expect(options.areas[1], '香港');
    expect(options.areas, isNot(contains('')));
    expect(options.years.first, '2026');
    expect(options.years.length, 10);
  });

  test('CatalogView 持久化地区年份', () {
    const view = CatalogView(
      sort: CatalogSort.score,
      release: 'finished',
      area: '香港',
      year: '2024',
      allSources: true,
    );
    final restored = CatalogView.fromJson(view.toJson());
    expect(restored.sort, CatalogSort.score);
    expect(restored.release, 'finished');
    expect(restored.area, '香港');
    expect(restored.year, '2024');
    expect(restored.allSources, isTrue);
  });

  testWidgets('地区年份选项渲染且点选生效、可叠加', (tester) async {
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
                      areaOptions: const ['内地', '香港'],
                      yearOptions: const ['2025', '2024'],
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
    expect(find.text('地区'), findsOneWidget);
    expect(find.text('年份'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('filter-area-香港')));
    await tester.pumpAndSettle();
    expect(updates.last.area, '香港');
    await tester.tap(find.byKey(const ValueKey('filter-year-2025')));
    await tester.pumpAndSettle();
    expect(updates.last.year, '2025');
    expect(updates.last.area, '香港', reason: '地区与年份筛选应叠加生效');
    // 「全部」清空对应维度。
    await tester.tap(find.byKey(const ValueKey('filter-area-all')));
    await tester.pumpAndSettle();
    expect(updates.last.area, '');
    expect(updates.last.year, '2025');
  });

  testWidgets('未提供地区年份选项时不渲染对应节', (tester) async {
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
    expect(find.text('地区'), findsNothing);
    expect(find.text('年份'), findsNothing);
    expect(updates, isEmpty);
  });
}
