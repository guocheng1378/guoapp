import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_screen.dart';
import 'package:duanju_app/live_source_entry.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/tvbox_config.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _EpgRepository extends AppRepository {
  _EpgRepository({required this.page, this.epg = LiveEpg.empty});

  LivePage page;
  LiveEpg epg;
  final sourceCalls = <List<LiveSourceEntry>>[];
  final epgCalls = <List<LiveChannel>>[];
  bool attachEpg = true;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> release(String session) async {}
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async => throw AppFailure('测试桩未实现');
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      throw AppFailure('测试桩未实现');
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
  @override
  Future<DramaDetail> detail(Drama drama) async => throw AppFailure('测试桩未实现');
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => throw AppFailure('测试桩未实现');
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      throw AppFailure('测试桩未实现');
  @override
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route) async =>
      throw AppFailure('测试桩未实现');
  @override
  Future<void> cancelPlayback() async {}

  @override
  Future<LivePage> liveChannels({
    String listId = '',
    List<String> liveUrls = const [],
    bool force = false,
  }) async => page;

  @override
  Future<LivePage> liveChannelsWithSources({
    String listId = '',
    List<LiveSourceEntry> liveSources = const [],
    bool force = false,
  }) async {
    sourceCalls.add(List.of(liveSources));
    return page;
  }

  @override
  Future<LiveEpg> liveEpg({
    List<LiveSourceEntry> epgSources = const [],
    List<LiveChannel> channels = const [],
  }) async {
    epgCalls.add(List.of(channels));
    if (!attachEpg) return LiveEpg.empty;
    return epg;
  }
}

LivePage _page(List<LiveChannel> channels) => LivePage(
  listId: 'main',
  lists: const [LiveList(id: 'main', name: '内置主列表')],
  groups: [LiveGroup(name: '央视', channels: channels)],
  channelCount: channels.length,
);

LiveEpg _epgNow(DateTime now) => LiveEpg(
  channels: [
    LiveEpgChannel(
      name: 'CCTV1',
      matched: true,
      match: 'name',
      now: LiveProgram(
        title: '新闻联播',
        start: now.subtract(const Duration(minutes: 10)),
        stop: now.add(const Duration(minutes: 20)),
      ),
      next: LiveProgram(
        title: '焦点访谈',
        start: now.add(const Duration(minutes: 20)),
        stop: now.add(const Duration(minutes: 50)),
      ),
      programs: [
        LiveProgram(
          title: '早间新闻',
          start: now.subtract(const Duration(hours: 2)),
          stop: now.subtract(const Duration(hours: 1)),
        ),
        LiveProgram(
          title: '新闻联播',
          start: now.subtract(const Duration(minutes: 10)),
          stop: now.add(const Duration(minutes: 20)),
        ),
        LiveProgram(
          title: '焦点访谈',
          start: now.add(const Duration(minutes: 20)),
          stop: now.add(const Duration(minutes: 50)),
        ),
      ],
    ),
  ],
);

