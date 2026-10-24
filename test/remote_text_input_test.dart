import 'package:duanju_app/remote_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'remote_test_helpers.dart';

// 电视端输入框遥控交互回归（移植自 Xanerix/guoapp c805425 的
// remote_text_input_test.dart，改用本仓 televisionHost 夹具）：
// 上下键移出搜索框、确认键唤起输入法、返回键收起输入法并移出。
void main() {
  testWidgets('television remote leaves text field and reopens keyboard', (
    tester,
  ) async {
    final above = FocusNode();
    final field = FocusNode();
    final below = FocusNode();
    addTearDown(above.dispose);
    addTearDown(field.dispose);
    addTearDown(below.dispose);
    await tester.pumpWidget(
      televisionHost(
        child: Scaffold(
          body: Column(
            children: [
              TextButton(focusNode: above, onPressed: () {}, child: const Text('上')),
              RemoteTextInput(child: TextField(focusNode: field)),
              TextButton(focusNode: below, onPressed: () {}, child: const Text('下')),
            ],
          ),
        ),
      ),
    );

    Future<void> press(LogicalKeyboardKey key) async {
      await tester.sendKeyEvent(key);
      await tester.pumpAndSettle();
    }

    field.requestFocus();
    await tester.pumpAndSettle();
    expect(field.hasPrimaryFocus, isTrue);

    await press(LogicalKeyboardKey.arrowDown);
    expect(below.hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.arrowUp);
    expect(field.hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.arrowUp);
    expect(above.hasPrimaryFocus, isTrue);
    await press(LogicalKeyboardKey.arrowDown);
    expect(field.hasPrimaryFocus, isTrue);

    tester.testTextInput.hide();
    expect(tester.testTextInput.isVisible, isFalse);
    await press(LogicalKeyboardKey.select);
    expect(field.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isTrue);

    await press(LogicalKeyboardKey.escape);
    expect(below.hasPrimaryFocus, isTrue);
    expect(tester.testTextInput.isVisible, isFalse);
  });

  testWidgets('remote text input passes through on phone layout', (
    tester,
  ) async {
    final field = FocusNode();
    addTearDown(field.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              RemoteTextInput(child: TextField(focusNode: field)),
              TextButton(onPressed: () {}, child: const Text('其他')),
            ],
          ),
        ),
      ),
    );
    field.requestFocus();
    await tester.pumpAndSettle();
    // 非电视模式不拦截按键：方向键不移动焦点，输入法状态由系统默认行为决定。
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    expect(field.hasPrimaryFocus, isTrue);
    expect(find.byType(TextField), findsOneWidget);
  });
}
