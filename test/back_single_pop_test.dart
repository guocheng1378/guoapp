import 'package:duanju_app/app_theme.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

// 上游 9096557：Android 返回键会同时以 goBack 键事件 + 系统 popRoute 两条
// 通道到达，两边各弹一层就成了「一次返回退两级」。本仓库口径：返回键只走
// popRoute，键绑定只留 Esc。（flutter_test 没有 GoBack 的物理键映射，
// 所以这里断言绑定表，再单独验 popRoute 只弹一层。）

const _drama = Drama(
  id: 'hongguo:301',
  source: 'hongguo',
  title: '返回键测试剧',
  episodes: 2,
  contentKind: 'long',
);

class _Host extends StatelessWidget {
  const _Host({required this.store});

  final LocalStore store;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => DetailScreen(
                drama: _drama,
                repository: FixtureRepository(),
                store: store,
              ),
            ),
          ),
          child: const Text('打开简介页'),
        ),
      ),
    );
  }
}

void main() {
  testWidgets('简介页只绑定 Esc，返回键交给系统 popRoute 且只弹一层', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(<String, Object>{'forceLogin': false});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);

    await tester.pumpWidget(
      MaterialApp(theme: AppTheme.light, home: _Host(store: store)),
    );
    await tester.tap(find.text('打开简介页'));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsOneWidget);

    final activators = tester
        .widgetList<CallbackShortcuts>(
          find.descendant(
            of: find.byType(DetailScreen),
            matching: find.byType(CallbackShortcuts),
          ),
        )
        .expand((widget) => widget.bindings.keys)
        .whereType<SingleActivator>();
    expect(
      activators.any((a) => a.trigger == LogicalKeyboardKey.goBack),
      isFalse,
      reason: 'goBack 键绑定会让返回键与 popRoute 各弹一层',
    );
    expect(
      activators.any((a) => a.trigger == LogicalKeyboardKey.escape),
      isTrue,
      reason: 'Esc 仍应保留（桌面/遥控键盘退出）',
    );

    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsNothing);
    expect(find.text('打开简介页'), findsOneWidget);
  });
}
