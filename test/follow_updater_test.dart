import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/follow_updater.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

Drama _drama(String id, {int episodes = 3, String releaseStatus = ''}) =>
    Drama(
      id: 'hongguo:$id',
      source: 'hongguo',
      title: '合成$id',
      episodes: episodes,
      releaseStatus: releaseStatus,
    );

class _ControlledClock {
  _ControlledClock(this.value);
  DateTime value;
  DateTime call() => value;
}

/// 每次调用前进 12 小时：让后台轮次在测试里持续「到期」。
class _AdvancingClock {
  _AdvancingClock(this.value);
  DateTime value;
  DateTime call() {
    final now = value;
    value = value.add(const Duration(hours: 12));
    return now;
  }
}

class _ReadOnlyRepository extends LibraryFeatureRepository {
  @override
  bool get supportsSourceManagement => false;
}

Future<(LocalStore, LibraryFeatureRepository)> create() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = LocalStore(prefs);
  addTearDown(store.dispose);
  return (store, LibraryFeatureRepository());
}

void main() {
  test('round honors limit and rotates least-recently-checked first',
      () async {
    final (store, repository) = await create();
    final dramas = [for (var i = 1; i <= 12; i++) _drama('d$i')];
    for (final drama in dramas) {
      await store.setFollowStatus(drama, FollowStatus.watching);
    }
    // 全部超过 6h 去重窗；d1 最久未查，d12 最新。
    final checks = <String, FollowCheck>{
      for (var i = 1; i <= 12; i++)
        'hongguo:d$i': FollowCheck(
          DateTime.now().subtract(Duration(hours: 40 - i)),
        ),
    };
    await store.saveFollowChecks(checks);

    final updater = FollowUpdater(repository, store, limit: 10);
    expect(await updater.run(), 0);
    expect(repository.detailRequests, [
      for (var i = 1; i <= 10; i++) 'hongguo:d$i',
    ]);
    // 检查记录已按轮次刷新（前 10 部的时间戳接近现在）。
    for (var i = 1; i <= 10; i++) {
      final check = store.followChecks['hongguo:d$i']!;
      expect(
        check.checkedAt.difference(DateTime.now()).inMinutes.abs(),
        lessThan(2),
      );
    }

    await updater.run();
    expect(
      repository.detailRequests.sublist(10),
      ['hongguo:d11', 'hongguo:d12'],
    );
  });

  test('round reports updates and fires the callback', () async {
    final (store, repository) = await create();
    final drama = _drama('one', episodes: 3);
    await store.setFollowStatus(drama, FollowStatus.watching);
    repository.details[drama.id] = LibraryFeatureRepository.makeDetail(
      _drama('one', episodes: 9),
      9,
    );

    final notified = <int>[];
    final updater = FollowUpdater(repository, store, onUpdated: notified.add);

    expect(await updater.run(), 1);
    expect(notified, [1]);
    expect(store.favorites.single.episodes, 9);
  });

  test('failed check backs off exponentially', () async {
    final (store, repository) = await create();
    final drama = _drama('one');
    await store.setFollowStatus(drama, FollowStatus.watching);
    repository.detailFailures.add(drama.id);

    final clock = _ControlledClock(DateTime(2026, 10, 22, 12));
    final updater = FollowUpdater(repository, store, clock: clock.call);

    expect(await updater.run(), 0);
    expect(store.followChecks[drama.id]!.failures, 1);
    expect(repository.detailRequests, ['hongguo:one']);

    // 退避窗内（6h×2=12h）不再检查。
    clock.value = clock.value.add(const Duration(hours: 7));
    expect(await updater.run(), 0);
    expect(repository.detailRequests, ['hongguo:one']);

    // 越过退避窗后重试，失败计数累加。
    clock.value = clock.value.add(const Duration(hours: 6));
    expect(await updater.run(), 0);
    expect(repository.detailRequests, ['hongguo:one', 'hongguo:one']);
    expect(store.followChecks[drama.id]!.failures, 2);
  });

  test('round skips planned, manually watched and finished dramas',
      () async {
    final (store, repository) = await create();
    await store.setFollowStatus(_drama('planned'), FollowStatus.planned);
    await store.setFollowStatus(_drama('manual'), FollowStatus.watched);
    await store.setFollowStatus(
      _drama('finished', releaseStatus: 'finished'),
      FollowStatus.watching,
    );
    await store.setFollowStatus(_drama('watching'), FollowStatus.watching);

    final updater = FollowUpdater(repository, store);
    await updater.run();

    expect(repository.detailRequests, ['hongguo:watching']);
  });

  test('round skips dramas whose source is switched off', () async {
    final (store, repository) = await create();
    await store.setFollowStatus(_drama('one'), FollowStatus.watching);
    await store.setSourceEnabled('hongguo', false);

    final updater = FollowUpdater(repository, store);
    expect(await updater.run(), 0);
    expect(repository.detailRequests, isEmpty);
  });

  test('disposed updater aborts the round without write-back', () async {
    final (store, repository) = await create();
    await store.setFollowStatus(_drama('one'), FollowStatus.watching);

    final disposed = FollowUpdater(repository, store);
    disposed.dispose();
    expect(await disposed.run(), 0);

    expect(repository.detailRequests, isEmpty);
    expect(store.followChecks, isEmpty);
  });

  test('locked store aborts the round without write-back', () async {
    final (store, repository) = await create();
    await store.setFollowStatus(_drama('one'), FollowStatus.watching);
    // 默认用户无密码时 lock() 是空操作，先给管理员设密。
    await store.saveProfile(
      id: 'default',
      name: '管理员',
      sources: [for (final site in SourceSite.values) site.id],
      download: true,
      pin: '123456',
    );

    final updater = FollowUpdater(repository, store);
    store.lock();
    expect(store.locked, isTrue);
    expect(await updater.run(), 0);

    expect(repository.detailRequests, isEmpty);
    expect(store.followChecks, isEmpty);
  });

  test('start waits for the delay then runs periodically until dispose',
      () async {
    final (store, repository) = await create();
    await store.setFollowStatus(_drama('a'), FollowStatus.watching);
    await store.setFollowStatus(_drama('b'), FollowStatus.watching);

    final clock = _AdvancingClock(DateTime(2026, 10, 22, 12));
    final updater = FollowUpdater(
      repository,
      store,
      startDelay: const Duration(milliseconds: 10),
      interval: const Duration(milliseconds: 20),
      limit: 1,
      clock: clock.call,
    );
    updater.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    // 轮次持续推进（时钟每次 +12h，两部交替到期）。
    // 首轮两部都未检查过，排序并列时取哪部不定，此后严格交替。
    expect(repository.detailRequests.length, greaterThanOrEqualTo(4));
    final firstIsA = repository.detailRequests.first == 'hongguo:a';
    expect(firstIsA || repository.detailRequests.first == 'hongguo:b', isTrue);
    for (var i = 1; i < repository.detailRequests.length; i++) {
      final expected = (i.isEven) == firstIsA ? 'hongguo:a' : 'hongguo:b';
      expect(repository.detailRequests[i], expected);
    }

    final frozen = List.of(repository.detailRequests);
    updater.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(repository.detailRequests, frozen);
  });

  test('start does nothing without source management support', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    addTearDown(store.dispose);
    final repository = _ReadOnlyRepository();
    await store.setFollowStatus(_drama('one'), FollowStatus.watching);

    final updater = FollowUpdater(
      repository,
      store,
      startDelay: const Duration(milliseconds: 10),
    );
    updater.start();
    await Future<void>.delayed(const Duration(milliseconds: 150));

    expect(repository.detailRequests, isEmpty);
    updater.dispose();
  });
}
