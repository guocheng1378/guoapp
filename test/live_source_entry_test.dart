import 'dart:convert';

import 'package:duanju_app/custom_sources.dart';
import 'package:duanju_app/http_headers.dart';
import 'package:duanju_app/live_source_entry.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<LocalStore> buildStore([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  group('parseHttpHeaders', () {
    test('accepts map, JSON string and Key: Value text', () {
      expect(
        parseHttpHeaders({'Referer': 'https://a/', 'X-Token': ' t '}),
        {'Referer': 'https://a/', 'X-Token': 't'},
      );
      expect(
        parseHttpHeaders('{"User-Agent":"UA","Cookie":"sid=1"}'),
        {'User-Agent': 'UA', 'Cookie': 'sid=1'},
      );
      expect(
        parseHttpHeaders('Referer: https://c/\nX-Token: abc'),
        {'Referer': 'https://c/', 'X-Token': 'abc'},
      );
    });

    test('rejects CRLF injection and invalid header names', () {
      expect(parseHttpHeaders({'Bad Name': 'x'}), isEmpty);
      expect(parseHttpHeaders({'X': 'a\r\nX-Evil: 1'}), isEmpty);
      expect(parseHttpHeaders('not a header'), isEmpty);
      expect(validateHttpHeaders({'X': 'a\r\nb'}), isNotNull);
      expect(validateHttpHeaders({'Host': 'evil.test'}), isNotNull);
      expect(
        validateHttpHeaders({for (var i = 0; i < 9; i++) 'X$i': 'v'}),
        isNotNull,
      );
      expect(validateHttpHeaders({'X-Token': 'ok'}), isNull);
    });

    test('mergeUserAgent keeps an explicit User-Agent', () {
      expect(
        mergeUserAgent({'User-Agent': 'Explicit'}, 'Fallback'),
        {'User-Agent': 'Explicit'},
      );
      expect(
        mergeUserAgent({'Referer': 'https://a/'}, 'Fallback'),
        {'Referer': 'https://a/', 'User-Agent': 'Fallback'},
      );
    });
  });

  group('LiveSourceEntry', () {
    test('decodeList upgrades old plain-URL rows and skips broken ones', () {
      final entries = LiveSourceEntry.decodeList(
        jsonEncode([
          'https://old.m3u',
          {'url': 'https://new.m3u', 'ua': 'UA-New'},
          {'name': 'missing url'},
          42,
        ]),
      );
      expect(entries, hasLength(2));
      expect(entries[0].url, 'https://old.m3u');
      expect(entries[0].headers, isEmpty);
      expect(entries[1].headers['User-Agent'], 'UA-New');
      expect(LiveSourceEntry.decodeList('not json'), isEmpty);
      expect(LiveSourceEntry.decodeList(null), isEmpty);
    });

    test('toPayload merges UA and carries inline payload', () {
      final entry = LiveSourceEntry(
        url: 'inline:0',
        label: '央视组',
        agent: 'UA',
        headers: const {'Referer': 'https://a/'},
        payload: '{"channels":[]}',
      );
      final payload = entry.toPayload();
      expect(payload['agent'], isNull);
      expect(payload['headers'], {
        'User-Agent': 'UA',
        'Referer': 'https://a/',
      });
      expect(payload['payload'], '{"channels":[]}');
      expect(entry.isInline, isTrue);
      expect(entry.displayLabel, '央视组');
    });
  });

  group('LocalStore live sources', () {
    test('old format survives restart, new format round-trips', () async {
      final store = await buildStore();
      final prefs = await SharedPreferences.getInstance();
      await store.setLiveSourceUrls(['https://old.m3u']);
      final raw = prefs.getString(LocalSnapshot.storageKey);
      expect(raw, isNotNull);

      // 旧版快照：liveSources 元素是纯 URL 字符串。
      final decoded = jsonDecode(raw!) as Map<String, dynamic>;
      final values = Map<String, dynamic>.from(decoded['values'] as Map);
      values['liveSources'] = jsonEncode([
        'https://old.m3u',
        'https://old2.txt',
      ]);
      final oldBlob = jsonEncode({'version': 1, 'values': values});
      final restored = await buildStore({LocalSnapshot.storageKey: oldBlob});
      expect(restored.liveSourceUrls, [
        'https://old.m3u',
        'https://old2.txt',
      ]);
      expect(restored.liveSourceEntries, hasLength(2));

      await restored.setLiveSourceEntries([
        LiveSourceEntry(
          url: 'https://new.m3u',
          headers: const {'Referer': 'https://new/'},
        ),
        LiveSourceEntry(
          url: 'inline:0',
          label: '内嵌',
          payload: '{"channels":[]}',
        ),
      ]);
      final newRaw = (await SharedPreferences.getInstance())
          .getString(LocalSnapshot.storageKey);
      final upgraded = await buildStore({LocalSnapshot.storageKey: newRaw!});
      expect(upgraded.liveSourceEntries, hasLength(2));
      expect(upgraded.liveSourceEntries.first.headers['Referer'],
          'https://new/');
      expect(upgraded.liveSourceEntries.last.isInline, isTrue);
    });

    test('setLiveSourceEntries rejects unsafe headers', () async {
      final store = await buildStore();
      await expectLater(
        store.setLiveSourceEntries([
          LiveSourceEntry(
            url: 'https://bad.m3u',
            headers: const {'X': 'a\r\nX-Evil: 1'},
          ),
        ]),
        throwsA(isA<StateError>()),
      );
      expect(store.liveSourceEntries, isEmpty);
    });

    test('backup keeps live sources and custom sources', () async {
      final store = await buildStore();
      await store.setLiveSourceEntries([
        LiveSourceEntry(
          url: 'https://backup.m3u',
          headers: const {'Referer': 'https://backup/'},
        ),
      ]);
      await store.addCustomSource(
        name: '备份源',
        url: 'https://cms.example.com',
        headers: const {'X-Token': 'abc'},
      );

      final content = await store.exportBackup();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      expect(decoded['liveSources'], isA<String>());
      expect(decoded['customSources'], isA<String>());

      await store.importBackup(content);
      expect(store.liveSourceEntries.single.url, 'https://backup.m3u');
      expect(
        store.liveSourceEntries.single.headers['Referer'],
        'https://backup/',
      );
      expect(store.customSources.single.name, '备份源');
      expect(store.customSources.single.headers['X-Token'], 'abc');
    });

    test('backup without the new keys keeps current values', () async {
      final store = await buildStore();
      await store.setLiveSourceUrls(['https://old.m3u']);
      final content = await store.exportBackup();
      final decoded = jsonDecode(content) as Map<String, dynamic>;
      decoded.remove('liveSources');
      decoded.remove('customSources');
      await store.importBackup(jsonEncode(decoded));
      expect(store.liveSourceUrls, ['https://old.m3u']);
    });
  });

  group('CustomSourceSpec headers', () {
    test('validate accepts safe headers and rejects injection', () {
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com',
          category: 'video',
          headers: const {'X-Token': 'abc'},
        ),
        isNull,
      );
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com',
          category: 'video',
          headers: const {'Host': 'evil.test'},
        ),
        isNotNull,
      );
    });

    test('toPayload merges UA and fromJson round-trips', () {
      const spec = CustomSourceSpec(
        id: 'custom-aaaa1111',
        name: '源',
        url: 'https://a.com',
        agent: 'UA',
        headers: {'Referer': 'https://a/'},
      );
      expect(spec.toPayload()['headers'], {
        'User-Agent': 'UA',
        'Referer': 'https://a/',
      });
      final restored = CustomSourceSpec.fromJson(spec.toJson());
      expect(restored!.effectiveHeaders, {
        'User-Agent': 'UA',
        'Referer': 'https://a/',
      });
    });
  });
}
