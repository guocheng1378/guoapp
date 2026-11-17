import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// 简介页「系列多季」折叠入口（移植自上游 5e3c4e9）：
// 本地原先把所有季平铺成胶囊，把剧集列表挤下一屏；改为一条入口 + 点开展开。

const _season1 = Drama(
  id: 'hongguo:201',
  source: 'hongguo',
  title: '合成剧场 第1部',
  episodes: 2,
  contentKind: 'long',
);

const _season2 = Drama(
  id: 'hongguo:202',
  source: 'hongguo',
  title: '合成剧场 第2部',
  episodes: 2,
  contentKind: 'long',
);

Future<LocalStore> _store(Iterable<Drama> favorites) async {
  SharedPreferences.setMockInitialValues(<String, Object>{'forceLogin': false});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  for (final drama in favorites) {
    await store.toggleFavorite(drama);
  }
  return store;
}

Future<void> _pump(WidgetTester tester, LocalStore store) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light,
      home: DetailScreen(
        drama: _season1,
        repository: FixtureRepository(),
        store: store,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('多季收成一条入口，点开才平铺各季', (tester) async {
    final store = await _store([_season1, _season2]);
    await _pump(tester, store);

    expect(find.text('系列多季'), findsOneWidget);
    expect(find.text('共 2 部'), findsOneWidget);
    // 折叠态：各季胶囊不在树上
    expect(find.byKey(const ValueKey('series-hongguo:202')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('series-toggle')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('series-hongguo:201')), findsOneWidget);
    expect(find.byKey(const ValueKey('series-hongguo:202')), findsOneWidget);

    // 再点一次收起
    await tester.tap(find.byKey(const ValueKey('series-toggle')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('series-hongguo:202')), findsNothing);
  });

  testWidgets('只有一季时不渲染系列入口', (tester) async {
    final store = await _store([_season1]);
    await _pump(tester, store);

    expect(find.text('系列多季'), findsNothing);
    expect(find.byKey(const ValueKey('series-toggle')), findsNothing);
  });
}
