import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
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

  test('blur cover switches gate each other and survive a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);

    expect(store.blurCoversButton, isFalse);
    expect(store.blurCoversOnLaunch, isFalse);

    // 按钮关着时「开屏自动模糊」写进去也不生效（读取侧门控）
    await store.setBlurCoversOnLaunch(true);
    expect(store.blurCoversOnLaunch, isFalse);

    await store.setBlurCoversButton(true);
    expect(store.blurCoversOnLaunch, isTrue);

    await store.setBlurCoversButton(false);
    expect(store.blurCoversOnLaunch, isFalse);

    await store.setBlurCoversButton(true);
    await store.setBlurCoversOnLaunch(false);
    expect(store.blurCoversButton, isTrue);
    expect(store.blurCoversOnLaunch, isFalse);
  });

  test('模糊状态按源记忆，开屏设置改写时清空记忆', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    addTearDown(store.dispose);
    await store.setBlurCoversButton(true);

    // 没点过按钮：跟随开屏设置。
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

    // 改「开屏自动模糊」= 明确表态下次该不该糊，重置所有源的记忆。
    await reloaded.setBlurCoversOnLaunch(true);
    expect(reloaded.blurCoversBySource, isEmpty);
    expect(reloaded.blurCoversFor('hongguo'), isTrue);
    expect(reloaded.blurCoversFor('huangdou'), isTrue);
    await reloaded.setBlurCoversOnLaunch(false);
    expect(reloaded.blurCoversFor('hongguo'), isFalse);
    expect(reloaded.blurCoversFor('huangdou'), isFalse);

    // 按钮总开关关掉时记忆不生效。
    await reloaded.setBlurCoversFor('hongguo', true);
    await reloaded.setBlurCoversButton(false);
    expect(reloaded.blurCoversFor('hongguo'), isFalse);
  });

  testWidgets('首页眼睛按钮切换后重启仍保持模糊', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setBlurCoversButton(true);
    // 首页网格条目来自缓存页：用带预置剧库的仓库，否则一个 DramaTile 都不渲染。
    final repository = LibraryFeatureRepository();

    Widget app() =>
        MaterialApp(home: HomeScreen(repository: repository, store: store));

    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(store.blurCoversFor('hongguo'), isFalse);
    expect(find.byType(ImageFiltered), findsNothing);

    await tester.tap(find.byKey(const ValueKey('toggle-blur-covers')));
    await tester.pumpAndSettle();
    expect(store.blurCoversFor('hongguo'), isTrue);
    expect(find.byType(ImageFiltered), findsWidgets);

    // 模拟重启：重建首页，状态来自该源的落盘记忆而不是开屏设置。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsWidgets);

    // 再点一次关掉，记忆同步关掉。
    await tester.tap(find.byKey(const ValueKey('toggle-blur-covers')));
    await tester.pumpAndSettle();
    expect(store.blurCoversFor('hongguo'), isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('每个源的模糊记忆互不影响', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.setBlurCoversButton(true);
    await store.setSourceSwitches({
      for (final site in SourceSite.values) site.id: true,
    });
    await store.setRestrictedUnlocked(true);
    final repository = LibraryFeatureRepository();
    await tester.pumpWidget(
      MaterialApp(home: HomeScreen(repository: repository, store: store)),
    );
    await tester.pumpAndSettle();

    // 红果糊上。
    await tester.tap(find.byKey(const ValueKey('toggle-blur-covers')));
    await tester.pumpAndSettle();
    expect(store.blurCoversFor('hongguo'), isTrue);
    expect(find.byType(ImageFiltered), findsWidgets);

    // 单源变体没有第二个源可切，记忆隔离由上面的 store 用例覆盖。
    if (!allSourcesEnabled) return;

    // 切到黄果类（黄豆）：该源没有记忆 → 回落开屏设置（关）= 不糊。
    // 状态以顶栏眼睛按钮的 tooltip 断言（不依赖具体卡片实现）。
    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('黄果类'));
    await tester.pumpAndSettle();
    expect(store.blurCoversFor('huangdou'), isFalse);
    expect(find.byTooltip('模糊封面'), findsOneWidget);
    expect(find.byTooltip('显示封面'), findsNothing);

    // 切回短剧类（红果）：这个源上次是糊着的，回来仍糊。
    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('短剧类'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('显示封面'), findsOneWidget);
    expect(store.blurCoversFor('hongguo'), isTrue);

    await tester.pumpWidget(const SizedBox.shrink());
  });
}
