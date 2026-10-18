import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LocalStore> createStore() async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = InMemorySharedPreferencesStore
        .withData(const {});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  testWidgets('解锁密码弹窗在手机端是轻量小卡，输密码可解锁', (tester) async {
    final store = await createStore();
    // PBKDF2 12 万轮跑在真 isolate，FakeAsync 等不到——用 runAsync 走真实异步。
    await tester.runAsync(
      () => store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: const [],
        download: true,
        pin: '123456',
      ),
    );
    store.lock();
    await tester.pumpWidget(
      MaterialApp(home: ProfilesScreen(store: store, locked: true)),
    );
    await tester.pumpAndSettle();

    // 点管理员行 → 弹出密码小卡（新特征文案「输入密码解锁该用户」）。
    await tester.tap(find.text('管理员'));
    await tester.pumpAndSettle();
    expect(find.text('登录 管理员'), findsOneWidget);
    expect(find.text('输入密码解锁该用户'), findsOneWidget);
    expect(find.text('密码'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);

    // 输错密码 → 停留在弹窗。
    await tester.enterText(find.byType(TextField), '000000');
    expect(find.text('密码'), findsOneWidget);

    // 点取消 → 弹窗关闭，锁定状态不变。
    // （输对密码走 switchProfile 会真跑 PBKDF2 isolate，FakeAsync 测不了，
    //  解锁业务由 local_persistence/store 层覆盖。）
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('输入密码解锁该用户'), findsNothing);
    expect(store.locked, isTrue);
  });
}
