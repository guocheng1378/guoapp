import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/related_catalog_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// 简介页二次导航（2026-10-25 用户反馈「简介页的东西都不能点击跳转」）：
// 站源名/分类/标签此前全是纯 Text 没有任何手势，现在都要能点出相关结果页。
// 运行需带 --dart-define=ALL_SOURCES=true：否则 SourceSite.values 只剩红果，
// 简介页会落到「当前用户无权访问」。

const _drama = Drama(
  id: 'dongpiandi:9001',
  source: 'dongpiandi',
  title: '合成短剧甲',
  episodes: 12,
  category: '短剧',
  tags: ['都市', '甜宠'],
  releaseStatus: 'ongoing',
);

Future<void> frames(WidgetTester tester, {int count = 24}) async {
  // 详情页/结果页都有循环指示动画，pumpAndSettle 会一直等到超时。
  for (var index = 0; index < count; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore() async {
    // 默认档案受保护且 forceLogin 缺省开启 → store 会触发自锁，
    // 简介页只渲染「当前用户无权访问」。这里显式关掉强制登录。
    SharedPreferences.setMockInitialValues(<String, Object>{'forceLogin': false});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<FixtureRepository> pumpDetail(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
    final store = await localStore();
    final repository = FixtureRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: DetailScreen(
          drama: _drama,
          repository: repository,
          store: store,
        ),
      ),
    );
    await frames(tester);
    // 简介页会自动拉「相关推荐」（related_dramas.dart），它走的也是
    // repository.catalog：清掉这批自动请求，下面的断言才只看用户点击产生的。
    repository.requests.clear();
    repository.queries.clear();
    return repository;
  }

  testWidgets('简介页标签可点，跳站源同名关键词结果页', (tester) async {
    final repository = await pumpDetail(tester);
    expect(repository.requests, isEmpty);
    expect(find.text('都市'), findsOneWidget);

    await tester.tap(find.text('都市'));
    await frames(tester);

    expect(find.byType(RelatedCatalogScreen), findsOneWidget);
    expect(repository.requests, <String>['dongpiandi']);
    // 标签走关键词搜索（站点目录的 kind 只接受 content_kind 原文）。
    expect(repository.queries, <String>['都市']);
  });

  testWidgets('简介页分类可点，走 content_kind 而非关键词', (tester) async {
    final repository = await pumpDetail(tester);

    await tester.tap(find.text('短剧'));
    await frames(tester);

    expect(find.byType(RelatedCatalogScreen), findsOneWidget);
    expect(repository.requests, <String>['dongpiandi']);
    // 「短剧」是中文标签，站点要的是 short_drama；落到 category 即不再搜中文。
    expect(repository.queries, isEmpty);
  });

  testWidgets('简介页站源名可点，不带任何筛选', (tester) async {
    final repository = await pumpDetail(tester);

    await tester.tap(find.text('真果·鉴'));
    await frames(tester);

    expect(find.byType(RelatedCatalogScreen), findsOneWidget);
    expect(repository.requests, <String>['dongpiandi']);
    expect(repository.queries, isEmpty);
  });

  testWidgets('结果页里点条目进它的简介页', (tester) async {
    final repository = await pumpDetail(tester);
    await tester.tap(find.text('都市'));
    await frames(tester);
    expect(find.byType(RelatedCatalogScreen), findsOneWidget);

    final target = find.text('第1页短剧');
    expect(target, findsWidgets);
    await tester.tap(target.first);
    await frames(tester);
    expect(find.byType(DetailScreen), findsWidgets);
  });
}
