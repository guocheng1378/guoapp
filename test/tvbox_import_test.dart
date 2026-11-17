import 'package:duanju_app/custom_sources.dart';
import 'package:duanju_app/live_source_entry.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/tvbox_config.dart';
import 'package:duanju_app/tvbox_import.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String _config = '''
{
  "sites": [
    {"name": "影视A", "api": "https://a.example.com/api.php/provide/vod/?ac=videolist", "ua": "UA-A", "header": {"Referer": "https://a.example.com/"}},
    {"name": "影视B", "api": "https://b.example.com"}
  ],
  "lives": [
    {"name": "直播A", "url": "https://live.example.com/a.m3u", "ua": "okhttp/4.9"},
    {"name": "直播B", "url": "https://live.example.com/b.txt"}
  ]
}
''';

Future<LocalStore> buildStore() async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

Widget importHost(void Function(BuildContext context) onOpen) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          key: const Key('open-import'),
          onPressed: () => onOpen(context),
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  setUp(() => SourceSite.registerCustomSites(const []));

  test('registers sites, publishes once, merges live urls and is idempotent',
      () async {
    final store = await buildStore();
    final published = <List<CustomSourceSpec>>[];
    Future<void> publish(List<CustomSourceSpec> sources) async {
      published.add(List.of(sources));
    }

    final plan = TvboxConfigParser.parse(_config);
    final outcome = await applyTvboxImport(
      store: store,
      publish: publish,
      plan: plan,
    );
    expect(outcome.sitesAdded, 2);
    expect(outcome.liveUrlsAdded, 2);
    expect(outcome.skippedSites, 0);
    expect(outcome.errors, isEmpty);
    expect(store.customSources, hasLength(2));
    expect(store.liveSourceUrls, hasLength(2));
    expect(published, hasLength(1));
    expect(
      [for (final spec in published.single) spec.url],
      ['https://a.example.com', 'https://b.example.com'],
    );
    expect(store.customSources.first.headers, {
      'User-Agent': 'UA-A',
      'Referer': 'https://a.example.com/',
    });
    expect(published.single.first.toPayload()['headers'], isNotNull);
    expect(
      store.liveSourceEntries.first.headers['User-Agent'],
      'okhttp/4.9',
    );

    final second = await applyTvboxImport(
      store: store,
      publish: publish,
      plan: plan,
    );
    expect(second.sitesAdded, 0);
    expect(second.liveUrlsAdded, 0);
    expect(second.skippedSites, 2);
    expect(published, hasLength(1), reason: '重复导入不应再次下发核心');
    expect(store.liveSourceUrls, hasLength(2));
  });

  test('honours the 16-source cap and reports it', () async {
    final store = await buildStore();
    for (var i = 0; i < CustomSourceSpec.maxSources; i++) {
      await store.addCustomSource(name: '源$i', url: 'https://s$i.example.com');
    }
    var publishes = 0;
    Future<void> publish(List<CustomSourceSpec> sources) async {
      publishes++;
    }

    final outcome = await applyTvboxImport(
      store: store,
      publish: publish,
      plan: const TvboxImportPlan(
        sites: [
          TvboxSite(
            name: '超量',
            url: 'https://over.example.com',
            category: 'video',
          ),
        ],
      ),
    );
    expect(outcome.sitesAdded, 0);
    expect(outcome.skippedSites, 1);
    expect(outcome.errors.single, contains('上限'));
    expect(publishes, 0);
    expect(store.customSources, hasLength(CustomSourceSpec.maxSources));
  });

  test('rolls back local sites when publishing to the core fails', () async {
    final store = await buildStore();

    Future<void> publish(List<CustomSourceSpec> sources) async {
      throw StateError('核心不可用');
    }

    final plan = TvboxConfigParser.parse(_config);
    final outcome = await applyTvboxImport(
      store: store,
      publish: publish,
      plan: plan,
    );
    expect(outcome.sitesAdded, 0);
    expect(outcome.errors.single, contains('已回滚'));
    expect(
      store.customSources,
      isEmpty,
      reason: '下发失败必须回滚本地，否则重试时全部被判「已存在」跳过',
    );
  });

  test('inline live entries are deduped by payload, not by inline index',
      () async {
    final store = await buildStore();
    await store.setLiveSourceEntries(const [
      LiveSourceEntry(
        url: 'inline:0',
        payload: '#EXTM3U\n#EXTINF:-1,旧频道\nhttp://a.test/1.m3u8',
        label: '旧配置',
      ),
    ]);

    final outcome = await applyTvboxImport(
      store: store,
      publish: (_) async {},
      plan: const TvboxImportPlan(
        liveSources: [
          LiveSourceEntry(
            url: 'inline:0',
            payload: '#EXTM3U\n#EXTINF:-1,新频道\nhttp://a.test/2.m3u8',
            label: '新配置',
          ),
        ],
      ),
    );
    expect(outcome.liveUrlsAdded, 1, reason: '正文不同就不算重复');
    expect(store.liveSourceEntries, hasLength(2));
  });

  test('empty plan writes nothing', () async {
    final store = await buildStore();
    var publishes = 0;
    Future<void> publish(List<CustomSourceSpec> sources) async {
      publishes++;
    }

    final outcome = await applyTvboxImport(
      store: store,
      publish: publish,
      plan: const TvboxImportPlan(),
    );
    expect(outcome.sitesAdded, 0);
    expect(outcome.liveUrlsAdded, 0);
    expect(outcome.errors, isEmpty);
    expect(publishes, 0);
    expect(store.customSources, isEmpty);
    expect(store.liveSourceUrls, isEmpty);
  });

  testWidgets('import dialog previews the plan before confirming',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    TvboxImportPlan? result;
    await tester.pumpWidget(
      importHost((context) async {
        result = await showTvboxImportDialog(context);
      }),
    );
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('tvbox-import-input')),
      _config,
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tvbox-import-parse')));
    await tester.pump();
    expect(find.byKey(const ValueKey('tvbox-import-summary')), findsOneWidget);
    expect(find.textContaining('可导入：2 个站源 · 2 个直播源'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tvbox-import-confirm')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.sites, hasLength(2));
    expect(result!.liveSources, hasLength(2));
  });

  test('detects tvbox address input', () {
    expect(looksLikeTvboxUrl(' https://a.example.com/tvbox.json '), isTrue);
    expect(looksLikeTvboxUrl('HTTP://a.example.com'), isTrue);
    expect(looksLikeTvboxUrl('{"sites":[]}'), isFalse);
    expect(looksLikeTvboxUrl(''), isFalse);
  });

  test('rejects non-http address before touching the network', () async {
    await expectLater(
      fetchTvboxConfig('ftp://a.example.com/config.json'),
      throwsA(isA<TvboxConfigException>()),
    );
    await expectLater(
      fetchTvboxConfig('not-a-url'),
      throwsA(isA<TvboxConfigException>()),
    );
  });

  testWidgets('import dialog fetches config from a tvbox address',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final requested = <String>[];
    TvboxImportPlan? result;
    await tester.pumpWidget(
      importHost((context) async {
        result = await showTvboxImportDialog(
          context,
          fetcher: (url) async {
            requested.add(url);
            return _config;
          },
        );
      }),
    );
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('tvbox-import-input')),
      'https://tvbox.example.com/api.json',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tvbox-import-parse')));
    await tester.pumpAndSettle();
    expect(requested, ['https://tvbox.example.com/api.json']);
    expect(find.textContaining('可导入：2 个站源 · 2 个直播源'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tvbox-import-confirm')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.sites, hasLength(2));
    expect(result!.liveSources, hasLength(2));
  });

  testWidgets('import dialog reports address fetch failures', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      importHost(
        (context) => showTvboxImportDialog(
          context,
          fetcher: (url) async =>
              throw const TvboxConfigException('地址返回 HTTP 404'),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('tvbox-import-input')),
      'https://x.example.com/config.json',
    );
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('tvbox-import-parse')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tvbox-import-error')), findsOneWidget);
    expect(find.text('地址返回 HTTP 404'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('tvbox-import-confirm')),
    );
    expect(button.onPressed, isNull);
  });

  test('local category is not selectable when adding a source by hand', () {
    expect(CustomSourceSpec.categories, isNot(contains('local')));
    expect(CustomSourceSpec.categories, containsAll(<String>['shortDrama', 'video', 'adult']));
  });

  test('local package sites land in the local category', () async {
    final store = await buildStore();
    final plan = TvboxConfigParser.parse(_config, localPackage: true);
    final outcome = await applyTvboxImport(
      store: store,
      publish: (_) async {},
      plan: plan,
    );
    expect(outcome.sitesAdded, 2);
    expect(store.customSources.every((source) => source.localPackage), isTrue);

    final spec = store.customSources.first;
    final site = SourceSite.byId(spec.id)!;
    expect(site.category, SourceCategory.local);
    expect(site.isLocalSource, isTrue);
    expect(store.customSources.where((s) => s.toSourceSite().isLocalSource),
        hasLength(2));

    // 下发给 Go 核心的 payload 不带本机标记，category 仍是解析出的真实类型。
    final payload = spec.toPayload();
    expect(payload.containsKey('localPackage'), isFalse);
    expect(payload['category'], 'video');

    // 持久化往返保留标记，重启后仍归本地类。
    final restored = CustomSourceSpec.fromJson(spec.toJson());
    expect(restored, isNotNull);
    expect(restored!.localPackage, isTrue);
    expect(restored.sourceCategory, SourceCategory.local);
  });

  testWidgets('import dialog accepts a local config file package',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    TvboxImportPlan? result;
    await tester.pumpWidget(
      importHost((context) async {
        result = await showTvboxImportDialog(
          context,
          fileLoader: () async => const TvboxConfigFile(
            name: 'mybox.json',
            content: _config,
          ),
        );
      }),
    );
    await tester.tap(find.byKey(const Key('open-import')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('tvbox-import-pick-file')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('tvbox-import-local-source')),
      findsOneWidget,
    );
    expect(find.textContaining('mybox.json'), findsOneWidget);
    expect(find.textContaining('可导入：2 个站源 · 2 个直播源'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tvbox-import-confirm')));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
    expect(result!.localPackage, isTrue);
    expect(result!.sites, hasLength(2));
  });
}
