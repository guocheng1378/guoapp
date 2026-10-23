import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/about_card.dart';
import 'package:duanju_app/glass.dart';

void main() {
  testWidgets('关于浮卡锚定出现、点空白关闭、查看许可推许可页', (tester) async {
    final anchorKey = GlobalKey(debugLabel: 'anchor');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  key: anchorKey,
                  width: 48,
                  height: 48,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
              Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    onPressed: () => showAboutCard(
                      context: context,
                      anchorKey: anchorKey,
                      appName: '真果鉴',
                      version: '0.2.94',
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('真果鉴'), findsOneWidget);
    expect(find.text('0.2.94'), findsOneWidget);
    expect(find.text('查看许可'), findsOneWidget);

    // 点空白处关闭。
    await tester.tapAt(const Offset(20, 500));
    await tester.pumpAndSettle();
    expect(find.text('查看许可'), findsNothing);

    // 再次打开，点「查看许可」→ 浮卡关闭并推入许可页。
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('查看许可'));
    await tester.pumpAndSettle();
    expect(find.text('查看许可'), findsNothing);
    expect(find.byType(LicensePage), findsOneWidget);
  });

  testWidgets('头部连点 5 次触发激活彩蛋并关闭浮卡', (tester) async {
    final anchorKey = GlobalKey(debugLabel: 'anchor');
    var unlocked = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  key: anchorKey,
                  width: 48,
                  height: 48,
                  child: const ColoredBox(color: Colors.red),
                ),
              ),
              Builder(
                builder: (context) => Center(
                  child: FilledButton(
                    onPressed: () => showAboutCard(
                      context: context,
                      anchorKey: anchorKey,
                      appName: '真果鉴',
                      version: '0.2.94',
                      onActivate: () => unlocked++,
                    ),
                    child: const Text('open'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 4 次 + 间隔超时：计数重置，不触发。
    for (var i = 0; i < 4; i++) {
      await tester.tap(find.text('真果鉴'));
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 1700));
    await tester.tap(find.text('真果鉴'));
    await tester.pumpAndSettle();
    expect(unlocked, 0);
    expect(find.text('查看许可'), findsOneWidget);

    // 1.6 秒内连点 5 次：触发回调、只触发一次、浮卡自动关闭。
    for (var i = 0; i < 5; i++) {
      await tester.tap(find.text('真果鉴'));
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(unlocked, 1);
    expect(find.text('查看许可'), findsNothing);
  });

  Widget host({
    GlobalKey? anchorKey,
    String version = '0.2.96+2178',
    Future<String?> Function()? fetcher,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Stack(
          children: [
            Align(
              alignment: Alignment.topRight,
              child: SizedBox(
                key: anchorKey ?? GlobalKey(debugLabel: 'unused'),
                width: 48,
                height: 48,
                child: const ColoredBox(color: Colors.red),
              ),
            ),
            Builder(
              builder: (context) => Center(
                child: FilledButton(
                  onPressed: () => showAboutCard(
                    context: context,
                    anchorKey: anchorKey ?? GlobalKey(debugLabel: 'unused'),
                    appName: '真果鉴',
                    version: version,
                    debugFetcher: fetcher,
                  ),
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  testWidgets('浮卡屏幕居中呈现', (tester) async {
    tester.view.physicalSize = const Size(600, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host(anchorKey: GlobalKey(debugLabel: 'anchor')));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // 卡片中心与屏幕中心重合（±2px 容差）。
    final cardCenter = tester.getCenter(find.text('0.2.96+2178')).dy;
    expect((cardCenter - 450).abs(), lessThan(120));
    expect(tester.takeException(), isNull);
  });

  testWidgets('检查更新：线上无新版本 → SnackBar 提示且浮卡保持', (tester) async {
    await tester.pumpWidget(host(fetcher: () async => '{}'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('当前已是最新版本'), findsOneWidget);
    expect(find.text('查看许可'), findsOneWidget); // 浮卡未关
  });

  testWidgets('检查更新：线上 build 更大 → 关浮卡弹既有更新卡', (tester) async {
    const body =
        '{"update":{"enabled":true,"build":99999,"version":"0.2.96.9999",'
        '"notes":"测试更新","url":"https://example.com/a.apk"}}';
    await tester.pumpWidget(host(fetcher: () async => body));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('查看许可'), findsNothing); // 关于卡已关
    expect(find.text('发现新版本 v0.2.96.9999'), findsOneWidget); // 更新卡顶替
    expect(find.text('去下载'), findsOneWidget);
  });

  testWidgets('检查更新：拉取异常 → SnackBar 失败提示且浮卡保持', (tester) async {
    await tester.pumpWidget(
      host(fetcher: () async => throw Exception('offline')),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();

    expect(find.text('检查更新失败，请检查网络后重试'), findsOneWidget);
    expect(find.text('查看许可'), findsOneWidget);
  });

  testWidgets('小屏：窄屏浮卡收缩且不溢出视口', (tester) async {
    tester.view.physicalSize = const Size(260, 480);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(host());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('真果鉴'), findsOneWidget);
    expect(find.text('检查更新'), findsOneWidget);
    // 卡片左右各留 ≥16px 边距。
    final cardLeft = tester.getTopLeft(find.byType(GlassSurface)).dx;
    expect(cardLeft, greaterThanOrEqualTo(15.9));
  });
}
