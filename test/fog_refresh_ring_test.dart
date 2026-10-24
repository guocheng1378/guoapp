import 'dart:async';

import 'package:duanju_app/folme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

// 下拉刷新圆环形态锁：宽恒 30（与静止小圆同径），只随下拉进度拉长、
// 顶边钉在 displacement；松手过阈同颗环弹回 30×30，完成原位淡出。
void main() {
  final ring = find.byKey(const Key('fog-refresh-ring'));

  Future<void> pumpHarness(WidgetTester tester, Completer<void> refresh) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FogRefresh(
            displacement: 120,
            onRefresh: () => refresh.future,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 40,
              itemBuilder: (context, i) => ListTile(title: Text('item $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<TestGesture> pull(WidgetTester tester, double dy) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.text('item 4')),
    );
    await gesture.moveBy(Offset(0, dy));
    await tester.pump();
    return gesture;
  }

  testWidgets('下拉时圆环宽度不变只拉长，过阈封顶 76px', (tester) async {
    await pumpHarness(tester, Completer<void>());
    final gesture = await pull(tester, 90);
    // 90px 下拉 → 进度封顶 → 30 + 46 = 76；宽度恒 30。
    expect(tester.getSize(ring).width, 30.0);
    expect(tester.getSize(ring).height, 76.0);
    // 环顶钉在 displacement，锚点不随下拉移动。
    expect(tester.getTopLeft(ring).dy, moreOrLessEquals(120));
    await gesture.up();
    await tester.pump();
  });

  testWidgets('松手过阈弹回 30×30 小圆，完成后原位淡出', (tester) async {
    final refresh = Completer<void>();
    await pumpHarness(tester, refresh);
    final gesture = await pull(tester, 90);
    await gesture.up();
    await tester.pump();
    // 测试环境弹簧直达：同颗环落定 30×30（与静止小圆同径同位）。
    expect(tester.getSize(ring), const Size(30, 30));
    refresh.complete();
    await tester.pump();
    // 收场在帧后微任务里落账，再泵一帧渲染。
    await tester.pump();
    expect(ring, findsNothing);
  });

  testWidgets('不足阈值弹簧弹回并淡出', (tester) async {
    await pumpHarness(tester, Completer<void>());
    final gesture = await pull(tester, 30);
    await gesture.up();
    await tester.pump();
    expect(ring, findsNothing);
  });

  double itemTop(WidgetTester tester) =>
      tester.getTopLeft(find.text('item 0')).dy;

  /// 内容层跟手平移量（内容整体下移距离，环的空隙来源；吸顶层不动）。
  double contentTranslate(WidgetTester tester) =>
      tester
          .widget<Transform>(
            find
                .ancestor(
                  of: find.text('item 0'),
                  matching: find.byWidgetPredicate((w) => w is Transform),
                )
                .first,
          )
          .transform
          .getTranslation()
          .y;

  testWidgets('下拉时界面内容 1:1 跟手平移让位，环在空隙中拉长', (tester) async {
    await pumpHarness(tester, Completer<void>());
    final base = itemTop(tester);
    final gesture = await pull(tester, 40);
    // 40px 下拉 → 内容 1:1 下移 40（纯平移，无缩放无拉伸畸变）。
    expect(itemTop(tester), moreOrLessEquals(base + 40));
    expect(ring, findsOneWidget);
    await gesture.up();
    await tester.pump();
  });

  testWidgets('按住不松手往回拖，内容跟手缩回（不等松手才弹回）', (tester) async {
    await pumpHarness(tester, Completer<void>());
    final base = itemTop(tester);
    final gesture = await pull(tester, 40);
    expect(itemTop(tester), moreOrLessEquals(base + 40));
    // 手指仍按住，往回拖 15px：clamping 物理回拖帧不再报 Overscroll 而
    // 是报 scrollDelta=15 的正常滚动帧（列表同时回滚），平移量应等量
    // 收回 40→25（内容跟手缩回），内容顶=base+25-15。
    await gesture.moveBy(const Offset(0, -15));
    await tester.pump();
    expect(contentTranslate(tester), moreOrLessEquals(25));
    expect(itemTop(tester), moreOrLessEquals(base + 10));
    // 继续回拖凑满 40px：下拉量清零，环随进度归位消失。
    await gesture.moveBy(const Offset(0, -25));
    await tester.pump();
    expect(contentTranslate(tester), moreOrLessEquals(0));
    expect(itemTop(tester), moreOrLessEquals(base - 40));
    // 全程未松手，松手时下拉量已归零 → 不触发刷新、无弹簧残留。
    await gesture.up();
    await tester.pump();
    expect(contentTranslate(tester), moreOrLessEquals(0));
    expect(ring, findsNothing);
  });

  testWidgets('不足阈值松手，界面与环同轨弹回原位', (tester) async {
    await pumpHarness(tester, Completer<void>());
    final base = itemTop(tester);
    final gesture = await pull(tester, 40);
    await gesture.up();
    await tester.pump();
    expect(itemTop(tester), moreOrLessEquals(base));
    expect(ring, findsNothing);
  });

  testWidgets('下拉触发刷新后界面停在让位量，完成后弹回复位', (tester) async {
    final refresh = Completer<void>();
    await pumpHarness(tester, refresh);
    final base = itemTop(tester);
    final gesture = await pull(tester, 90);
    await gesture.up();
    await tester.pump();
    // 让位量 = 环高 30 + 间隙 6：小环悬在内容顶边之上的空隙里不压内容。
    expect(itemTop(tester), moreOrLessEquals(base + 36));
    expect(tester.getSize(ring), const Size(30, 30));
    refresh.complete();
    await tester.pump();
    await tester.pump();
    // 收场：内容与环一起归零复位。
    expect(itemTop(tester), moreOrLessEquals(base));
    expect(ring, findsNothing);
  });

  testWidgets('程序化 show() 内容原地不动，仅环进入刷新态', (tester) async {
    final refresh = Completer<void>();
    await pumpHarness(tester, refresh);
    final base = itemTop(tester);
    tester.state<FogRefreshState>(find.byType(FogRefresh)).show();
    await tester.pump();
    expect(itemTop(tester), moreOrLessEquals(base));
    expect(tester.getSize(ring), const Size(30, 30));
    refresh.complete();
    await tester.pump();
    await tester.pump();
    expect(itemTop(tester), moreOrLessEquals(base));
    expect(ring, findsNothing);
  });

  testWidgets('吸顶层钉在原位：下拉时分组不跟着下来，环落在其下方白区',
      (tester) async {
    const header = Key('pinned-header');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: FogRefresh(
            // 环顶 96 = 吸顶层高 80 + 6 间隙，环落在吸顶层下方白区。
            displacement: 96,
            headerExtent: 80,
            header: Container(key: header, height: 80, color: Colors.white),
            onRefresh: () => Completer<void>().future,
            child: ListView.builder(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: 40,
              itemBuilder: (context, i) => ListTile(title: Text('item $i')),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    final base = itemTop(tester);
    final gesture = await pull(tester, 40);
    // 吸顶层钉在 y=0 不动（真机定调「分组不跟着下来」）。
    expect(tester.getTopLeft(find.byKey(header)).dy, moreOrLessEquals(0));
    // 内容层 1:1 下移 40，吸顶层下方露出 40px 白区。
    expect(itemTop(tester), moreOrLessEquals(base + 40));
    // 环顶 96 > 吸顶层底 80：环悬在白区里，不与分组叠在一起。
    expect(tester.getTopLeft(ring).dy, moreOrLessEquals(96));
    // 继续拉过阈值（64）后松手触发刷新：吸顶层依然不动，内容停在
    // 让位量（36），等刷新做完才回去——分组全程不参与位移。
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(tester.getTopLeft(find.byKey(header)).dy, moreOrLessEquals(0));
    expect(itemTop(tester), moreOrLessEquals(base + 36));
    await tester.pump();
  });
}
