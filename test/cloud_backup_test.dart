import 'dart:convert';

import 'package:duanju_app/cloud_backup.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/lan_sync_models.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 记录 webdav 调用并按脚本返回结果的假仓储。信封加密在 Go 侧完成，
/// Dart 编排测试直接让明文备份体在 upload 与 download 之间往返。
class FakeWebdavRepository extends AppRepository {
  bool exists = false;
  String? data;
  Object? failure;
  final List<String> commands = [];
  final List<Map<String, dynamic>> payloads = [];

  @override
  Future<Map<String, dynamic>> webdav(
    String command,
    Map<String, dynamic> payload,
  ) async {
    commands.add(command);
    payloads.add(payload);
    if (failure case final failure?) throw failure;
    switch (command) {
      case 'test':
        return {'exists': exists, 'size': data?.length ?? 0};
      case 'upload':
        return {'ok': true, 'size': payload['data']?.length ?? 0};
      case 'download':
        if (!exists || data == null) return {'exists': false};
        return {'exists': true, 'size': data!.length, 'data': data};
    }
    throw UnimplementedError(command);
  }

  // 云备份测试只走 webdav 动作，其余成员补 no-op 占位（对齐 fixtures.dart
  // 惯例：显式实现而非 noSuchMethod，基类新增抽象成员时此处即时暴露）。
  @override
  Future<void> initialize() async {}
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async => throw UnimplementedError(source);
  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async =>
      throw UnimplementedError(source);
  @override
  Future<String> cover(Drama drama, {bool force = false}) async => '';
  @override
  Future<DramaDetail> detail(Drama drama) async =>
      throw UnimplementedError(drama.id);
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => throw UnimplementedError(episode.id);
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async => current;
  @override
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route) async =>
      current;
  @override
  Future<void> cancelPlayback() async {}
  @override
  Future<void> release(String session) async {}
}

const readyConfig = CloudBackupConfig(
  url: 'https://dav.jianguoyun.com/dav/duanju_backup/backup.json',
  username: 'user@example.com',
  password: 'app-password',
  backupPassword: 'backup-pass',
);

