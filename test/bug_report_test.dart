import 'dart:io';

import 'package:duanju_app/bug_report.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'fixtures.dart';

/// url_launcher 平台桩：让「打开成功/失败」在测试环境确定性可控
/// （真 MethodChannel 在测试壳里行为不确定）。
class _StubLauncher extends UrlLauncherPlatform {
  _StubLauncher(this.result);

  final bool result;
  final List<String> launched = <String>[];

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => result;

  @override
  Future<bool> launch(
    String url, {
    required bool useSafariVC,
    required bool useWebView,
    required bool enableJavaScript,
    required bool enableDomStorage,
    required bool universalLinksOnly,
    required Map<String, String> headers,
    String? webOnlyWindowName,
  }) async {
    launched.add(url);
    return result;
  }
}

void _installLauncher(_StubLauncher launcher) {
  final UrlLauncherPlatform previous = UrlLauncherPlatform.instance;
  UrlLauncherPlatform.instance = launcher;
  addTearDown(() => UrlLauncherPlatform.instance = previous);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // 剪贴板桩：Clipboard.setData 走 SystemChannels.platform，
  // 测试环境必须接管才能断言复制内容（真通道不存在）。
  String? clipboardText;
  setUp(() {
    clipboardText = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        clipboardText = (call.arguments as Map)['text'] as String?;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });
  });

  group('buildBugReport', () {
    test('包含描述/版本/系统/时间信息', () {
      final report = buildBugReport(
        version: '0.2.96+2134',
        description: '播放黑屏\n点开就退回首页',
        television: true,
        now: DateTime(2026, 10, 20, 12, 0, 5),
      );
      expect(report, contains('播放黑屏\n点开就退回首页'));
      expect(report, contains('版本：0.2.96+2134'));
      expect(report, contains('系统：'));
      // television 标记只在 Android 上生效（电视=Android 设备类型），
      // 测试宿主机是 Windows 时走「电脑」分支。
      if (Platform.isAndroid) {
        expect(report, contains('界面：电视'));
      } else {
        expect(report, contains('界面：电脑'));
      }
      expect(report, contains('时间：2026-10-20 12:00:05'));
    });

    test('描述首尾空白被裁剪', () {
      final report = buildBugReport(
        version: '1.0',
        description: '  描述  \n',
        television: false,
      );
      expect(report, contains('问题描述：\n描述\n'));
    });
  });

  group('bugReportTitle', () {
    test('取描述首行', () {
      expect(bugReportTitle('第一行\n第二行'), '第一行');
      expect(bugReportTitle('   单行   '), '单行');
    });

    test('超长首行截断到 40 字符', () {
      final long = '字' * 50;
      final title = bugReportTitle(long);
      expect(title.length, 41);
      expect(title.endsWith('…'), isTrue);
    });

    test('空描述回退默认标题', () {
      expect(bugReportTitle(''), 'Bug 反馈');
      expect(bugReportTitle('  \n '), 'Bug 反馈');
    });
  });

  group('buildBugIssueUri', () {
    test('指向仓库 issues/new 并携带预填参数', () {
      final uri = buildBugIssueUri(title: '播放黑屏', body: '问题描述：\n播放黑屏');
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, '/guocheng1378/guoapp/issues/new');
      expect(uri.queryParameters['title'], '播放黑屏');
      expect(uri.queryParameters['body'], contains('播放黑屏'));
    });
  });

  group('反馈卡片', () {
    Widget host() => MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              key: const ValueKey('open-bug-report'),
              onPressed: () => showBugReportCard(
                context,
                version: '0.2.96+2134',
                television: false,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    Future<void> open(WidgetTester tester) async {
      await tester.pumpWidget(host());
      await tester.tap(find.byKey(const ValueKey('open-bug-report')));
      await tester.pumpAndSettle();
    }

    testWidgets('描述为空时提交不可用', (tester) async {
      await open(tester);
      final button = tester.widget<FilledButton>(
        find.byKey(const ValueKey('bug-report-submit')),
      );
      expect(button.onPressed, isNull);
      final stub = _StubLauncher(true);
      _installLauncher(stub);
      await tester.tap(find.byKey(const ValueKey('bug-report-submit')));
      await tester.pump();
      expect(stub.launched, isEmpty);
    });

    testWidgets('复制反馈内容带描述与版本并出状态提示', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bug-report-field')),
        '播放黑屏',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bug-report-copy')));
      await tester.pump();
      expect(clipboardText, contains('播放黑屏'));
      expect(clipboardText, contains('版本：0.2.96+2134'));
      expect(find.byKey(const ValueKey('bug-report-status')), findsOneWidget);
    });

    testWidgets('提交成功打开预填的 GitHub 页并关闭卡片', (tester) async {
      final stub = _StubLauncher(true);
      _installLauncher(stub);
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bug-report-field')),
        '播放黑屏\n点开就退回首页',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bug-report-submit')));
      await tester.pumpAndSettle();
      expect(stub.launched, hasLength(1));
      final uri = Uri.parse(stub.launched.single);
      expect(uri.host, 'github.com');
      expect(uri.path, '/guocheng1378/guoapp/issues/new');
      expect(uri.queryParameters['title'], '播放黑屏');
      expect(uri.queryParameters['body'], contains('点开就退回首页'));
      expect(uri.queryParameters['body'], contains('版本：0.2.96+2134'));
      expect(find.byKey(const ValueKey('bug-report-field')), findsNothing);
    });

    testWidgets('提交失败降级为复制并保留卡片', (tester) async {
      final stub = _StubLauncher(false);
      _installLauncher(stub);
      await open(tester);
      await tester.enterText(
        find.byKey(const ValueKey('bug-report-field')),
        '播放黑屏',
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('bug-report-submit')));
      await tester.pumpAndSettle();
      expect(stub.launched, hasLength(1));
      expect(clipboardText, contains('播放黑屏'));
      expect(find.textContaining('无法打开浏览器'), findsOneWidget);
      expect(find.byKey(const ValueKey('bug-report-field')), findsOneWidget);
    });
  });

  testWidgets('设置页「反馈 Bug」入口打开卡片并可用（手机端）', (tester) async {
    final stub = _StubLauncher(true);
    _installLauncher(stub);
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.reset);

    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      DuanjuApp(repository: FixtureRepository(), store: store),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('bottom-nav-1')));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设置与备份'));
    await tester.pumpAndSettle();

    expect(find.text('反馈 Bug'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bug-report-setting')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bug-report-field')), findsOneWidget);

    // 版本号来自 AppLayout.versionOf（DuanjuApp 默认回退 appVersion）。
    await tester.enterText(
      find.byKey(const ValueKey('bug-report-field')),
      '设置页文字重叠',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('bug-report-copy')));
    await tester.pump();
    expect(clipboardText, contains('设置页文字重叠'));
    expect(clipboardText, contains('版本：'));

    await tester.tap(find.byKey(const ValueKey('bug-report-submit')));
    await tester.pumpAndSettle();
    expect(stub.launched, hasLength(1));
    expect(
      Uri.parse(stub.launched.single).queryParameters['body'],
      contains('设置页文字重叠'),
    );
    expect(find.byKey(const ValueKey('bug-report-field')), findsNothing);
  });
}
