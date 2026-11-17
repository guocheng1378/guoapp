import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/player_status.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('网速与时钟文案', () {
    expect(formatNetworkSpeed(0), '0 KB/s');
    expect(formatNetworkSpeed(512 * 1024), '512 KB/s');
    expect(formatNetworkSpeed(1024 * 1024), '1.0 MB/s');
    expect(formatNetworkSpeed((2.46 * 1024 * 1024).round()), '2.5 MB/s');

    expect(formatClock(DateTime(2026, 11, 14, 9, 5)), '09:05');
    expect(formatClock(DateTime(2026, 11, 14, 23, 59)), '23:59');
  });

  testWidgets('网速为 0 时不占位，有读数才显示', (tester) async {
    var speed = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: NetworkSpeedText(read: () async => speed)),
      ),
    );
    await tester.pump();
    expect(find.textContaining('KB/s'), findsNothing);

    speed = 2048;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.text('2 KB/s'), findsOneWidget);

    // 归零后收起（暂停/缓冲中不该留一个 0 KB/s）
    speed = 0;
    await tester.pump(const Duration(seconds: 1));
    await tester.pump();
    expect(find.textContaining('KB/s'), findsNothing);
  });

  test('播放页网速/时间开关默认开，关掉后落盘', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);

    expect(store.showNetworkSpeed, isTrue);
    expect(store.showClock, isTrue);

    await store.setShowNetworkSpeed(false);
    await store.setShowClock(false);
    expect(store.showNetworkSpeed, isFalse);
    expect(store.showClock, isFalse);

    await store.setShowClock(true);
    expect(store.showClock, isTrue);
  });

  testWidgets('时钟按注入时间渲染并跨分钟刷新', (tester) async {
    var now = DateTime(2026, 11, 14, 21, 7);
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: ClockText(now: () => now))),
    );
    expect(find.text('21:07'), findsOneWidget);

    now = DateTime(2026, 11, 14, 21, 8);
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('21:08'), findsOneWidget);
  });
}
