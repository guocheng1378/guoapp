import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/settings_screen.dart';
import 'package:duanju_app/ui_scale.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> localStore([Map<String, Object> initial = const {}]) async {
    SharedPreferences.setMockInitialValues(initial);
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);
  }

  const switchKey = ValueKey('dongpiandi-official-only');

  testWidgets('只播官方线路开关同时落到本地与核心', (tester) async {
    phone(tester);
    final store = await localStore();
    final repository = FixtureRepository();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: SettingsScreen(repository: repository, store: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(store.dongpiandiOfficialOnly, isFalse);

    await tester.scrollUntilVisible(find.byKey(switchKey), 240);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(switchKey));
    await tester.pumpAndSettle();
    expect(store.dongpiandiOfficialOnly, isTrue);
    expect(repository.officialOnlyValues, [true]);
    // 设备级开关要能跨重启保留。
    expect(LocalStore(store.preferences).dongpiandiOfficialOnly, isTrue);

    await tester.tap(find.byKey(switchKey));
    await tester.pumpAndSettle();
    expect(store.dongpiandiOfficialOnly, isFalse);
    expect(repository.officialOnlyValues, [true, false]);
    expect(LocalStore(store.preferences).dongpiandiOfficialOnly, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  test('界面缩放倍率夹到 85%~130% 并跨重启保留', () async {
    addTearDown(() => UiScale.current.value = 1);
    final store = await localStore();
    expect(store.uiScale, 1);
    await store.setUiScale(1.5);
    expect(store.uiScale, 1.3);
    await store.setUiScale(0.1);
    expect(store.uiScale, 0.85);
    await store.setUiScale(1.15);
    expect(store.uiScale, 1.15);

    // 重启：新实例读盘并把倍率灌进全局通知器。
    final reloaded = LocalStore(store.preferences);
    addTearDown(reloaded.dispose);
    expect(reloaded.uiScale, 1.15);
    expect(UiScale.current.value, 1.15);
  });

  testWidgets('界面缩放滑块拖动即时预览、松手落盘', (tester) async {
    phone(tester);
    addTearDown(() => UiScale.current.value = 1);
    final store = await localStore();
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pumpAndSettle();
    final slider = find.byKey(const ValueKey('ui-scale-slider'));
    await tester.scrollUntilVisible(slider, 240);
    await tester.pumpAndSettle();
    expect(store.uiScale, 1.0);
    expect(UiScale.current.value, 1.0);

    // 向右拖 = 放大；预览态（内存）与落盘（store）同时生效。
    await tester.drag(slider, const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(UiScale.current.value, greaterThan(1.0));
    expect(store.uiScale, greaterThan(1.0));
    expect(store.uiScale, UiScale.current.value);
    expect(LocalStore(store.preferences).uiScale, store.uiScale);

    // 重置回 100%（重置按钮在标题行，可能被滚出视口，先让它可见）。
    final reset = find.byKey(const ValueKey('ui-scale-reset'));
    await tester.ensureVisible(reset);
    await tester.pumpAndSettle();
    await tester.tap(reset);
    await tester.pumpAndSettle();
    expect(UiScale.current.value, 1.0);
    expect(store.uiScale, 1.0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('重启后开关回显已保存的只播官方线路选择', (tester) async {
    phone(tester);
    final seed = await localStore();
    await seed.setDongpiandiOfficialOnly(true);

    final store = LocalStore(seed.preferences);
    addTearDown(store.dispose);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.light,
        home: SettingsScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.byKey(switchKey), 240);
    await tester.pumpAndSettle();
    expect(
      tester.widget<SwitchListTile>(find.byKey(switchKey)).value,
      isTrue,
    );
    expect(find.textContaining('没有官方线路的集会提示不可播'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
