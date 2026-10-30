import 'dart:async';

import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_launch_screen.dart';
import 'package:duanju_app/search_input.dart';
import 'package:duanju_app/search_suggestion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

/// 只留一部剧 + detail 永挂起：搜索态下剧卡在视口内可直接点中，
/// 点完停在薄壳转圈态（测试宿主无 MediaKit，Player() 构造即抛）。
class _SinglePendingRepository extends LibraryFeatureRepository {
  _SinglePendingRepository() {
    cachedPages['hongguo'] = CatalogPage([
      LibraryFeatureRepository.first,
    ], fresh: true, page: 1, hasMore: false);
  }

  @override
  Future<DramaDetail> detail(Drama drama) => Completer<DramaDetail>().future;
}

void main() {
  Future<LocalStore> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await store.setSource('hongguo');
    addTearDown(store.dispose);
    return store;
  }

  testWidgets('tapping outside the search box hides the keyboard', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SearchInput(
                controller: controller,
                hint: '搜索',
                autofocus: true,
                onSearch: (_) {},
              ),
              TextButton(onPressed: () {}, child: const Text('外部区域')),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '合成');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    // 点在输入框之外（剧卡的等效位置）：当帧释放焦点并收起键盘。
    await tester.tap(find.text('外部区域'));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('opening a drama from search results dismisses the keyboard', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await create();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            repository: _SinglePendingRepository(),
            store: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '合成');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);

    await tester.tap(find.byKey(const ValueKey('hongguo:one')));
    // detail 挂起：薄壳停在转圈，用固定 pump，别 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.byType(PlaybackLaunchScreen), findsOneWidget);
    // 消费 _load 的 20s 超时看门狗（detail 挂起会让它跨 teardown 悬挂）。
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('点直达建议：键盘收起并进入播放', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final store = await create();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            repository: _DirectSuggestionRepository(),
            store: store,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('toggle-search')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '合成');
    // 300ms 建议防抖 + 结果落地。
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(find.byKey(const ValueKey('search-suggestion-0')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('search-suggestion-0')));
    // detail 挂起：薄壳停在转圈，用固定 pump，别 pumpAndSettle。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.byType(PlaybackLaunchScreen), findsOneWidget);
    // 消费 _load 的 20s 超时看门狗（detail 挂起会让它跨 teardown 悬挂）。
    await tester.pump(const Duration(seconds: 20));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}

/// 建议接口返回直达播放建议（真果·鉴 intent=play 的形态）：
/// detail 永挂起，直达后的薄壳停在转圈态。
class _DirectSuggestionRepository extends LibraryFeatureRepository {
  @override
  Future<List<SearchSuggestion>> suggestions(
    String query, {
    String source = '',
  }) async => const [
    SearchSuggestion(
      label: '合成一号',
      subtitle: '直达播放',
      intent: 'play',
      variantId: 'v-1',
      directPlayable: true,
    ),
  ];

  @override
  Future<DramaDetail> detail(Drama drama) => Completer<DramaDetail>().future;
}
