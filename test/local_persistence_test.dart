import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_snapshot_files.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_preferences.dart';
import 'package:duanju_app/profiles_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class FailingPreferences extends InMemorySharedPreferencesStore {
  FailingPreferences(super.data) : super.withData();
  String failure = '';
  int snapshots = 0;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith(LocalSnapshot.storageKey)) {
      snapshots++;
      if (failure == 'false') return false;
      if (failure == 'throw') throw StateError('synthetic write failure');
      if (failure == 'after') {
        failure = '';
        await super.setValue(valueType, key, value);
        throw StateError('synthetic acknowledgement failure');
      }
    }
    return super.setValue(valueType, key, value);
  }
}

/// 可注入文件写失败的文件层，用于验证 commit 的失败回滚路径。
class FailingSnapshotFiles extends MemorySnapshotFiles {
  bool failWrites = false;

  @override
  Future<void> write(String key, String json) async {
    if (failWrites) throw StateError('synthetic file write failure');
    return super.write(key, json);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '旧资料');
  const next = Drama(id: 'hongguo:2', source: 'hongguo', title: '新资料');

  Future<(LocalStore, FailingPreferences, MemorySnapshotFiles)> create([
    Map<String, Object> initial = const {},
    MemorySnapshotFiles? files,
  ]) async {
    // 文件层跨 create/restart 共享同一实例：等价于生产里应用支持目录不变。
    files ??= MemorySnapshotFiles();
    SharedPreferences.resetStatic();
    final platform = FailingPreferences({
      for (final entry in initial.entries) 'flutter.${entry.key}': entry.value,
    });
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance(), files: files);
    addTearDown(store.dispose);
    return (store, platform, files);
  }

  Future<LocalStore> restart(
    FailingPreferences platform,
    MemorySnapshotFiles files,
  ) async {
    SharedPreferences.resetStatic();
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(await SharedPreferences.getInstance(), files: files);
    addTearDown(store.dispose);
    return store;
  }

  for (final failure in ['false', 'throw', 'after']) {
    test(
      'failed $failure writes keep favorites, preferences and progress after restart',
      () async {
        final (store, platform, files) = await create({
          'plugin_secret': 'outside-the-backup',
        });
        await store.toggleFavorite(drama);
        await store.saveWatch(
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 15,
            duration: 100,
            updatedAt: DateTime.now(),
          ),
        );
        for (final change in <Future<void> Function()>[
          () => store.toggleFavorite(next),
          () => store.clearHistory(),
          () => store.setThemeMode('light'),
          () => store.setPlaybackPreferences(
            const PlaybackPreferences(
              speed: 2,
              quality: 720,
              autoAdvance: false,
            ),
          ),
        ]) {
          platform.failure = failure;
          await expectLater(change(), throwsStateError);
          expect(store.favorites.map((entry) => entry.id), [drama.id]);
          expect(store.watched(drama.id)?.position, 15);
          expect(store.themeMode, 'system');
          expect(store.playbackPreferences.speed, 1);
          final restored = await restart(platform, files);
          expect(restored.favorites.single.id, drama.id);
          expect(restored.watched(drama.id)?.position, 15);
          expect(restored.themeMode, 'system');
          expect(
            restored.preferences.getString('plugin_secret'),
            'outside-the-backup',
          );
        }
        platform.failure = '';
        await store.toggleFavorite(next);
        expect((await restart(platform, files)).favorites.length, 2);
      },
    );
  }

  test('文件层就绪时 commit 拒绝非 String 重键（防写入致锁定的 blob）', () async {
    SharedPreferences.setMockInitialValues(const {});
    final snapshot = LocalSnapshot(
      await SharedPreferences.getInstance(),
      files: MemorySnapshotFiles(),
    );
    await expectLater(
      () => snapshot.commit({'favorites': <String>['bad-type']}),
      throwsStateError,
    );
    // 合法 String 重键不受影响。
    await snapshot.commit({'favorites': '[]'});
  });

  test('heavy keys migrate from blob to files on first commit', () async {
    // 上一代（未拆文件版）应用的存储形态：重键仍打包在 blob 的 values 里。
    final (store, platform, files) = await create({
      LocalSnapshot.storageKey: jsonEncode({
        'version': 1,
        'values': {
          'profiles': jsonEncode([
            // 默认档最小 fixture：带 salt/pinHash 会让 admin.protected=true，
            // forceLogin 回落 true 把 favorites getter 过滤空（登录语义）。
            const LocalProfile(id: 'default', name: '管理员', admin: true)
                .toJson(),
          ]),
          'favorites': jsonEncode([drama.toJson()]),
          'history': jsonEncode([
            WatchEntry(
              drama: drama,
              episode: 1,
              position: 15,
              duration: 100,
              updatedAt: DateTime.now(),
            ).toJson(),
          ]),
        },
      }),
    });
    // 迁移窗口期：重键仍在 blob 里可见。
    expect(store.favorites.single.id, drama.id);
    final before = jsonDecode(
      store.preferences.getString(LocalSnapshot.storageKey)!,
    ) as Map;
    expect((before['values'] as Map), contains('favorites'));
    expect((before['values'] as Map), contains('history'));

    await store.setThemeMode('dark');

    // 任一次提交都会把重键迁出：文件层接管，blob 只剩轻键与全局键。
    expect(files.containsKey('favorites'), isTrue);
    expect(files.containsKey('history'), isTrue);
    final after = jsonDecode(
      store.preferences.getString(LocalSnapshot.storageKey)!,
    ) as Map;
    final afterValues = after['values'] as Map;
    expect(afterValues, isNot(contains('favorites')));
    expect(afterValues, isNot(contains('history')));
    expect(afterValues, containsPair('themeMode', 'dark'));

    // 幂等：后续提交不重写文件，重启后数据完好。
    await store.setThemeMode('light');
    final restored = await restart(platform, files);
    expect(restored.favorites.single.id, drama.id);
    expect(restored.watched(drama.id)?.position, 15);
    expect(restored.themeMode, 'light');
  });

  test('file layer wins over a stale blob copy after restart', () async {
    final (store, platform, files) = await create();
    await store.toggleFavorite(next);
    expect(store.favorites.single.id, next.id);

    // 模拟迁移窗口期的陈旧 blob：手工把旧收藏写回 blob。
    final stale = jsonDecode(
      store.preferences.getString(LocalSnapshot.storageKey)!,
    ) as Map;
    (stale['values'] as Map)['favorites'] = jsonEncode([drama.toJson()]);
    await platform.setValue(
      'String',
      'flutter.${LocalSnapshot.storageKey}',
      jsonEncode(stale),
    );

    final restored = await restart(platform, files);
    expect(restored.favorites.single.id, next.id);
  });

  test('file write failure keeps blob untouched and rolls back', () async {
    final failing = FailingSnapshotFiles();
    final (store, platform, files) = await create(const {}, failing);
    await store.toggleFavorite(drama);
    final snapshotsBefore = platform.snapshots;

    failing.failWrites = true;
    await expectLater(store.toggleFavorite(next), throwsStateError);
    // 文件先写后 blob：文件失败时 blob 未被触碰。
    expect(platform.snapshots, snapshotsBefore);
    expect(store.favorites.map((entry) => entry.id), [drama.id]);

    failing.failWrites = false;
    expect((await restart(platform, files)).favorites.single.id, drama.id);
  });

  test('recovery export merges file-layer heavy keys', () async {
    final (store, platform, files) = await create();
    await store.toggleFavorite(drama);

    // 制造损坏：把 blob values 里的 profiles 改坏，重启后进入锁定恢复态。
    final blob = jsonDecode(
      store.preferences.getString(LocalSnapshot.storageKey)!,
    ) as Map;
    (blob['values'] as Map)['profiles'] = 'broken-json';
    await platform.setValue(
      'String',
      'flutter.${LocalSnapshot.storageKey}',
      jsonEncode(blob),
    );
    final damaged = await restart(platform, files);
    expect(damaged.configurationError, isNotNull);
    // 重键已迁出 blob（prefs 里没有），导出必须从文件层并回。
    expect(damaged.exportRecoveryData(), contains('旧资料'));
  });

  test('directory files load with gzip and plaintext fallback', () async {
    final dir = await Directory.systemTemp.createTemp('zgj_persist_');
    addTearDown(() => dir.delete(recursive: true));
    // DirectorySnapshotFiles 把重键落在传入目录下的 library/ 子目录。
    final library = Directory('${dir.path}${Platform.pathSeparator}library');
    await library.create(recursive: true);
    // 明文收藏文件（迁移窗口期旧版本写入）+ gzip 历史文件（新版形态）。
    await File(
      '${library.path}${Platform.pathSeparator}favorites$kSnapshotFileSuffix',
    ).writeAsString(jsonEncode([drama.toJson()]), flush: true);
    final historyJson = jsonEncode([
      WatchEntry(
        drama: next,
        episode: 2,
        position: 30,
        duration: 100,
        updatedAt: DateTime.now(),
      ).toJson(),
    ]);
    await File(
      '${library.path}${Platform.pathSeparator}history$kSnapshotFileSuffix',
    ).writeAsBytes(gzip.encode(utf8.encode(historyJson)), flush: true);

    SharedPreferences.resetStatic();
    final platform = FailingPreferences(const {});
    SharedPreferencesStorePlatform.instance = platform;
    final store = LocalStore(
      await SharedPreferences.getInstance(),
      files: DirectorySnapshotFiles(directory: dir),
    );
    addTearDown(store.dispose);

    expect(store.favorites.single.id, drama.id);
    expect(store.watched(next.id)?.episode, 2);
  });

  test(
    'backup restoration is one snapshot and never mixes old and new data',
    () async {
      final (store, platform, files) = await create({
        'plugin_secret': 'preserved',
      });
      await store.toggleFavorite(drama);
      await store.saveWatch(
        WatchEntry(
          drama: drama,
          episode: 1,
          position: 10,
          duration: 100,
          updatedAt: DateTime.now(),
        ),
      );
      final old = await store.exportBackup();
      final backup = jsonDecode(old) as Map<String, dynamic>;
      backup['themeMode'] = 'light';
      final library = (backup['libraries'] as Map)['default'] as Map;
      library.remove('followSync');
      library['favorites'] = [next.toJson()];
      library['followStates'] = {};
      library['history'] = [
        WatchEntry(
          drama: next,
          episode: 2,
          position: 30,
          duration: 100,
          updatedAt: DateTime.now(),
        ).toJson(),
      ];
      library['playback'] = const PlaybackPreferences(
        speed: 1.5,
        quality: 1080,
        autoAdvance: false,
      ).toJson();
      final content = jsonEncode(backup);
      for (final failure in ['false', 'throw', 'after']) {
        platform.failure = failure;
        await expectLater(
          store.importBackup(content),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
        expect(await store.exportBackup(), old);
        expect(await (await restart(platform, files)).exportBackup(), old);
      }
      platform.failure = '';
      final before = platform.snapshots;
      await store.importBackup(content);
      expect(platform.snapshots - before, 1);
      final restored = await restart(platform, files);
      expect(restored.favorites.single.id, next.id);
      expect(restored.history.single.episode, 2);
      expect(restored.themeMode, 'light');
      expect(restored.playbackPreferences.toJson(), library['playback']);
      expect(restored.preferences.getString('plugin_secret'), 'preserved');
      final compatible = jsonDecode(content) as Map<String, dynamic>;
      ((compatible['libraries'] as Map)['default'] as Map).remove('playback');
      await store.importBackup(jsonEncode(compatible));
      expect(
        store.playbackPreferences.toJson(),
        const PlaybackPreferences().toJson(),
      );
    },
  );

  test(
    'queued mutations preserve all successful records and isolate playback preferences',
    () async {
      final (store, platform, files) = await create();
      await Future.wait([
        store.toggleFavorite(drama),
        store.toggleFavorite(next),
      ]);
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: [],
        download: true,
        pin: 'abcdef12',
      );
      await store.setPlaybackPreferences(
        const PlaybackPreferences(speed: 1.5, quality: 720, autoAdvance: false),
      );
      await store.saveProfile(
        name: '访客',
        sources: ['hongguo'],
        download: false,
      );
      final visitor = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(visitor.id);
      expect(store.playbackPreferences.speed, 1);
      await store.setPlaybackPreferences(const PlaybackPreferences(speed: .75));
      await store.switchProfile('default', pin: 'abcdef12');
      expect(store.playbackPreferences.speed, 1.5);
      final restored = await restart(platform, files);
      expect(restored.locked, isTrue);
      await restored.switchProfile('default', pin: 'abcdef12');
      expect(restored.favorites.length, 2);
      expect(restored.playbackPreferences.autoAdvance, isFalse);
    },
  );

  for (final records in <Object>[
    'broken-json',
    '[]',
    jsonEncode([
      const LocalProfile(
        id: 'default',
        name: '管理员',
        admin: true,
        salt: '11111111111111111111111111111111',
        pinHash:
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
      ).toJson(),
      {'id': 'visitor', 'name': 7},
    ]),
    jsonEncode([
      {
        'id': 'default',
        'name': '管理员',
        'admin': true,
        'sources': [],
        'salt': 'bad',
      },
    ]),
  ]) {
    test(
      'damaged profiles remain locked without replacing raw data: $records',
      () async {
        final (store, platform, files) = await create({
          'profiles': records,
          'favorites': jsonEncode([drama.toJson()]),
        });
        expect(store.configurationError, isNotNull);
        expect(store.locked, isTrue);
        expect(store.profile.admin, isFalse);
        expect(store.canDownload, isFalse);
        expect(store.favorites, isEmpty);
        expect(store.sources, isEmpty);
        await expectLater(store.switchProfile('default'), throwsStateError);
        expect(platform.snapshots, 0);
        final restored = await restart(platform, files);
        expect(restored.configurationError, isNotNull);
        expect(restored.preferences.get('profiles'), records);
        expect(store.exportRecoveryData(), contains('旧资料'));
      },
    );
  }

  testWidgets(
    'damaged profile screen offers recovery without an unlocked administrator',
    (tester) async {
      final (store, _, _) = await create({'profiles': 'bad'});
      await tester.pumpWidget(
        MaterialApp(home: ProfilesScreen(store: store, locked: true)),
      );
      expect(find.text('从备份恢复'), findsOneWidget);
      expect(find.text('重新读取配置'), findsOneWidget);
      expect(find.text('导出原始配置'), findsOneWidget);
      expect(find.text('添加用户'), findsNothing);
      expect(find.text('管理员 · 全部权限'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
