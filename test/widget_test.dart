import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  Future<LocalStore> store() async {
    SharedPreferences.setMockInitialValues({});
    return LocalStore(await SharedPreferences.getInstance());
  }

  for (final size in [const Size(390, 844), const Size(1280, 800)]) {
    testWidgets('catalog, VIP filter and fresh details at $size', (
      tester,
    ) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FixtureRepository();
      final local = await store();
      // 站源菜单按三分类组织：只开红果与黄豆，让两类都进入菜单且菜单简短。
      await local.setSourceSwitches({
        for (final site in SourceSite.values)
          site.id: site.id == 'hongguo' || site.id == 'huangdou',
      });
      await tester.pumpWidget(DuanjuApp(repository: repository, store: local));
      await tester.pumpAndSettle();
      expect(find.byTooltip('VIP：隐藏'), findsNothing);
      // 轮播大卡与网格 tile 各渲染一份剧名。
      expect(find.text('测试短剧'), findsWidgets);
      if (allSourcesEnabled) {
        // 点按菜单只列当前类源；跨类切源走长按三分类菜单。
        await tester.longPress(find.byKey(const ValueKey('source-switch')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('黄果类'));
        await tester.pumpAndSettle();
        expect(find.text('会员测试剧'), findsNothing);
        expect(find.byTooltip('VIP：隐藏'), findsOneWidget);
        await tester.tap(find.byTooltip('VIP：隐藏'));
        await tester.pumpAndSettle();
        expect(find.byTooltip('VIP：显示'), findsOneWidget);
        expect(find.text('会员测试剧'), findsOneWidget);
        await tester.tap(find.byTooltip('VIP：显示'));
        await tester.pumpAndSettle();
      } else {
        expect(find.text('黄豆'), findsNothing);
      }
      expect(find.text('会员测试剧'), findsNothing);
      await tester.tap(find.text('测试短剧').first);
      await tester.pumpAndSettle();
      expect(repository.detailCalls, 1);
      expect(find.byKey(const ValueKey('episode-2')), findsOneWidget);
      await tester.tap(find.byTooltip('加入追剧'));
      await tester.pumpAndSettle();
      expect(local.isFavorite(FixtureRepository.free.id), isTrue);
      for (final episode in [1, 2]) {
        await local.saveWatch(
          WatchEntry(
            drama: FixtureRepository.free,
            episode: episode,
            position: 18.5,
            duration: 90,
            updatedAt: DateTime.now(),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('继续第 $episode 集'), findsOneWidget);
        for (final number in [1, 2]) {
          final button = tester.widget<RemoteEpisodeButton>(
            find.byKey(ValueKey('episode-$number')),
          );
          expect(button.current, number == episode);
        }
      }
      await local.clearHistory();
      await tester.pumpAndSettle();
      expect(find.text('立即播放'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('failed catalog can be retried', (tester) async {
    final repository = FixtureRepository()..fail = true;
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('暂时无法加载'), findsOneWidget);
    repository.fail = false;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsWidgets);
  });

  testWidgets('fresh disk catalog skips the network and resumes pagination', (
    tester,
  ) async {
    final repository = FixtureRepository();
    repository.cachedPages['hongguo'] = CatalogPage(
      [
        FixtureRepository.free,
        for (var index = 0; index < 30; index++)
          Drama(
            id: 'hongguo:cached-$index',
            source: 'hongguo',
            title: '缓存短剧$index',
            episodes: 1,
            category: '合成数据',
          ),
      ],
      fresh: true,
      page: 3,
      hasMore: true,
    );
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsWidgets);
    expect(repository.requests, isEmpty);
    final scrollable = find.byType(CustomScrollView);
    for (var i = 0; i < 4 && repository.pages.isEmpty; i++) {
      await tester.drag(scrollable, const Offset(0, -900));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
    }
    await tester.pumpAndSettle();
    expect(repository.pages, [4]);
    // 回到顶部（深处下拉是普通滚动，不触发刷新指示器）。
    // 首条剧现仅存在于顶部轮播卡（网格已去重），故直接大位移上拖回顶。
    await tester.drag(scrollable, const Offset(0, 8000));
    await tester.pumpAndSettle();
    // 刷新入口为内容区下拉刷新（菜单条目已移除）。
    await tester.drag(scrollable, const Offset(0, 300));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(repository.pages, [4, 1]);
    expect(repository.forced, [false, true]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('stale disk catalog remains usable when refresh fails', (
    tester,
  ) async {
    final repository = FixtureRepository()..fail = true;
    repository.cachedPages['hongguo'] = CatalogPage([FixtureRepository.free]);
    await tester.pumpWidget(
      DuanjuApp(repository: repository, store: await store()),
    );
    await tester.pumpAndSettle();
    expect(find.text('测试短剧'), findsWidgets);
    expect(find.text('合成网络错误'), findsNothing);
    expect(find.text('暂时无法加载'), findsNothing);
    expect(repository.requests, ['hongguo']);
    expect(tester.takeException(), isNull);
  });

  test('watch progress and favorites survive a new store', () async {
    final local = await store();
    await local.saveWatch(
      WatchEntry(
        drama: FixtureRepository.free,
        episode: 2,
        position: 18.5,
        duration: 90,
        updatedAt: DateTime.now(),
      ),
    );
    await local.toggleFavorite(FixtureRepository.free);
    final restored = LocalStore(local.preferences);
    expect(restored.watched(FixtureRepository.free.id)?.position, 18.5);
    expect(restored.watched(FixtureRepository.free.id)?.episode, 2);
    expect(restored.isFavorite(FixtureRepository.free.id), isTrue);
  });

  testWidgets('long-press source island opens the three-category picker', (
    tester,
  ) async {
    final repository = FixtureRepository();
    final local = await store();
    // 全开源让三类都非空（默认变体受限源集只有短剧类，无类可选不弹菜单）。
    await local.setSourceSwitches({
      for (final site in SourceSite.values) site.id: true,
    });
    await tester.pumpWidget(DuanjuApp(repository: repository, store: local));
    await tester.pumpAndSettle();
    expect(find.text('短剧类'), findsNothing);
    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    if (allSourcesEnabled) {
      // 长按弹出三分类选择菜单。
      expect(find.text('短剧类'), findsOneWidget);
      expect(find.text('视频类'), findsOneWidget);
      expect(find.text('黄果类'), findsOneWidget);
      // 选黄果类 -> 切到该类第一个源（黄豆），VIP 过滤入口出现。
      await tester.tap(find.text('黄果类'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('VIP：隐藏'), findsOneWidget);
    } else {
      // 默认变体单类：长按不弹类选择菜单。
      expect(find.text('短剧类'), findsNothing);
      expect(find.text('黄果类'), findsNothing);
    }
  });

  testWidgets('tap source island lists only the current category sources', (
    tester,
  ) async {
    final repository = FixtureRepository();
    final local = await store();
    // 全开源：当前源红果属短剧类，点按菜单只列该类源。
    await local.setSourceSwitches({
      for (final site in SourceSite.values) site.id: true,
    });
    await tester.pumpWidget(DuanjuApp(repository: repository, store: local));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    if (allSourcesEnabled) {
      // 菜单只含当前类：header「短剧类」出现，其他类名与黄果类源不出现。
      expect(find.text('短剧类'), findsOneWidget);
      expect(find.text('视频类'), findsNothing);
      expect(find.text('黄果类'), findsNothing);
      expect(find.text('黄豆'), findsNothing);
    } else {
      // 默认变体单源：不弹站源菜单。
      expect(find.text('短剧类'), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });
}

