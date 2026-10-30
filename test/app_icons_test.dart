import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/app_icons.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 播放器专用实心图标（player-*）：独立于公共线性语言，仅控制层使用。
  // 兜底断言资产存在 + 格式合法，避免「图标消失」式静默回归。
  const assets = <String>[
    AppIcons.playerPlay,
    AppIcons.playerPause,
    AppIcons.playerLock,
    AppIcons.playerLockOpen,
    AppIcons.playerCast,
    AppIcons.playerCastConnected,
  ];

  group('播放器专用图标资产（player-*）', () {
    for (final name in assets) {
      test('$name.svg 资产存在且为合法 24 网格 SVG', () async {
        final content = await rootBundle.loadString('assets/icons/$name.svg');
        expect(content, contains('<svg'), reason: '缺少 <svg 根元素');
        expect(
          content,
          contains('viewBox="0 0 24 24"'),
          reason: 'viewBox 应为 0 0 24 24',
        );
      });

      testWidgets('$name 可被 SvgPicture.asset 正常渲染', (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: SvgPicture.asset(
                'assets/icons/$name.svg',
                width: 24,
                height: 24,
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: 'SVG 解析/加载异常');
      });
    }
  });
}
