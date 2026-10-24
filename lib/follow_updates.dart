import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import 'core_bridge.dart';
import 'local_store.dart';

/// 追剧更新主动检测：后台逐部拉取追剧详情并回写 store，让剧卡上的
/// 「N 集更新」角标自动亮起，无需用户逐部点开详情。
///
/// 设计约束：
/// - **6 小时去重**：时间戳存 SharedPreferences；全量跑完且至少一部
///   成功才记录（断网/全挂时下次启动重试）；
/// - **并发 2 worker + 400ms 节流**：不抢播放/浏览的带宽；
/// - 上限 [sweepLimit] 部（favorites 按追剧时间倒序，最新的优先）；
/// - 豆瓣等无详情源的 detail 抛错静默；profileEpoch 变化（切用户）
///   立即中止且不写时间戳。
const _sweepKey = 'follow_update_sweep.v1';
const _sweepInterval = Duration(hours: 6);
const sweepLimit = 24;
const _workerCount = 2;
const _throttle = Duration(milliseconds: 400);

/// 返回本轮检测出的「有更新」部数（供调用方提示）。
Future<int> sweepFollowUpdates(
  AppRepository repository,
  LocalStore store, {
  SharedPreferences? preferences,
  Duration throttle = _throttle,
  int limit = sweepLimit,
}) async {
  final prefs = preferences ?? await SharedPreferences.getInstance();
  final epoch = store.profileEpoch;
  final last = prefs.getInt(_sweepKey) ?? 0;
  final now = DateTime.now().millisecondsSinceEpoch;
  if (now - last < _sweepInterval.inMilliseconds) return 0;

  final targets = store.favorites.take(limit).toList();
  if (targets.isEmpty) return 0;
  final known = {for (final drama in targets) drama.id: drama.episodes};

  var index = 0;
  var success = 0;
  var updated = 0;

  Future<void> worker() async {
    while (index < targets.length) {
      final current = targets[index];
      index++;
      // 全体 worker 共享节流：每个请求之间至少隔 [throttle]，
      // 两个 worker 交错后实际节奏 = 每 throttle 窗口最多 2 个请求。
      if (index > _workerCount) await Future<void>.delayed(throttle);
      if (store.profileEpoch != epoch) return;
      if (!store.allowsSource(current.source)) continue;
      try {
        final detail = await repository.detail(current);
        if (store.profileEpoch != epoch) return;
        await store.refreshDrama(detail.drama);
        success++;
        if (detail.drama.episodes > (known[current.id] ?? 0)) updated++;
      } catch (_) {
        // 受限源/豆瓣/断网：静默跳过，打开详情时 merge 仍会修正。
      }
    }
  }

  await Future.wait([for (var i = 0; i < _workerCount; i++) worker()]);

  if (store.profileEpoch != epoch || success == 0) return updated;
  await prefs.setInt(_sweepKey, DateTime.now().millisecondsSinceEpoch);
  return updated;
}
