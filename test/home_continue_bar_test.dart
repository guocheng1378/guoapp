import 'dart:async';

import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_launch_screen.dart';
import 'package:duanju_app/player_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

/// detail 永挂起：首页预取或 tap 薄壳的 detail 都拿不到结果——
/// 一旦首次 detail 成功就会进 core_bridge 的 30min 缓存，tap 后
/// PlaybackLaunchScreen 命中缓存直接 mount PlayerScreen（测试宿主无
/// MediaKit，Player() 构造即抛 ensureInitialized）。挂起则薄壳停在
/// 转圈加载态，缓存永不命中。条渲染只依赖 store.history，不受影响。
class _PendingDetailRepository extends LibraryFeatureRepository {
  @override
  Future<DramaDetail> detail(Drama drama) =>
      Completer<DramaDetail>().future;
}

void main() {
  const first = LibraryFeatureRepository.first;

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

  WatchEntry watch(Drama drama) => WatchEntry(
    drama: drama,
    episode: 1,
    position: 12,
    duration: 60,
    updatedAt: DateTime.utc(2026, 9, 21),
  );

  Future<void> mountHome(
    WidgetTester tester,
    LocalStore store, {
    LibraryFeatureRepository? repository,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            repository: repository ?? LibraryFeatureRepository(),
            store: store,
          ),
        ),
      ),
    );
  }

  testWidgets(
    'continue watching bar shows the latest unfinished entry',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await create();
      await store.saveWatch(watch(first));
      await mountHome(tester, store);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-continue-watching')),
        findsOneWidget,
      );
      expect(find.textContaining('合成一号'), findsWidgets);
    },
  );

  testWidgets(
    'tapping the bar opens the playback launch screen for the entry',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await create();
      await store.saveWatch(watch(first));
      await mountHome(tester, store, repository: _PendingDetailRepository());
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-continue-watching')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('home-continue-watching')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(PlaybackLaunchScreen), findsOneWidget);
      // detail 挂起中：薄壳应停在转圈加载态，绝不 mount PlayerScreen。
      expect(find.byType(PlayerScreen), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing the bar hides it for the rest of the session',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await create();
      await store.saveWatch(watch(first));
      await mountHome(tester, store);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('不再提醒'));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-continue-watching')),
        findsNothing,
      );
    },
  );

  testWidgets(
    'the bar auto-hides after a few seconds without interaction',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final store = await create();
      await store.saveWatch(watch(first));
      await mountHome(tester, store);
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('home-continue-watching')),
        findsOneWidget,
      );

      // 出现后 8 秒无操作：自动收起，本会话不再出现（postFrame 才起算，
      // 冷启动 history 异步就绪不会把倒计时耗在条目出现之前）。
      await tester.pump(const Duration(seconds: 8));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('home-continue-watching')),
        findsNothing,
      );
    },
  );
}
