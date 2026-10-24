import 'dart:async';

import 'core_bridge.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';

/// 后台定期追剧更新（移植自 Xanerix/guoapp 3d1fa2b，降级版：
/// 复用 repository.detail，不引入 Go followCheck action）：
/// 启动让路 [startDelay] 后首轮，之后每 [interval] 一轮；每轮最多
/// [limit] 部，按「上次检查时间」升序轮转（从未检查的排最前）；
/// 同一部剧 [recheck] 内不重复检查，失败按 6h × 2^failures 指数退避
/// （封顶 8 倍 = 48h）；只看「在看」与自动判定「已看」的剧，跳过
/// 想看、手动标记已看、已完结与已关闭站源；切换用户或锁定立即中止
/// 本轮且不写回；检查记录按用户存档。
///
/// 与一次性 sweep（follow_updates.dart）的关系：sweep 保留为工具函数，
/// 首页改由本 updater 驱动持续后台检查。
class FollowUpdater {
  FollowUpdater(
    this.repository,
    this.store, {
    this.startDelay = const Duration(seconds: 30),
    this.interval = const Duration(minutes: 30),
    this.recheck = const Duration(hours: 6),
    this.limit = 10,
    this.onUpdated,
    DateTime Function()? clock,
  }) : _epoch = store.profileEpoch,
       _clock = clock ?? DateTime.now;

  static const _maxBackoffShift = 3;

  final AppRepository repository;
  final LocalStore store;
  final Duration startDelay;
  final Duration interval;
  final Duration recheck;
  final int limit;
  /// 本轮检出「有更新」的部数（供调用方弹提醒；后台轮次不弹噪声）。
  final void Function(int)? onUpdated;
  final DateTime Function() _clock;
  final int _epoch;

  Timer? _timer;
  bool _running = false;
  bool _disposed = false;

  bool get _valid =>
      !_disposed && !store.locked && _epoch == store.profileEpoch;

  void start() {
    if (_timer != null || !repository.supportsSourceManagement || !_valid) {
      return;
    }
    _timer = Timer(startDelay, () {
      _timer = Timer.periodic(interval, (_) => _tick());
      _tick();
    });
  }

  void _tick() => unawaited(run().catchError((Object _) => 0));

  /// 本轮到期的剧：过滤掉不想看/手动已看/已完结/源已关闭的，
  /// 再按「距下次可检查的时间」排出前 [limit] 部。
  List<Drama> _due(Map<String, FollowCheck> checks) {
    final now = _clock();
    final never = DateTime.fromMillisecondsSinceEpoch(0);
    final items = store.favorites.where((drama) {
      final state = store.following(drama.id);
      if (state == null ||
          state.manuallyWatched ||
          state.status == FollowStatus.planned ||
          const {'finished', 'completed'}.contains(drama.releaseStatus)) {
        return false;
      }
      if (!store.allowsSource(drama.source)) return false;
      final check = checks[drama.id];
      if (check == null) return true;
      // 失败指数退避：6h × 2^failures，封顶 8 倍（48h）。
      final shift = check.failures <= 0
          ? 0
          : check.failures >= _maxBackoffShift
          ? _maxBackoffShift
          : check.failures;
      return !now.isBefore(check.checkedAt.add(recheck * (1 << shift)));
    }).toList();
    items.sort(
      (a, b) =>
          (checks[a.id]?.checkedAt ?? never).compareTo(
            checks[b.id]?.checkedAt ?? never,
          ),
    );
    return items.take(limit).toList();
  }

  /// 执行一轮检查（测试可直接调用，不必等定时器）。
  Future<int> run() async {
    if (_running || !_valid) return 0;
    _running = true;
    var updated = 0;
    try {
      final checks = store.followChecks;
      final updates = <Drama>[];
      for (final drama in _due(checks)) {
        if (!_valid) return 0;
        try {
          final detail = await repository.detail(drama);
          updates.add(detail.drama);
          if (detail.drama.episodes > drama.episodes) updated++;
          checks[drama.id] = FollowCheck(_clock());
        } catch (_) {
          // 受限源/豆瓣/断网：静默记失败，下一轮指数退避后重试。
          checks[drama.id] = FollowCheck(
            _clock(),
            failures: (checks[drama.id]?.failures ?? 0) + 1,
          );
        }
      }
      if (!_valid) return 0;
      if (updates.isNotEmpty) await store.refreshDramas(updates);
      await store.saveFollowChecks(checks, epoch: _epoch);
      if (updated > 0) onUpdated?.call(updated);
      return updated;
    } finally {
      _running = false;
    }
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
  }
}
