import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  Future<LocalStore> create() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  test('groupSources 记住每个分组上次选中的源并随快照持久化', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    addTearDown(store.dispose);

    expect(store.groupSources, isEmpty);
    expect(store.sourceForGroup('cat-video'), isNull);

    await store.rememberGroupSource('cat-video', 'yingshigongchang');
    await store.rememberGroupSource('cat-short', 'hongguo');
    expect(store.groupSources, {
      'cat-video': 'yingshigongchang',
      'cat-short': 'hongguo',
    });
    // 单源变体里影视工厂不在白名单 → 记忆不生效，调用方回落该组首源。
    if (allSourcesEnabled) {
      expect(store.sourceForGroup('cat-video'), 'yingshigongchang');
    } else {
      expect(store.sourceForGroup('cat-video'), isNull);
    }

    // 重新构造一个 store（模拟杀进程重启）：记忆来自落盘快照。
    final reloaded = LocalStore(preferences);
    addTearDown(reloaded.dispose);
    expect(reloaded.groupSources['cat-short'], 'hongguo');
    expect(reloaded.groupSources['cat-video'], 'yingshigongchang');
  });

  test('空分组 id 不写盘（不能污染记忆表）', () async {
    final store = await create();
    await store.rememberGroupSource('', 'hongguo');
    expect(store.groupSources, isEmpty);
  });

  testWidgets('切回分组时回到该组上次用的源', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = await create();
    await store.setSourceSwitches({
      for (final site in SourceSite.values) site.id: true,
    });
    await store.setRestrictedUnlocked(true);
    await tester.pumpWidget(
      DuanjuApp(repository: FixtureRepository(), store: store),
    );
    await tester.pumpAndSettle();

    Finder islandText(String text) => find.descendant(
      of: find.byKey(const ValueKey('source-switch')),
      matching: find.text(text),
    );

    // 单源变体只有一个分组，没有「切分组」可言。
    if (!allSourcesEnabled) {
      expect(find.text('视频类'), findsNothing);
      return;
    }

    // 1) 长按切到视频类 → 落到该组首源（真果·鉴）。
    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频类'));
    await tester.pumpAndSettle();
    expect(islandText('真果·鉴'), findsOneWidget);

    // 2) 点按站源岛在组内换到「影视工厂」——这一步必须被记住。
    await tester.tap(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('影视工厂'));
    await tester.pumpAndSettle();
    expect(islandText('影视工厂'), findsOneWidget);

    // 3) 切到短剧类，再切回视频类：应回到「影视工厂」而非组首源。
    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('短剧类'));
    await tester.pumpAndSettle();
    expect(islandText('红果'), findsOneWidget);

    await tester.longPress(find.byKey(const ValueKey('source-switch')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('视频类'));
    await tester.pumpAndSettle();
    expect(islandText('影视工厂'), findsOneWidget);
    expect(islandText('真果·鉴'), findsNothing);
    expect(store.groupSources['cat-video'], 'yingshigongchang');
    expect(tester.takeException(), isNull);
  });
}
