import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/folme.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interface_fixtures.dart';

/// 首页加载链路会先拉分类再拉目录；InterfaceRepository 未覆写 categories()
/// 时默认实现不可用，首页加载直接失败、内容区不渲染。这里补最小分类实现。
class ItfRepository extends InterfaceRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
}

void main() {
  Future<LocalStore> localStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void viewport(WidgetTester tester, Size size, [double scale = 1]) {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = scale;
    addTearDown(tester.view.reset);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }

  testWidgets(
    'pull-to-refresh reloads the catalog and surfaces failures',
    (tester) async {
      viewport(tester, const Size(390, 844));
      final repository = ItfRepository();
      await tester.pumpWidget(
        DuanjuApp(repository: repository, store: await localStore()),
      );
      await tester.pumpAndSettle();
      final indicator = find.byType(FogRefresh);
      expect(indicator, findsOneWidget);
      for (final fails in [false, true]) {
        final pending = Completer<CatalogPage>();
        repository.pendingCatalog = pending;
        final requests = repository.requests.length;
        // widget test 的手势链路触发不了刷新胶囊（框架层限制），
        // 改用公开 API show() 驱动同一条 onRefresh 链路。
        tester.state<FogRefreshState>(indicator).show();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(repository.requests.length, greaterThan(requests));
        repository.pendingCatalog = null;
        if (fails) {
          pending.completeError(AppFailure('合成更新失败'));
        } else {
          pending.complete(CatalogPage(repository.dramas('hongguo')));
        }
        await tester.pumpAndSettle();
        // 失败分支 _items 清空仅剩错误横幅（短标题=0 属正常）。
        if (fails) {
          expect(find.text('合成更新失败'), findsOneWidget);
        } else {
          expect(find.text('短标题'), findsWidgets);
        }
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Huangdou exposes the persistent VIP filter and applies it',
    (tester) async {
      // 黄豆是受限源且只存在于全源变体。
      if (!allSourcesEnabled) return;
      viewport(tester, const Size(390, 844));
      final repository = ItfRepository();
      final store = await localStore();
      await store.setSourceEnabled('huangdou', true);
      await store.setSource('huangdou');
      await tester.pumpWidget(DuanjuApp(repository: repository, store: store));
      await tester.pumpAndSettle();

      // hideVip 默认开：会员剧被过滤、胶囊处于隐藏态。
      expect(find.byTooltip('VIP：隐藏'), findsOneWidget);
      expect(find.text('会员合成剧'), findsNothing);
      await tester.tap(find.byTooltip('VIP：隐藏'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('VIP：显示'), findsOneWidget);
      expect(store.hideVip, isFalse);
      // fixture 只有 3 部剧且全被轮播吃掉；轮播 PageView 只构建当前页与
      // 邻页，会员剧排在第 3 张卡——翻到它才能断言内容恢复。
      await tester.drag(
        find.byKey(const ValueKey('home-carousel')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('home-carousel')),
        const Offset(-500, 0),
      );
      await tester.pumpAndSettle();
      expect(find.text('会员合成剧'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
