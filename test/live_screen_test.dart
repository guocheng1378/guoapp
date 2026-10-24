import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/live_models.dart';
import 'package:duanju_app/live_screen.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _LiveRepository extends AppRepository {
  _LiveRepository({this.page, this.error});
  LivePage? page;
  Object? error;
  final calls = <({String listId, List<String> urls, bool force})>[];

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
  Future<DramaDetail> detail(Drama drama) async =>
      throw AppFailure('测试桩未实现');
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
  }) async {
    calls.add((listId: listId, urls: List.of(liveUrls), force: force));
    if (error != null) throw error!;
    return page!;
  }
}

LivePage _page({
  String listId = 'main',
  List<LiveList> lists = const [LiveList(id: 'main', name: '内置主列表')],
  List<LiveGroup> groups = const [],
  String warning = '',
  bool stale = false,
}) => LivePage(
  listId: listId,
  lists: lists,
  groups: groups,
  channelCount: [for (final g in groups) ...g.channels].length,
  warning: warning,
  stale: stale,
);

Future<void> _mount(
  WidgetTester tester,
  _LiveRepository repo, {
  List<String> urls = const [],
  ValueChanged<LiveChannel>? onPlay,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: LiveScreen(
        repository: repo,
        liveUrls: urls,
        onPlayChannel: onPlay,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 60));
}

