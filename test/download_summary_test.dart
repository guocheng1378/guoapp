import 'package:duanju_app/download_summary.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _SummaryRepository extends FixtureRepository {
  List<DownloadJob> jobs = [];
  int calls = 0;
  bool downloadSupported = true;

  @override
  bool get supportsDownloads => downloadSupported;

  @override
  Future<List<DownloadJob>> downloads() async {
    calls++;
    return List.of(jobs);
  }
}

DownloadJob _job(String id, String state) => DownloadJob(
  id: id,
  drama: FixtureRepository.free,
  episode: Episode({'id': id, 'currentEpisode': 1}, 1),
  state: state,
  bytes: 1024,
  total: 2048,
  progress: .5,
  actualQuality: 1080,
);

Future<LocalStore> _newStore() async {
  SharedPreferences.setMockInitialValues({});
  return LocalStore(await SharedPreferences.getInstance());
}

void main() {
  // 单例状态跨用例隔离：每个用例结束解除绑定（含停定时器、清快照计数）。
  tearDown(() {
    DownloadSummary.instance.unbind();
  });

  test('冷启动存量任务不计数，只记基线快照', () async {
    final repo = _SummaryRepository()
      ..jobs = [_job('1', 'completed'), _job('2', 'failed')];
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    expect(summary.unread, 0);
    expect(summary.batch, 0);
    expect(summary.batchText, isEmpty);
  });

  test('新任务从活跃到完成累计未读，批次结束时产出汇总', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);

    // 模拟真实调用序：入队后 poke 唤醒轮询。
    repo.jobs = [_job('1', 'queued')];
    summary.poke();
    await summary.tick();
    expect(summary.unread, 0); // 下载中不计数

    repo.jobs = [_job('1', 'completed')];
    await summary.tick();
    expect(summary.completed, 1);
    expect(summary.unread, 1);
    expect(summary.batch, 1);
    expect(summary.batchText, '1 个下载完成');
  });

  test('失败任务累计失败数并产出失败文案', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    repo.jobs = [_job('1', 'queued')];
    summary.poke();
    await summary.tick();
    repo.jobs = [_job('1', 'failed')];
    await summary.tick();
    expect(summary.failed, 1);
    expect(summary.completed, 0);
    expect(summary.batchText, '1 个下载失败');
  });

  test('入队即已完成的任务同样计数', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    repo.jobs = [_job('9', 'completed')];
    summary.poke();
    await summary.tick();
    expect(summary.completed, 1);
    expect(summary.unread, 1);
  });

  test('同一任务失败后重试成功不重复计数', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    repo.jobs = [_job('1', 'queued')];
    summary.poke();
    await summary.tick();
    repo.jobs = [_job('1', 'failed')];
    await summary.tick();
    expect(summary.failed, 1);
    // 用户重试：resume 操作唤醒轮询。
    repo.jobs = [_job('1', 'downloading')];
    summary.poke();
    await summary.tick();
    repo.jobs = [_job('1', 'completed')];
    await summary.tick();
    // 仍只算那一次失败事件，不叠加「完成」。
    expect(summary.failed, 1);
    expect(summary.completed, 0);
    expect(summary.unread, 1);
  });

  test('markSeen 清空未读徽标', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    repo.jobs = [_job('1', 'queued'), _job('2', 'queued')];
    summary.poke();
    await summary.tick();
    repo.jobs = [
      _job('1', 'completed'),
      _job('2', 'completed'),
      _job('3', 'failed'),
    ];
    await summary.tick();
    expect(summary.unread, 3);
    expect(summary.batchText, '2 个下载完成，1 个失败');
    summary.markSeen();
    expect(summary.unread, 0);
    expect(summary.completed, 0);
    expect(summary.failed, 0);
  });

  test('切换用户档后汇总清零重新建基线', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    repo.jobs = [_job('1', 'queued')];
    summary.poke();
    await summary.tick();
    repo.jobs = [_job('1', 'completed')];
    await summary.tick();
    expect(summary.unread, 1);

    await store.switchProfile(store.profile.id);
    repo.jobs = [_job('1', 'completed')];
    await summary.tick();
    expect(summary.unread, 0);
    expect(summary.batch, 0);
  });

  test('无活跃任务时轮询空转不重复请求', () async {
    final repo = _SummaryRepository();
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    expect(repo.calls, 1); // 绑定时的基线拉取
    await summary.tick();
    expect(repo.calls, 1); // 无活跃任务：tick 直接返回
    summary.poke();
    await summary.tick();
    expect(repo.calls, 2); // poke 后恢复拉取
  });

  test('仓库不支持下载时不发起请求', () async {
    final repo = _SummaryRepository()..downloadSupported = false;
    final store = await _newStore();
    final summary = DownloadSummary.instance;
    await summary.bind(repo, store);
    expect(repo.calls, 0);
    expect(summary.unread, 0);
  });
}
