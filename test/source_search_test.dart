import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/search_input.dart';
import 'package:duanju_app/source_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  setUp(() => SourceSearchBus.pending.value = null);
  tearDown(() => SourceSearchBus.pending.value = null);

  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  test('总线只交付一次，空白剧名不写请求', () {
    SourceSearchBus.request('   ');
    expect(SourceSearchBus.pending.value, isNull);

    SourceSearchBus.request(' 测试短剧 ');
    final request = SourceSearchBus.take();
    expect(request?.query, '测试短剧');
    // 取走后清空：首页一帧重建也不会重复消费。
    expect(SourceSearchBus.pending.value, isNull);
    expect(SourceSearchBus.take(), isNull);
  });

  testWidgets('点换个源找：写请求并退回首页', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('首页'))),
    );
    tester
        .state<NavigatorState>(find.byType(Navigator))
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(
              body: Center(child: GroupSearchButton(title: '测试短剧')),
            ),
          ),
        );
    await tester.pumpAndSettle();
    await tester.tap(find.text('换个源找'));
    await tester.pumpAndSettle();
    // popUntil(isFirst)：播放器/简介页整条栈退回首页。
    expect(find.text('首页'), findsOneWidget);
    expect(SourceSearchBus.take()?.query, '测试短剧');
  });

  testWidgets('分组内没有别的源时不显示换源入口', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: GroupSearchButton(title: '测试短剧', enabled: false),
        ),
      ),
    );
    expect(find.text('换个源找'), findsNothing);
    expect(SourceSearchBus.pending.value, isNull);
  });

  testWidgets('播放失败换源：只搜当前分组，不跨类搜全部站源', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FixtureRepository();
    final local = await store();
    // 全源变体下把所有源（含隐藏的黄果类/成人类）都打开，验证搜索
    // 范围仍被钉在当前源（红果=短剧类）所在分组，不再逐个等 18 个源。
    await local.setSourceSwitches({
      for (final site in SourceSite.values) site.id: true,
    });
    await local.setRestrictedUnlocked(true);
    await tester.pumpWidget(DuanjuApp(repository: repository, store: local));
    await tester.pumpAndSettle();

    repository.requests.clear();
    repository.queries.clear();
    SourceSearchBus.request('测试短剧');
    await tester.pumpAndSettle();

    final field = tester.widget<TextField>(
      find.descendant(
        of: find.byType(SearchInput),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller?.text, '测试短剧');
    expect(repository.queries, contains('测试短剧'));
    expect(repository.requests, contains('hongguo'));
    // 本分组以外一个都不该发请求：黄豆属黄果类，是最典型的跨类源。
    final outside = <String>{
      for (final site in SourceSite.values)
        if (site.classKey != SourceSite.hongguo.classKey) site.id,
    };
    for (final id in outside) {
      expect(
        repository.requests,
        isNot(contains(id)),
        reason: '$id 不在当前源所在分组，不该发搜索请求',
      );
    }
    // 程序触发的换源搜索只展示结果，不能自动聚焦搜索框弹输入法。
    expect(tester.testTextInput.isVisible, isFalse);
    // 吸顶搜索头的等高占位必须在：否则第一排结果被顶栏整块盖住。
    expect(find.byKey(const ValueKey('search-header-spacer')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
