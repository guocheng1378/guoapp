import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';
import 'remote_test_helpers.dart';

class _FakeClock {
  _FakeClock(this._now);
  DateTime _now;
  DateTime call() => _now;
  void advance(Duration duration) => _now = _now.add(duration);
}

void main() {
  const exitHint = '再按一次返回键退出';

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

  // 拦截 platform 通道：只记录 SystemNavigator.pop（真正的退出调用），
  // 其余出站消息（SystemChrome.set* 等框架自身行为）一律回成功信封——
  // widget test 里无人应答的消息会永久挂起（见 player_portrait_drama_test
  // 的教训），也不能混进断言。
  List<String> spyPlatformChannel(WidgetTester tester) {
    final methods = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.platform.name,
      (data) async {
        if (data != null) {
          final call = const JSONMethodCodec().decodeMethodCall(data);
          if (call.method == 'SystemNavigator.pop') methods.add(call.method);
        }
        return const JSONMethodCodec().encodeSuccessEnvelope(null);
      },
    );
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMessageHandler(SystemChannels.platform.name, null));
    return methods;
  }

  Future<void> mountMobile(
    WidgetTester tester,
    LocalStore store, {
    DateTime Function()? backClock,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HomeScreen(
            repository: LibraryFeatureRepository(),
            store: store,
            backClock: backClock,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('mobile: first back shows the exit hint and stays', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final pops = spyPlatformChannel(tester);
    final store = await create();
    await mountMobile(tester, store);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text(exitHint), findsOneWidget);
    expect(pops, isEmpty);
  });

  testWidgets('mobile: second back within the window exits the app', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final pops = spyPlatformChannel(tester);
    final store = await create();
    await mountMobile(tester, store);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));

    expect(pops, contains('SystemNavigator.pop'));
  });

  testWidgets('mobile: back after the window expires asks again', (
    tester,
  ) async {
    viewport(tester, const Size(390, 844));
    final pops = spyPlatformChannel(tester);
    final clock = _FakeClock(DateTime(2026, 10, 23, 12));
    final store = await create();
    await mountMobile(tester, store, backClock: clock.call);

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text(exitHint), findsOneWidget);

    clock.advance(const Duration(seconds: 3));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 100));

    expect(pops, isEmpty);
    expect(find.text(exitHint), findsOneWidget);
  });

  testWidgets('tv: back keeps in-page behavior without the exit hint', (
    tester,
  ) async {
    viewport(tester, const Size(1280, 720));
    final pops = spyPlatformChannel(tester);
    final store = await create();
    await tester.pumpWidget(
      televisionHost(
        child: HomeScreen(
          repository: LibraryFeatureRepository(),
          store: store,
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 切到「追剧」tab：TV 分支 canPop=false，返回键走 _televisionBack
    // 切回首页，绝不触发退出提示或 SystemNavigator.pop。
    focusRemote(tester, find.byKey(const ValueKey('tv-nav-1')));
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();

    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text(exitHint), findsNothing);
    expect(pops, isEmpty);
  });
}