Future<void> _mount(
  WidgetTester tester,
  _EpgRepository repo, {
  List<LiveSourceEntry> sources = const [],
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveScreen(
        repository: repo,
        liveSources: sources,
        onPlayChannel: (_) {},
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  group('LiveEpg 模型', () {
    test('解析频道/正在播/下一档/当日节目并规范化时间', () {
      final epg = LiveEpg.fromJson({
        'channels': [
          {
            'name': 'CCTV1',
            'tvgId': 'cctv1.hd',
            'matched': true,
            'match': 'tvgId',
            'now': {
              'title': '新闻联播',
              'start': '2026-11-08T19:00:00+08:00',
              'stop': '2026-11-08T19:30:00+08:00',
            },
            'next': {'title': '焦点访谈', 'start': '2026-11-08T19:30:00+08:00'},
            'programs': [
              {'title': '新闻联播', 'start': '2026-11-08T19:00:00+08:00'},
            ],
          },
        ],
        'fetchedAt': '2026-11-08T19:10:00+08:00',
        'warning': '',
        'cached': true,
      });
      expect(epg.cached, isTrue);
      final channel = epg.channels.single;
      expect(channel.tvgId, 'cctv1.hd');
      expect(channel.now!.title, '新闻联播');
      expect(channel.next!.title, '焦点访谈');
      // 缺 stop 时按 30 分钟兜底，避免进度除零。
      expect(channel.next!.duration, const Duration(minutes: 30));
      expect(channel.programs.single.start.isUtc, isFalse);
      // tvg-id 优先于台名。
      expect(epg.find('别的台', tvgId: 'cctv1.hd'), isNotNull);
      expect(epg.find('CCTV1'), isNotNull);
      expect(epg.find('不存在'), isNull);
    });

    test('节目进度与在播判定', () {
      final start = DateTime(2026, 11, 8, 20);
      final program = LiveProgram(
        title: 'A',
        start: start,
        stop: start.add(const Duration(minutes: 40)),
      );
      expect(program.progressAt(start), 0);
      expect(
        program.progressAt(start.add(const Duration(minutes: 20))),
        closeTo(0.5, 0.001),
      );
      expect(program.progressAt(start.add(const Duration(hours: 2))), 1);
      expect(program.isOnAir(start), isTrue);
      expect(
        program.isOnAir(start.add(const Duration(minutes: 41))),
        isFalse,
      );
      // 空结果不抛异常，UI 直接降级。
      expect(LiveEpg.empty.find('CCTV1'), isNull);
      expect(LiveEpg.empty.isEmpty, isTrue);
    });
  });

  group('LiveSourceEntry.epg', () {
    test('序列化往返保留 EPG，非法地址丢弃', () {
      final entry = LiveSourceEntry(
        url: 'http://a/x.m3u',
        epg: 'https://epg.test/pp.xml',
      );
      final captured = const JsonEncoder().convert(entry.toJson());
      final restored = LiveSourceEntry.fromJson(jsonDecode(captured));
      expect(restored!.epg, 'https://epg.test/pp.xml');
      expect(restored.hasEpg, isTrue);
      expect(LiveSourceEntry.sanitizeEpgUrl('ftp://a/b.xml'), '');
      expect(LiveSourceEntry.sanitizeEpgUrl('  '), '');
      expect(
        LiveSourceEntry.sanitizeEpgUrl('https://epg.test/e.xml.gz'),
        'https://epg.test/e.xml.gz',
      );
      // copyWith 能把 EPG 清空（取消关联）。
      expect(entry.copyWith(epg: '').epg, '');
    });
  });

  group('TVBox 配置的 EPG 字段', () {
    test('lives[].epg 随订阅导入，非法地址忽略并提示', () {
      final plan = TvboxConfigParser.parse(
        jsonEncode({
          'sites': [],
          'lives': [
            {
              'name': '节目单源',
              'url': 'http://a/x.m3u',
              'epg': 'https://epg.test/pp.xml',
            },
            {'name': '坏节目单', 'url': 'http://b/y.m3u', 'epg': 'ftp://bad'},
          ],
        }),
      );
      expect(plan.liveSources, hasLength(2));
      expect(plan.liveSources[0].epg, 'https://epg.test/pp.xml');
      expect(plan.liveSources[1].epg, '');
      expect(
        plan.notices.any((notice) => notice.reason.contains('已关联节目单')),
        isTrue,
      );
      expect(
        plan.notices.any((notice) => notice.reason.contains('不是 http(s)')),
        isTrue,
      );
    });
  });

  group('LiveScreen 节目单', () {
    testWidgets('频道行显示正在播，且只请求可见频道', (tester) async {
      final repo = _EpgRepository(
        page: _page(const [
          LiveChannel(name: 'CCTV1', urls: ['http://a/1']),
          LiveChannel(name: '湖南卫视', urls: ['http://a/2']),
        ]),
        epg: _epgNow(DateTime.now()),
      );
      await _mount(
        tester,
        repo,
        sources: const [
          LiveSourceEntry(url: 'http://mine/1.m3u', epg: 'https://epg.test/pp.xml'),
        ],
      );
      expect(repo.epgCalls, hasLength(1));
      expect(
        repo.epgCalls.single.map((channel) => channel.name).toList(),
        ['CCTV1', '湖南卫视'],
      );
      final banner = find.byKey(const Key('live-now-CCTV1'));
      expect(banner, findsOneWidget);
      expect(
        (tester.widget<Text>(banner)).data,
        startsWith('正在播 · 新闻联播'),
      );
      // 没有 EPG 的台不显示横幅。
      expect(find.byKey(const Key('live-now-湖南卫视')), findsNothing);
    });

    testWidgets('未配置 EPG 时不发请求', (tester) async {
      final repo = _EpgRepository(
        page: _page(const [LiveChannel(name: 'CCTV1', urls: ['http://a/1'])]),
      );
      await _mount(
        tester,
        repo,
        sources: const [LiveSourceEntry(url: 'http://mine/1.m3u')],
      );
      expect(repo.epgCalls, isEmpty);
      expect(find.byKey(const Key('live-now-CCTV1')), findsNothing);
    });

    testWidgets('长按频道打开当日节目单', (tester) async {
      final repo = _EpgRepository(
        page: _page(const [LiveChannel(name: 'CCTV1', urls: ['http://a/1'])]),
        epg: _epgNow(DateTime.now()),
      );
      await _mount(
        tester,
        repo,
        sources: const [
          LiveSourceEntry(url: 'http://mine/1.m3u', epg: 'https://epg.test/pp.xml'),
        ],
      );
      await tester.longPress(find.byKey(const Key('live-channel-CCTV1')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('live-epg-sheet')), findsOneWidget);
      expect(find.byKey(const Key('live-epg-program-list')), findsOneWidget);
      expect(find.text('正在播'), findsOneWidget);
      expect(find.text('焦点访谈'), findsWidgets);
      expect(find.text('早间新闻'), findsOneWidget);
    });

    testWidgets('长按且无节目单时给出可操作提示', (tester) async {
      final repo = _EpgRepository(
        page: _page(const [LiveChannel(name: 'CCTV1', urls: ['http://a/1'])]),
      );
      await _mount(
        tester,
        repo,
        sources: const [LiveSourceEntry(url: 'http://mine/1.m3u')],
      );
      await tester.longPress(find.byKey(const Key('live-channel-CCTV1')));
      await tester.pump();
      expect(find.byKey(const Key('live-epg-sheet')), findsNothing);
      expect(find.textContaining('未配置节目单'), findsOneWidget);
    });
  });
}
