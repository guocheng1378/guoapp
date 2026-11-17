import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/saved_library.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

void main() {
  Future<LocalStore> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester, Size size) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  WatchEntry watch(Drama drama, DateTime at) => WatchEntry(
    drama: drama,
    episode: 1,
    position: 5,
    duration: 60,
    updatedAt: at,
  );

  Widget page(LocalStore store, {required bool history}) => MaterialApp(
    home: Scaffold(
      body: SavedLibrary(
        repository: LibraryFeatureRepository(),
        store: store,
        history: history,
        onOpen: (_) {},
        onContinue: (_) {},
      ),
    ),
  );

  test('HistoryDayBucket 只按本地日历日分档（今天/昨天/更早）', () {
    final now = DateTime(2026, 11, 15, 9, 30);
    expect(HistoryDayBucket.forTime(DateTime(2026, 11, 15, 0, 1), now), '今天');
    expect(HistoryDayBucket.forTime(DateTime(2026, 11, 15, 23, 59), now), '今天');
    expect(HistoryDayBucket.forTime(DateTime(2026, 11, 14, 23, 59), now), '昨天');
    expect(HistoryDayBucket.forTime(DateTime(2026, 11, 13, 12), now), '更早');
    expect(HistoryDayBucket.forTime(DateTime(2025, 12, 31), now), '更早');
    // 时钟回拨/未来时间不算「明天」，统一归「今天」。
    expect(HistoryDayBucket.forTime(DateTime(2026, 11, 16, 8), now), '今天');
  });

  testWidgets('最近观看按今天/昨天/更早分组，并在封面标出站源', (tester) async {
    viewport(tester, const Size(390, 1400));
    final store = await create();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day, 12);
    final dramas = [
      const Drama(id: 'hongguo:h-today', source: 'hongguo', title: '今天看的', episodes: 3),
      const Drama(
        id: 'hongguo:h-yesterday',
        source: 'hongguo',
        title: '昨天看的',
        episodes: 3,
      ),
      const Drama(
        id: 'hongguo:h-earlier',
        source: 'hongguo',
        title: '以前看的',
        episodes: 3,
      ),
    ];
    final times = [
      today,
      today.subtract(const Duration(days: 1)),
      today.subtract(const Duration(days: 6)),
    ];
    for (var index = 0; index < dramas.length; index++) {
      await store.saveWatch(watch(dramas[index], times[index]));
    }

    await tester.pumpWidget(page(store, history: true));
    await tester.pumpAndSettle();

    // 三个分档标题按时间倒序排列。
    final todayHeader = find.byKey(const ValueKey('history-section-今天'));
    final yesterdayHeader = find.byKey(const ValueKey('history-section-昨天'));
    final earlierHeader = find.byKey(const ValueKey('history-section-更早'));
    expect(todayHeader, findsOneWidget);
    expect(yesterdayHeader, findsOneWidget);
    expect(earlierHeader, findsOneWidget);
    expect(
      tester.getTopLeft(todayHeader).dy,
      lessThan(tester.getTopLeft(yesterdayHeader).dy),
    );
    expect(
      tester.getTopLeft(yesterdayHeader).dy,
      lessThan(tester.getTopLeft(earlierHeader).dy),
    );
    // 卡片落在自己的档位下。
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('saved-hongguo:h-today'))).dy,
      greaterThan(tester.getTopLeft(todayHeader).dy),
    );
    expect(
      tester.getTopLeft(find.byKey(const ValueKey('saved-hongguo:h-today'))).dy,
      lessThan(tester.getTopLeft(yesterdayHeader).dy),
    );
    // 封面左上角站源小标。
    expect(find.text('红果'), findsNWidgets(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('追剧页保持平铺但同样带站源小标', (tester) async {
    viewport(tester, const Size(390, 844));
    final store = await create();
    await store.toggleFavorite(LibraryFeatureRepository.first);
    await tester.pumpWidget(page(store, history: false));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('saved-hongguo:one')), findsOneWidget);
    // 追剧页不分组。
    for (final label in HistoryDayBucket.order) {
      expect(find.byKey(ValueKey('history-section-$label')), findsNothing);
    }
    // 未观看时副标题也写站源名 → 至少两处「红果」（小标 + 副标题）。
    expect(find.text('红果'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
