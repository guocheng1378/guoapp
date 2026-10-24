import 'package:duanju_app/follow_state.dart';
import 'package:duanju_app/follow_updates.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'library_feature_fixtures.dart';

void main() {
  const first = LibraryFeatureRepository.first;
  const sweepKey = 'follow_update_sweep.v1';

  Future<(LocalStore, LibraryFeatureRepository, SharedPreferences)>
  create() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final store = LocalStore(prefs);
    addTearDown(store.dispose);
    return (store, LibraryFeatureRepository(), prefs);
  }

  test('sweep refreshes favorites, reports updates and stamps the run', () async {
    final (store, repository, prefs) = await create();
    await store.setFollowStatus(first, FollowStatus.watching);
    repository.details[first.id] = LibraryFeatureRepository.makeDetail(
      const Drama(
        id: 'hongguo:one',
        source: 'hongguo',
        title: '合成一号',
        episodes: 9,
      ),
      9,
    );

    final updated = await sweepFollowUpdates(
      repository,
      store,
      preferences: prefs,
    );

    expect(updated, 1);
    expect(repository.detailRequests, [first.id]);
    expect(store.favorites.single.episodes, 9);
    expect(prefs.getInt(sweepKey), greaterThan(0));
  });

  test('fresh timestamp skips the sweep entirely', () async {
    final (store, repository, prefs) = await create();
    await store.setFollowStatus(first, FollowStatus.watching);
    await prefs.setInt(sweepKey, DateTime.now().millisecondsSinceEpoch);

    final updated = await sweepFollowUpdates(
      repository,
      store,
      preferences: prefs,
    );

    expect(updated, 0);
    expect(repository.detailRequests, isEmpty);
  });

  test('no favorites means no requests and no stamp', () async {
    final (store, repository, prefs) = await create();

    final updated = await sweepFollowUpdates(
      repository,
      store,
      preferences: prefs,
    );

    expect(updated, 0);
    expect(repository.detailRequests, isEmpty);
    expect(prefs.getInt(sweepKey), isNull);
  });

  test('failed details stay silent and do not stamp the run', () async {
    final (store, repository, prefs) = await create();
    await store.setFollowStatus(first, FollowStatus.watching);
    repository.detailFailures.add(first.id);

    final updated = await sweepFollowUpdates(
      repository,
      store,
      preferences: prefs,
    );

    expect(updated, 0);
    expect(prefs.getInt(sweepKey), isNull);
  });

  test('second sweep within interval does not refetch stamped dramas', () async {
    final (store, repository, prefs) = await create();
    await store.setFollowStatus(first, FollowStatus.watching);
    repository.details[first.id] = LibraryFeatureRepository.makeDetail(
      const Drama(
        id: 'hongguo:one',
        source: 'hongguo',
        title: '合成一号',
        episodes: 9,
      ),
      9,
    );

    await sweepFollowUpdates(repository, store, preferences: prefs);
    final updated = await sweepFollowUpdates(
      repository,
      store,
      preferences: prefs,
    );

    expect(updated, 0);
    expect(repository.detailRequests, [first.id]);
  });
}
