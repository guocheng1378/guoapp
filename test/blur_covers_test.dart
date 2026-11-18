import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';
import 'library_feature_fixtures.dart';

void main() {
  testWidgets('blurred cover wraps only the poster in a blur filter', (
    tester,
  ) async {
    final repository = FixtureRepository();

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 120,
            height: 180,
            child: DramaCover(
              drama: FixtureRepository.free,
              repository: repository,
              blurred: true,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsOneWidget);

    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 120,
            height: 180,
            child: DramaCover(
              drama: FixtureRepository.free,
              repository: repository,
            ),
          ),
        ),
      ),
    );
    expect(find.byType(ImageFiltered), findsNothing);
  });

  test('模糊封面按源记忆，默认不糊，重启后仍按源恢复', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    addTearDown(store.dispose);

    // 顶栏按钮与设置开关已移除：默认不糊，只看按源记忆。
    expect(store.blurCoversFor('hongguo'), isFalse);
    await store.setBlurCoversFor('hongguo', true);
    expect(store.blurCoversFor('hongguo'), isTrue);
    // 每个源各记各的：红果糊着不影响别的源。
    expect(store.blurCoversFor('huangdou'), isFalse);

    await store.setBlurCoversFor('huangdou', true);

    // 重启（新实例读同一份快照）仍按源恢复。
    final reloaded = LocalStore(preferences);
    addTearDown(reloaded.dispose);
    expect(reloaded.blurCoversFor('hongguo'), isTrue);
    expect(reloaded.blurCoversFor('huangdou'), isTrue);

    // 单独关掉红果：只有该源变化。
    await reloaded.setBlurCoversFor('hongguo', false);
    expect(reloaded.blurCoversFor('hongguo'), isFalse);
    expect(reloaded.blurCoversFor('huangdou'), isTrue);
  });

  testWidgets('首页按落盘记忆糊封面，且顶栏不再有眼睛按钮', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    // 首页网格条目来自缓存页：用带预置剧库的仓库，否则一个 DramaTile 都不渲染。
    final repository = LibraryFeatureRepository();

    Widget app() =>
        MaterialApp(home: HomeScreen(repository: repository, store: store));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    // 没记忆时默认不糊。
    expect(find.byType(ImageFiltered), findsNothing);
    // 顶栏眼睛按钮已移除。
    expect(find.byKey(const ValueKey('toggle-blur-covers')), findsNothing);

    // 模拟在「已装模块」页按分组打开模糊：直接写入红果记忆后重建首页。
    await store.setBlurCoversFor('hongguo', true);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