/// LanVersion.fromJson 要求设备键为 32 位十六进制，测试用固定假设备指纹。
const testDeviceKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '旧资料');
  const next = Drama(id: 'hongguo:2', source: 'hongguo', title: '新资料');

  Future<LocalStore> newStore() async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    return store;
  }

  Future<CloudBackup> newService(FakeWebdavRepository repository) async {
    SharedPreferences.setMockInitialValues({});
    return CloudBackup(await SharedPreferences.getInstance(), repository);
  }

  group('CloudBackupConfig', () {
    test('ready 要求地址、账号与两组密码齐全', () {
      expect(const CloudBackupConfig().ready, isFalse);
      expect(readyConfig.copyWith(url: 'https://x.com/data.json').ready, isFalse);
      expect(readyConfig.copyWith(username: '').ready, isFalse);
      expect(readyConfig.copyWith(password: '').ready, isFalse);
      expect(readyConfig.copyWith(backupPassword: '').ready, isFalse);
      expect(readyConfig.ready, isTrue);
    });

    test('持久化往返保留进度字段，坏数据回落默认配置', () async {
      final repository = FakeWebdavRepository();
      final service = await newService(repository);
      final config = readyConfig.copyWith(
        autoBackup: true,
        lastBackupAt: DateTime.utc(2026, 10, 30, 8),
        lastBackupHash: 'abc',
      );
      await service.save(config);
      final loaded = service.load();
      expect(loaded.url, config.url);
      expect(loaded.autoBackup, isTrue);
      expect(loaded.lastBackupHash, 'abc');
      expect(
        loaded.lastBackupAt?.millisecondsSinceEpoch,
        config.lastBackupAt!.millisecondsSinceEpoch,
      );

      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(CloudBackup.configKey, 'not-json');
      expect(service.load().url, '');
      expect(service.load().ready, isFalse);
    });
  });

  group('CloudBackup 备份与上传', () {
    test('build 产出带 meta 的备份体，hash 只随内容变化', () async {
      final store = await newStore();
      final service = await newService(FakeWebdavRepository());
      final built = await service.build(store);
      final data = jsonDecode(built.content) as Map<String, dynamic>;
      expect(data['meta'], isA<Map<dynamic, dynamic>>());
      expect((data['profiles'] as List).length, greaterThanOrEqualTo(1));
      expect(built.profiles, greaterThanOrEqualTo(1));
      expect(built.size, built.content.length);
      // meta 不参与指纹：内容不变则 hash 不变。
      final again = await service.build(store);
      expect(again.hash, built.hash);
    });

    test('backupNow 未就绪抛错且不访问网络；就绪时上传明文并记录进度', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      await expectLater(
        service.backupNow(store),
        throwsA(isA<AppFailure>()),
      );
      expect(repository.commands, isEmpty);

      await service.save(readyConfig);
      final built = await service.backupNow(store);
      expect(repository.commands, ['upload']);
      final payload = repository.payloads.single;
      expect(payload['url'], readyConfig.url);
      expect(payload['username'], readyConfig.username);
      expect(payload['password'], readyConfig.password);
      expect(payload['backupPassword'], readyConfig.backupPassword);
      expect(payload['data'], built.content);
      final loaded = service.load();
      expect(loaded.lastBackupHash, built.hash);
      expect(loaded.lastBackupAt, isNotNull);
    });

    test('backupNow 返回异常信封时抛错且不写进度', () async {
      final repository = FakeWebdavRepository()
        ..data = null;
      final store = await newStore();
      final service = await newService(repository);
      await service.save(readyConfig);
      repository.commands.add('upload');
      repository.payloads.add(const {});
      repository.failure = AppFailure('网络错误');
      await expectLater(
        service.backupNow(store),
        throwsA(isA<AppFailure>()),
      );
      expect(service.load().lastBackupAt, isNull);
    });
  });

  group('CloudBackup.maybeAutoBackup', () {
    test('未开启或未就绪时静默跳过', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      expect(await service.maybeAutoBackup(store), isFalse);
      expect(repository.commands, isEmpty);
      await service.save(readyConfig);
      expect(await service.maybeAutoBackup(store), isFalse);
      expect(repository.commands, isEmpty);
    });

    test('内容无变化或间隔不足时跳过，变化后重新上传', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      await service.save(readyConfig.copyWith(autoBackup: true));
      expect(await service.maybeAutoBackup(store), isTrue);
      expect(repository.commands, ['upload']);
      final uploaded = service.load().lastBackupHash;
      expect(uploaded, isNotNull);

      // 内容不变：跳过。
      expect(await service.maybeAutoBackup(store), isFalse);
      expect(repository.commands, ['upload']);

      // 内容变了但距上次备份不足 12 小时：跳过。
      await store.toggleFavorite(next);
      expect(await service.maybeAutoBackup(store), isFalse);
      expect(repository.commands, ['upload']);

      // 把上次备份时间拨回 13 小时前：重新上传并更新指纹。
      await service.save(
        service.load().copyWith(
          lastBackupAt: DateTime.now().subtract(const Duration(hours: 13)),
        ),
      );
      expect(await service.maybeAutoBackup(store), isTrue);
      expect(repository.commands, ['upload', 'upload']);
      expect(service.load().lastBackupHash, isNot(uploaded));
    });

    test('上传失败静默返回 false 且不写进度', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      await service.save(readyConfig.copyWith(autoBackup: true));
      repository.failure = AppFailure('网络错误');
      expect(await service.maybeAutoBackup(store), isFalse);
      expect(service.load().lastBackupAt, isNull);
      expect(service.load().lastBackupHash, isNull);
    });
  });

  group('CloudBackup 恢复', () {
    test('云端没有备份返回 null，内容无效抛错', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      await service.save(readyConfig);
      expect(await service.fetch(readyConfig, store), isNull);

      repository.exists = true;
      repository.data = 'not json';
      await expectLater(
        service.fetch(readyConfig, store),
        throwsA(isA<AppFailure>()),
      );
    });

    test('fetch 剥离 meta 并通过 validateBackup', () async {
      final repository = FakeWebdavRepository();
      final store = await newStore();
      final service = await newService(repository);
      final built = await service.build(store);
      repository.exists = true;
      repository.data = built.content;
      final remote = await service.fetch(readyConfig, store);
      expect(remote, isNotNull);
      expect(remote!.meta.platform, isNotEmpty);
      expect(remote.meta.exportedAt, isNotNull);
      expect(remote.data.containsKey('meta'), isFalse);
      expect(remote.size, built.content.length);
    });

    test('覆盖恢复替换本机全部数据', () async {
      final repository = FakeWebdavRepository();
      final service = await newService(repository);
      final source = await newStore();
      await source.toggleFavorite(drama);
      await source.saveWatch(
        WatchEntry(
          drama: drama,
          episode: 3,
          position: 40,
          duration: 100,
          updatedAt: DateTime.now(),
        ),
      );
      repository.exists = true;
      repository.data = (await service.build(source)).content;

      final target = await newStore();
      await target.toggleFavorite(next);
      final remote = await service.fetch(readyConfig, target);
      await service.restoreReplace(target, remote!);
      expect(target.favorites.single.id, drama.id);
      expect(target.watched(drama.id)?.episode, 3);
    });

    test('合并追剧只并入当前用户，与既有记录双向保留', () async {
      final repository = FakeWebdavRepository();
      final service = await newService(repository);
      final source = await newStore();
      await source.mergeCloudRecords([
        followRecord(drama, watch: WatchEntry(
          drama: drama,
          episode: 5,
          position: 66,
          duration: 100,
          updatedAt: DateTime.now(),
        )),
      ]);
      repository.exists = true;
      repository.data = (await service.build(source)).content;

      final target = await newStore();
      await target.toggleFavorite(next);
      final remote = await service.fetch(readyConfig, target);
      final count = await service.restoreMergeFollow(target, remote!);
      expect(count.added, 1);
      // 云端记录并入了，本机原有收藏也还在。
      expect(target.favorites.map((row) => row.id), containsAll(<String>[
        drama.id,
        next.id,
      ]));
      expect(target.watched(drama.id)?.episode, 5);
    });
  });
}

LanRecord followRecord(Drama target, {required WatchEntry watch}) {
  var counter = 0;
  LanCell cell(Object? value) {
    counter++;
    return LanCell([LanValue(LanVersion({testDeviceKey: counter}), value)]);
  }

  return LanRecord(
    drama: target,
    member: cell(true),
    // 与生产写入（lan_sync_models.dart cell({'status': .., 'manual': ..})）同形状。
    status: cell({'status': 'watching', 'manual': false}),
    progress: cell(lanProgress(watch)),
  );
}
