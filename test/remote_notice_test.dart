import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'package:duanju_app/remote_notice.dart';

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


const RemoteNoticeConfig _announceOnly = RemoteNoticeConfig(
  announcement: RemoteNoticeAnnouncement(
    title: '公告标题',
    message: '公告正文内容',
    button: '我知道了',
  ),
);

const RemoteNoticeConfig _updateOnly = RemoteNoticeConfig(
  update: RemoteNoticeUpdate(
    version: '0.2.97',
    build: 3000,
    notes: '修复与优化',
    url: 'https://example.com/download',
  ),
);

const RemoteNoticeConfig _announceWithImage = RemoteNoticeConfig(
  announcement: RemoteNoticeAnnouncement(
    title: '带图公告',
    message: '看看这张图',
    button: '我知道了',
    image: 'https://example.com/banner.jpg',
  ),
);

RemoteNoticeTrigger _host({
  required String version,
  RemoteNoticeConfig? config,
  RemoteConfigFetcher? fetcher,
}) {
  return RemoteNoticeTrigger(
    version: version,
    debugConfig: config,
    debugFetcher: fetcher,
    child: const Scaffold(body: Center(child: Text('home-body'))),
  );
}

Future<void> _pumpToNotice(WidgetTester tester, Widget host) async {
  await tester.pumpWidget(MaterialApp(home: host));
  // 首帧后 1.5s 触发拉取/弹窗。
  await tester.pump(const Duration(milliseconds: 1600));
  await tester.pumpAndSettle();
}

Widget _contextCapture(WidgetTester tester, void Function(BuildContext) onBuilt) {
  return MaterialApp(
    home: Builder(
      builder: (BuildContext context) {
        onBuilt(context);
        return const Scaffold(body: Text('home-body'));
      },
    ),
  );
}

