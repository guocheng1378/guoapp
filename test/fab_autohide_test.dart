import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 每页 40 部：默认 fixture 每页 3 部内容不足一屏，
/// clamping 物理下滚动位置恒 0，回顶钮永远不浮现。
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
  testWidgets('回顶钮停止滚动 2s 后自动隐藏，再次滚动立即重现', (tester) async {
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

    double opacity() => tester
        .widget<AnimatedOpacity>(find.byKey(const ValueKey('home-fab-opacity')))
        .opacity;

    // 停在顶部：不显示。
    expect(opacity(), 0);

    // 滚出首屏：浮现。
    final list = find.byType(CustomScrollView);
    await tester.drag(list, const Offset(0, -1200));
    await tester.pumpAndSettle();
    expect(opacity(), 1);

    // 停止滚动 2s：自动隐藏（micro 透明过渡 settle 到 0）。
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();
    expect(opacity(), 0);

    // 再次滚动：立即重现；静默 1.5s 时保持显示。
    await tester.drag(list, const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(opacity(), 1);
    await tester.pump(const Duration(seconds: 1, milliseconds: 500));
    expect(opacity(), 1);

    // 静默满 2s：再次隐藏。
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(opacity(), 0);
  });
}
