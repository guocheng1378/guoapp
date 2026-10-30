library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'core_bridge.dart';
import 'local_store.dart';

/// 下载完成/失败的全局汇总。
///
/// 下载由原生引擎执行，Dart 侧只能通过 [AppRepository.downloads] 轮询
/// 观察任务状态。这里维护一个轻量差量轮询：
/// - 仅当存在活跃任务（或刚有任务入队/刚绑定）时才发起拉取，其余时刻
///   定时器空转，零开销；
/// - 对任务状态做差量：任务从非完成态变为完成态、从非失败态变为失败态
///   时累计未读计数，驱动底栏下载入口的徽标；
/// - 一批任务全部结束（活跃任务清零）且确有新增时，产出一句话汇总文案
///   供首页弹提示（「N 个下载完成」/「M 个下载失败」）。
///
/// 进入下载页时调用 [markSeen] 清零徽标，避免用户正看着下载页还累计。
class DownloadSummary extends ChangeNotifier {
  DownloadSummary._();

  static final DownloadSummary instance = DownloadSummary._();

  static const _interval = Duration(seconds: 2);

  AppRepository? _repository;
  LocalStore? _store;
  Timer? _timer;
  int _epoch = -1;
  bool _ticking = false;
  bool _watching = false;
  bool _primed = false;

  // 任务状态快照：id -> state。
  Map<String, String> _states = const {};
  // 已计过数的事件：无论完成还是失败，一个任务只计一次首个终态事件，
  // 防止「失败→重试→完成」被反复累计。
  final _counted = <String>{};

  /// 自上次 [markSeen] 以来的完成数。
  int completed = 0;

  /// 自上次 [markSeen] 以来的失败数。
  int failed = 0;

  /// 批次结束事件的序号（每产出一次汇总文案 +1），消费方据此去重。
  int batch = 0;

  /// 最近一次批次结束的汇总文案；空串表示暂无。
  String batchText = '';

  int get unread => completed + failed;

  /// 绑定仓库与本地存储并启动轮询；完成首次基线拉取后返回。
  /// 重复绑定以最后一次为准。首页侧用 unawaited 调用即可。
  Future<void> bind(AppRepository repository, LocalStore store) async {
    _repository = repository;
    _store = store;
    _timer ??= Timer.periodic(_interval, (_) => unawaited(tick()));
    _watching = true;
    await tick();
  }

  /// 通知有任务入队或被操作（重试、恢复等）：下一次轮询会拉取最新状态。
  /// 置位是同步幂等的，实际拉取由周期定时器执行（最迟一个间隔），避免
  /// 与在途拉取竞态。
  void poke() {
    _watching = true;
  }

  /// 进入下载页：清空未读徽标。
  void markSeen() {
    if (completed == 0 && failed == 0) return;
    completed = 0;
    failed = 0;
    notifyListeners();
  }

  void _resetForEpoch() {
    _states = const {};
    _counted.clear();
    _primed = false;
    completed = 0;
    failed = 0;
    batch = 0;
    batchText = '';
  }

  Future<void> tick() async {
    final repository = _repository;
    final store = _store;
    if (repository == null ||
        store == null ||
        _ticking ||
        !repository.supportsDownloads ||
        !store.canDownload) {
      return;
    }
    if (store.profileEpoch != _epoch) {
      // 换用户档：旧档任务与本档无关，全部重来。
      _epoch = store.profileEpoch;
      _resetForEpoch();
      _watching = true;
    } else if (!_watching) {
      return;
    }
    _ticking = true;
    try {
      final jobs = await repository.downloads();
      var changed = false;
      var hadActive = false;
      final states = <String, String>{};
      for (final job in jobs) {
        states[job.id] = job.state;
        if (job.active) hadActive = true;
        final previous = _states[job.id];
        if (previous == null) {
          // 冷启动首次拉取（_primed=false）只记基线快照，不把存量任务
          // 当成新结果；此后新出现的任务（入队后立即可见）若是终态则计数。
          if (_primed && !job.active) {
            completed += job.completed ? 1 : 0;
            failed += job.state == 'failed' ? 1 : 0;
            _counted.add(job.id);
            changed = true;
          }
          continue;
        }
        if (_counted.contains(job.id)) continue;
        if (job.completed && previous != 'completed') {
          completed++;
          _counted.add(job.id);
          changed = true;
        } else if (job.state == 'failed' && previous != 'failed') {
          failed++;
          _counted.add(job.id);
          changed = true;
        }
      }
      _states = states;
      _primed = true;
      // 活跃任务从有到无：一批结束，若确有未读则产出一次汇总文案。
      if (_watching && !hadActive && (completed > 0 || failed > 0)) {
        batch++;
        batchText = switch ((completed, failed)) {
          (0, final fails) => '$fails 个下载失败',
          (final done, 0) => '$done 个下载完成',
          (final done, final fails) => '$done 个下载完成，$fails 个失败',
        };
        changed = true;
      }
      _watching = hadActive;
      if (changed) notifyListeners();
    } catch (_) {
      // 轮询失败静默：下一轮重试。
    } finally {
      _ticking = false;
    }
  }

  /// 测试辅助：解除绑定并清空全部状态（含停掉定时器）。
  @visibleForTesting
  void unbind() {
    _timer?.cancel();
    _timer = null;
    _repository = null;
    _store = null;
    _watching = false;
    _ticking = false;
    _epoch = -1;
    _resetForEpoch();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }
}
