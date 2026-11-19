import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 每页 40 部，保证滚动位置能超过一屏视口。
class _RichFixture extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async {
    await super.catalog(
      source,
      page: page,
      query: query,
      category: category,
      sort: sort,
      force: force,
    );
    return CatalogPage([
      for (var i = 0; i < 40; i++)
        Drama(
          id: '$source:p$page-$i',
          source: source,
          title: '滚动填充$page-$i',
          episodes: 1,
        ),
    ], page: page, hasMore: false);
  }
}

void main() {
  testWidgets('滚出首屏隐藏底栏并把置顶按钮下移，滚回第一屏恢复', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    SharedPreferences.setMockInitialValues({});
    final local = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      DuanjuApp(repository: _RichFixture(), store: local),
    );
    await tester.pumpAndSettle();

    Offset navOffset() => tester
        .widget<AnimatedSlide>(
          find.byKey(const ValueKey('home-bottom-nav-slide')),
        )
        .offset;
    double? fabBottom() => tester
        .widget<AnimatedPositioned>(
          find.byKey(const ValueKey('home-fab-position')),
        )
        .bottom;
    Duration navDuration() => tester
        .widget<AnimatedSlide>(
          find.byKey(const ValueKey('home-bottom-nav-slide')),
        )
        .duration;
    Duration fabDuration() => tester
        .widget<AnimatedPositioned>(
          find.byKey(const ValueKey('home-fab-position')),
        )
        .duration;

    // 动画参数明确且两者同步（200ms + 同曲线）。
    expect(navDuration(), const Duration(milliseconds: 200));
    expect(fabDuration(), navDuration());
    expect(
      tester
          .widget<AnimatedSlide>(
            find.byKey(const ValueKey('home-bottom-nav-slide')),
          )
          .curve,
      tester
          .widget<AnimatedPositioned>(
            find.byKey(const ValueKey('home-fab-position')),
          )
          .curve,
    );

    // 初始：底栏在原位，置顶按钮在底栏上方（24 + 96）。
    expect(navOffset(), Offset.zero);
    expect(fabBottom(), 24 + 96);

    final list = find.byType(CustomScrollView);
    // 滚过一屏（844）：底栏滑出，置顶按钮下移填补到 24。
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(navOffset(), const Offset(0, 1));
    expect(fabBottom(), 24);

    // 滚回第一屏：底栏恢复，置顶按钮回原位。
    await tester.drag(list, const Offset(0, 1400));
    await tester.pumpAndSettle();
    expect(navOffset(), Offset.zero);
    expect(fabBottom(), 24 + 96);
  });
}
