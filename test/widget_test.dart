import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/detail_screen.dart';
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
    testWidgets('catalog and VIP filter at $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final repository = FixtureRepository();
      final local = await store();
      // 站源菜单按三分类组织：只开红果与黄豆，让两类都进入菜单且菜单简短。
      // 黄果类/成人类默认整组隐藏（关于卡彩蛋解锁），本用例验证分组与
      // VIP 过滤逻辑，先解锁再断言。
      await local.setSourceSwitches({
        for (final site in SourceSite.values)
          site.id: site.id == 'hongguo' || site.id == 'huangdou',
      });
      await local.setRestrictedUnlocked(true);
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
      expect(tester.takeException(), isNull);
    });
  }

  // 首页点剧卡现在直进播放器（media_kit 在 widget 测试环境不可用），
  // 详情页覆盖改为直接挂 DetailScreen 验证。
  testWidgets(
    'fresh details, watch progress and favorites on the detail screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final repository = FixtureRepository();
    final local = await store();
    await tester.pumpWidget(
      MaterialApp(
        home: DetailScreen(
          drama: FixtureRepository.free,
          repository: repository,
          store: local,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(repository.detailCalls, 1);
    expect(find.byKey(const ValueKey('episode-2')), findsOneWidget);
    // 追剧入口为「追剧与观看状态」菜单：选「想看」即加入追剧。
    await tester.tap(find.byKey(const ValueKey('follow-status')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('想看').last);
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
      expect(find.text('继续播放 · 第 $episode 集'), findsOneWidget);
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
    // 轮播已改豆瓣选片：无豆瓣榜单 Provider 时静默回退（红果鉴/全源版
    // 一致），首页磁盘缓存路径完全不请求网络。
    expect(repository.requests, isEmpty);
    final scrollable = find.byType(CustomScrollView);
    // 判据是「分页让请求数增长」。
    final knownPages = repository.pages.length;
    for (var i = 0; i < 4 && repository.pages.length == knownPages; i++) {
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
    // 红果鉴仅缓存过期后刷新一次红果目录；全源版另有一次精选轮换源请求。
    expect(
      repository.requests.where((source) => source == 'hongguo'),
      ['hongguo'],
    );
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
      // 未解锁：黄果类/成人类整组隐藏（关于卡连点 5 次才显示）。
      expect(find.text('黄果类'), findsNothing);
      expect(find.text('成人类'), findsNothing);
      await tester.tap(find.text('视频类'));
      await tester.pumpAndSettle();
      // 彩蛋解锁后重开菜单：黄果类可见。
      await local.setRestrictedUnlocked(true);
      await tester.pumpAndSettle();
      await tester.longPress(find.byKey(const ValueKey('source-switch')));
      await tester.pumpAndSettle();
      // 长按弹出三分类选择菜单。
      expect(find.text('短剧类'), findsOneWidget);
      expect(find.text('视频类'), findsOneWidget);
      expect(find.text('黄果类'), findsOneWidget);
      // 选黄果类 -> 切到该类第一个源（黄豆），VIP 过滤入口出现。
      await tester.tap(find.text('黄果类'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('VIP：隐藏'), findsOneWidget);
    } else {
      // 默认变体单类：长按仍弹菜单（末尾固定「电视直播」条目，
      // 见 _pickSourceCategory；守卫自 2171 起移除），但只有一个
      // 分类项，没有类可选择。
      expect(find.text('短剧类'), findsOneWidget);
      expect(find.text('电视直播'), findsOneWidget);
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