void main() {
  setUp(resetRemoteNoticeSessionForTest);

  group('RemoteNoticeConfig.tryParse', () {
    test('解析完整配置并忽略未知键', () {
      final String body = jsonEncode(<String, Object?>{
        '_说明': '说明键应被忽略',
        'announcement': <String, Object?>{
          'enabled': true,
          'title': '公告',
          'message': '内容',
          'button': '知道了',
          'link': 'https://a.example',
        },
        'update': <String, Object?>{
          'enabled': true,
          'version': '0.2.97',
          'build': '2130',
          'notes': '说明',
          'url': 'https://r.example',
        },
      });
      final config = RemoteNoticeConfig.tryParse(body);
      expect(config, isNotNull);
      expect(config!.announcement?.title, '公告');
      expect(config.announcement?.message, '内容');
      expect(config.announcement?.button, '知道了');
      expect(config.announcement?.link, 'https://a.example');
      expect(config.update?.version, '0.2.97');
      expect(config.update?.build, 2130);
      expect(config.update?.url, 'https://r.example');
    });

    test('缺省按钮回退「我知道了」', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{
          'enabled': true,
          'title': 'T',
          'message': 'M',
        },
      }));
      expect(config?.announcement?.button, '我知道了');
    });

    test('enabled=false 或 build 非法时丢弃对应段', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{
          'enabled': false,
          'title': 'T',
          'message': 'M',
        },
        'update': <String, Object?>{'enabled': true, 'build': 0},
      }));
      expect(config, isNotNull);
      expect(config!.announcement, isNull);
      expect(config.update, isNull);
    });

    test('空公告段（无标题无正文）不生成', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{'enabled': true},
      }));
      expect(config, isNotNull);
      expect(config!.announcement, isNull);
    });

    test('image 合法 URL 解析进公告段', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{
          'enabled': true,
          'title': 'T',
          'message': 'M',
          'image': 'https://example.com/banner.jpg',
        },
      }));
      expect(config?.announcement?.image, 'https://example.com/banner.jpg');
    });

    test('image 非法值静默置空', () {
      RemoteNoticeConfig parseWithImage(String image) {
        return RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
          'announcement': <String, Object?>{
            'enabled': true,
            'title': 'T',
            'message': 'M',
            'image': image,
          },
        }))!;
      }
      expect(parseWithImage('javascript:alert(1)').announcement?.image, '');
      expect(parseWithImage('ftp://example.com/a.png').announcement?.image, '');
      expect(parseWithImage('not a url').announcement?.image, '');
      expect(parseWithImage('  ').announcement?.image, '');
    });

    test('纯图公告（无标题正文但配图）有效', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{
          'enabled': true,
          'image': 'https://example.com/banner.jpg',
        },
      }));
      expect(config?.announcement, isNotNull);
      expect(config!.announcement!.image, 'https://example.com/banner.jpg');
      expect(config.announcement!.title, '');
      expect(config.announcement!.message, '');
    });

    test('纯图但 image 非法时整段丢弃', () {
      final config = RemoteNoticeConfig.tryParse(jsonEncode(<String, Object?>{
        'announcement': <String, Object?>{
          'enabled': true,
          'image': 'not a url',
        },
      }));
      expect(config, isNotNull);
      expect(config!.announcement, isNull);
    });

    test('坏 JSON 与非对象根返回 null', () {
      expect(RemoteNoticeConfig.tryParse('{oops'), isNull);
      expect(RemoteNoticeConfig.tryParse('[]'), isNull);
      expect(RemoteNoticeConfig.tryParse('null'), isNull);
    });
  });

  group('parseBuildNumber', () {
    test('解析 +N 构建号', () {
      expect(parseBuildNumber('0.2.96+2129'), 2129);
      expect(parseBuildNumber(' v3+007 '), 7);
      expect(parseBuildNumber('0.2.96'), isNull);
      expect(parseBuildNumber(''), isNull);
    });
  });

  group('启动弹窗', () {
    testWidgets('公告每次启动弹出，确认后关闭', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _announceOnly),
      );
      expect(find.text('公告标题'), findsOneWidget);
      expect(find.text('公告正文内容'), findsOneWidget);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(find.text('公告标题'), findsNothing);
      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('公告配图时弹窗渲染图片区块', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _announceWithImage),
      );
      expect(find.text('带图公告'), findsOneWidget);
      expect(find.text('看看这张图'), findsOneWidget);
      // FLUTTER_TEST 下 HTTP 返回 400：Image widget 存在（errorBuilder
      // 只替换渲染输出，不移除 Image 元素本身）。
      expect(find.byType(Image), findsOneWidget);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsNothing);
    });

    testWidgets('公告无配图时弹窗不渲染图片', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _announceOnly),
      );
      expect(find.text('公告标题'), findsOneWidget);
      expect(find.byType(Image), findsNothing);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
    });

    testWidgets('远程 build 更大时弹更新卡，稍后再说可关', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _updateOnly),
      );
      expect(find.textContaining('发现新版本'), findsOneWidget);
      expect(find.text('稍后再说'), findsOneWidget);
      expect(find.text('去下载'), findsOneWidget);
      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();
      expect(find.textContaining('发现新版本'), findsNothing);
    });

    testWidgets('已是最新版本时不弹更新只弹公告', (tester) async {
      const RemoteNoticeConfig config = RemoteNoticeConfig(
        announcement: RemoteNoticeAnnouncement(
          title: '公告标题',
          message: '公告正文内容',
          button: '我知道了',
        ),
        update: RemoteNoticeUpdate(
          version: '0.2.97',
          build: 2130,
          notes: '更新说明',
          url: '',
        ),
      );
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+2130', config: config),
      );
      expect(find.text('公告标题'), findsOneWidget);
      expect(find.textContaining('发现新版本'), findsNothing);
      expect(find.text('去下载'), findsNothing);
      await tester.tap(find.text('我知道了'));
      await tester.pumpAndSettle();
    });

    testWidgets('公告与更新同时满足时同卡展示', (tester) async {
      const RemoteNoticeConfig config = RemoteNoticeConfig(
        announcement: RemoteNoticeAnnouncement(
          title: '公告标题',
          message: '公告正文内容',
          button: '我知道了',
        ),
        update: RemoteNoticeUpdate(
          version: '0.2.97',
          build: 3000,
          notes: '更新说明',
          url: '',
        ),
      );
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: config),
      );
      expect(find.text('公告标题'), findsOneWidget);
      expect(find.textContaining('发现新版本'), findsOneWidget);
      await tester.tap(find.text('稍后再说'));
      await tester.pumpAndSettle();
    });

    testWidgets('去下载失败时降级为卡内可复制链接', (tester) async {
      final stub = _StubLauncher(false);
      _installLauncher(stub);
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _updateOnly),
      );
      await tester.tap(find.text('去下载'));
      await tester.pumpAndSettle();
      expect(stub.launched, hasLength(1));
      expect(stub.launched.single, 'https://example.com/download');
      expect(find.text('无法打开浏览器，链接已复制，可手动粘贴：'), findsOneWidget);
      expect(find.textContaining('example.com/download'), findsWidgets);
    });

    testWidgets('去下载成功时直接关闭弹窗', (tester) async {
      final stub = _StubLauncher(true);
      _installLauncher(stub);
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', config: _updateOnly),
      );
      await tester.tap(find.text('去下载'));
      await tester.pumpAndSettle();
      expect(stub.launched, hasLength(1));
      expect(find.textContaining('发现新版本'), findsNothing);
      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('拉取失败静默', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', fetcher: () async => null),
      );
      expect(find.text('公告标题'), findsNothing);
      expect(find.textContaining('发现新版本'), findsNothing);
      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('配置内容非法静默', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96+100', fetcher: () async => '<html>x</html>'),
      );
      expect(find.text('公告标题'), findsNothing);
      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('本地构建号解析失败时跳过更新段', (tester) async {
      await _pumpToNotice(
        tester,
        _host(version: '0.2.96', config: _updateOnly),
      );
      expect(find.textContaining('发现新版本'), findsNothing);
      expect(find.text('home-body'), findsOneWidget);
    });

    testWidgets('拉取抛错静默', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(_contextCapture(tester, (context) {
        captured = context;
      }));
      final Future<void> future = maybeShowRemoteNotice(
        captured,
        currentVersion: '0.2.96+100',
        debugFetcher: () async => throw Exception('offline'),
      );
      await tester.pump();
      expect(find.text('公告标题'), findsNothing);
      await future;
    });

    testWidgets('同一会话只尝试一次', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(_contextCapture(tester, (context) {
        captured = context;
      }));
      final Future<void> first = maybeShowRemoteNotice(
        captured,
        currentVersion: '0.2.96+100',
        debugConfig: _announceOnly,
      );
      await tester.pumpAndSettle();
      expect(find.text('公告标题'), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      await first;
      final Future<void> second = maybeShowRemoteNotice(
        captured,
        currentVersion: '0.2.96+100',
        debugConfig: _announceOnly,
      );
      await tester.pump();
      expect(find.text('公告标题'), findsNothing);
      await second;
    });

    testWidgets('FLUTTER_TEST 环境未注入时直通不拉网', (tester) async {
      late BuildContext captured;
      await tester.pumpWidget(_contextCapture(tester, (context) {
        captured = context;
      }));
      await maybeShowRemoteNotice(captured, currentVersion: '0.2.96+100');
      await tester.pump();
      expect(find.text('公告标题'), findsNothing);
      expect(find.textContaining('发现新版本'), findsNothing);
    });
  });
}