void main() {
  group('LivePage.fromJson', () {
    test('parses full payload', () {
      final page = LivePage.fromJson({
        'listId': 'fav',
        'lists': [
          {'id': 'fav', 'name': '收藏列表'},
        ],
        'groups': [
          {
            'name': '央视',
            'channels': [
              {'name': 'CCTV1', 'group': '央视', 'urls': ['http://a/1']},
            ],
          },
        ],
        'channelCount': '3',
        'fetchedAt': '2026-10-22T10:00:00Z',
        'stale': true,
        'warning': '自填源 1 个加载失败',
      });
      expect(page.listId, 'fav');
      expect(page.lists.single.name, '收藏列表');
      expect(page.groups.single.channels.single.name, 'CCTV1');
      expect(page.channelCount, 3);
      expect(page.stale, isTrue);
      expect(page.warning, contains('加载失败'));
      expect(page.isEmpty, isFalse);
    });

    test('tolerates missing or malformed fields', () {
      final page = LivePage.fromJson({});
      expect(page.listId, '');
      expect(page.lists, isEmpty);
      expect(page.groups, isEmpty);
      expect(page.channelCount, 0);
      expect(page.stale, isFalse);
      expect(page.isEmpty, isTrue);
    });

    test('channel urls trim and drop blanks', () {
      final channel = LiveChannel.fromJson({
        'name': '测试台',
        'urls': [' http://a/1 ', '   ', 42, null, 'http://a/2'],
      });
      expect(channel.urls, ['http://a/1', 'http://a/2']);
      expect(channel.playable, isTrue);
      expect(const LiveChannel(name: '空').playable, isFalse);
    });
  });

  group('LiveScreen', () {
    testWidgets('renders groups and channels after load', (tester) async {
      final repo = _LiveRepository(
        page: _page(
          groups: [
            LiveGroup(name: '央视', channels: [const LiveChannel(name: 'CCTV1')]),
            LiveGroup(
              name: '卫视',
              channels: [
                const LiveChannel(name: '湖南卫视', urls: ['http://a/1', 'http://a/2']),
              ],
            ),
          ],
        ),
      );
      await _mount(tester, repo, urls: ['http://mine/1.m3u']);
      expect(find.byKey(const Key('live-group-央视')), findsOneWidget);
      expect(find.byKey(const Key('live-group-卫视')), findsOneWidget);
      expect(find.text('CCTV1'), findsOneWidget);
      expect(find.text('湖南卫视'), findsOneWidget);
      expect(find.text('2 条线路'), findsOneWidget);
      // 自填源 URL 透传给核心。
      expect(repo.calls.single.urls, ['http://mine/1.m3u']);
    });

    testWidgets('group chip filters channel list', (tester) async {
      final repo = _LiveRepository(
        page: _page(
          groups: [
            LiveGroup(name: '央视', channels: [const LiveChannel(name: 'CCTV1')]),
            LiveGroup(name: '卫视', channels: [const LiveChannel(name: '湖南卫视')]),
          ],
        ),
      );
      await _mount(tester, repo);
      await tester.tap(find.byKey(const Key('live-group-央视')));
      await tester.pumpAndSettle();
      expect(find.text('CCTV1'), findsOneWidget);
      expect(find.text('湖南卫视'), findsNothing);
      await tester.tap(find.byKey(const Key('live-group-')));
      await tester.pumpAndSettle();
      expect(find.text('湖南卫视'), findsOneWidget);
    });

    testWidgets('tapping playable channel invokes onPlayChannel',
        (tester) async {
      final repo = _LiveRepository(
        page: _page(
          groups: [
            LiveGroup(
              name: '央视',
              channels: [const LiveChannel(name: 'CCTV1', urls: ['http://a/1'])],
            ),
          ],
        ),
      );
      final played = <LiveChannel>[];
      await _mount(tester, repo, onPlay: (c) => played.add(c));
      await tester.tap(find.byKey(const Key('live-channel-CCTV1')));
      await tester.pump();
      expect(played.single.name, 'CCTV1');
    });

    testWidgets('tapping unplayable channel shows snackbar', (tester) async {
      final repo = _LiveRepository(
        page: _page(
          groups: [
            LiveGroup(name: '央视', channels: [const LiveChannel(name: 'CCTV1')]),
          ],
        ),
      );
      final played = <LiveChannel>[];
      await _mount(tester, repo, onPlay: (c) => played.add(c));
      await tester.tap(find.byKey(const Key('live-channel-CCTV1')));
      await tester.pump();
      expect(played, isEmpty);
      expect(find.textContaining('暂无可用线路'), findsOneWidget);
    });

    testWidgets('error state offers retry that recovers', (tester) async {
      final repo = _LiveRepository(
        error: AppFailure('网络不可用'),
        page: _page(
          groups: [LiveGroup(name: '央视', channels: [const LiveChannel(name: 'CCTV1')])],
        ),
      );
      await _mount(tester, repo);
      expect(find.textContaining('直播列表加载失败'), findsOneWidget);
      repo.error = null;
      await tester.tap(find.byKey(const Key('live-retry')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      expect(find.text('CCTV1'), findsOneWidget);
    });

    testWidgets('single list hides switch menu', (tester) async {
      final single = _LiveRepository(page: _page());
      await _mount(tester, single);
      expect(find.byKey(const Key('live-list-switch')), findsNothing);
    });

    testWidgets('multiple lists expose switch and trigger reload',
        (tester) async {
      final multi = _LiveRepository(
        page: _page(
          lists: const [
            LiveList(id: 'main', name: '内置主列表'),
            LiveList(id: 'fav', name: '收藏列表'),
          ],
        ),
      );
      await _mount(tester, multi);
      expect(find.byKey(const Key('live-list-switch')), findsOneWidget);
      await tester.tap(find.byKey(const Key('live-list-switch')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('收藏列表'));
      await tester.pumpAndSettle();
      expect(multi.calls.last.listId, 'fav');
    });

    testWidgets('warning bar renders when present', (tester) async {
      final repo = _LiveRepository(
        page: _page(
          warning: '自填源 1 个加载失败',
          groups: [LiveGroup(name: '央视', channels: [const LiveChannel(name: 'CCTV1')])],
        ),
      );
      await _mount(tester, repo);
      expect(find.byKey(const Key('live-warning-bar')), findsOneWidget);
      expect(find.textContaining('加载失败'), findsOneWidget);
    });
  });
}
