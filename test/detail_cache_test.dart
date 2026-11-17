import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

class _Repo extends FixtureRepository {
  int calls = 0;
  bool empty = false;
  final drama = const Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    title: '测试短剧',
  );

  Future<DramaDetail> get() => detailCached(drama, () async {
    calls++;
    return DramaDetail(
      drama,
      empty ? const <Episode>[] : [Episode(const {'id': 'e1'}, 1)],
    );
  });
}

void main() {
  test('正常详情命中缓存：同剧二次点按零网络', () async {
    final repo = _Repo();
    expect((await repo.get()).episodes, hasLength(1));
    expect((await repo.get()).episodes, hasLength(1));
    expect(repo.calls, 1);
  });

  test('站源空包返回 0 集不入缓存：下次点开会重新取详情', () async {
    final repo = _Repo()..empty = true;
    expect((await repo.get()).episodes, isEmpty);
    expect((await repo.get()).episodes, isEmpty);
    // 旧实现会把空结果缓存 30 分钟，追剧里再点就一直「没有视频」。
    expect(repo.calls, 2);
  });

  test('空包之后站点恢复：正常详情重新进缓存', () async {
    final repo = _Repo()..empty = true;
    await repo.get();
    repo.empty = false;
    expect((await repo.get()).episodes, hasLength(1));
    expect((await repo.get()).episodes, hasLength(1));
    expect(repo.calls, 2);
  });

  test('invalidateDetail 清缓存后强制重取', () async {
    final repo = _Repo();
    await repo.get();
    repo.invalidateDetail(repo.drama);
    await repo.get();
    expect(repo.calls, 2);
  });
}
