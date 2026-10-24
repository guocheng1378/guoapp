import 'dart:async';

import 'package:duanju_app/search_input.dart';
import 'package:duanju_app/search_suggestion.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'search suggestions debounce, highlight, select and suppress stale results',
    (tester) async {
      final controller = TextEditingController();
      final calls = <String>[], searches = <String>[];
      final first = Completer<List<SearchSuggestion>>();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(20),
              child: SearchInput(
                controller: controller,
                hint: '搜索',
                onSearch: searches.add,
                suggestions: (query) async {
                  calls.add(query);
                  return query == '永'
                      ? first.future
                      : const [
                          SearchSuggestion(
                            label: '永世长青',
                            subtitle: '2024 · 短剧',
                          ),
                        ];
                },
              ),
            ),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), '永');
      await tester.pump(const Duration(milliseconds: 299));
      expect(calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(calls, ['永']);
      await tester.enterText(find.byType(TextField), '永世');
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      first.complete(const [SearchSuggestion(label: '旧候选')]);
      await tester.pumpAndSettle();
      expect(find.text('旧候选'), findsNothing);
      final item = find.byKey(const ValueKey('search-suggestion-0'));
      expect(item, findsOneWidget);
      final text = tester.widget<Text>(
        find.descendant(of: item, matching: find.byType(Text)).first,
      );
      expect(text.textSpan!.toPlainText(), '永世长青');
      // 副标题（年份·类型）随建议渲染
      expect(
        find.descendant(of: item, matching: find.text('2024 · 短剧')),
        findsOneWidget,
      );
      await tester.tap(item);
      await tester.pumpAndSettle();
      expect(searches, ['永世长青']);
      expect(controller.text, '永世长青');
      expect(item, findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.dispose();
    },
  );

  testWidgets('direct-playable suggestion routes to rich callback', (
    tester,
  ) async {
    final controller = TextEditingController();
    final searches = <String>[];
    final selected = <SearchSuggestion>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(20),
            child: SearchInput(
              controller: controller,
              hint: '搜索',
              onSearch: searches.add,
              onSuggestionSelected: selected.add,
              suggestions: (_) async => const [
                SearchSuggestion(
                  label: '嫁金钗',
                  intent: 'play',
                  variantId: 'av_5dhMc',
                  directPlayable: true,
                ),
                SearchSuggestion(
                  label: '总裁复仇 电影',
                  intent: 'filter',
                  prompt: '总裁复仇 电影',
                ),
              ],
            ),
          ),
        ),
      ),
    );
    // 普通建议：填词搜索
    await tester.enterText(find.byType(TextField), '总裁');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-suggestion-1')));
    await tester.pumpAndSettle();
    expect(searches, ['总裁复仇 电影']);
    expect(selected, isEmpty);
    // 直达建议：走富回调，不进搜索
    await tester.enterText(find.byType(TextField), '嫁金');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('search-suggestion-0')));
    await tester.pumpAndSettle();
    expect(selected, hasLength(1));
    expect(selected.single.variantId, 'av_5dhMc');
    expect(searches, ['总裁复仇 电影']);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });

  testWidgets('suggestion failure still allows a manual search and clearing', (
    tester,
  ) async {
    final controller = TextEditingController();
    final searches = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SearchInput(
            controller: controller,
            hint: '搜索',
            onSearch: searches.add,
            suggestions: (_) async => throw StateError('offline'),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), '重生');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('搜索'));
    expect(searches, ['重生']);
    await tester.tap(find.byTooltip('清空搜索'));
    await tester.pumpAndSettle();
    expect(controller.text, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
  });
}
