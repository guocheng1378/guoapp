import 'models.dart';

enum PlaybackRecoveryAction { reuse, alternative, refresh, route, stop }

class PlaybackRecovery {
  static const maxAttempts = 4;
  // 一次故障最多重解析一次：refresh 会重跑整条解析链（真果鉴可达十几
  // 秒），两轮叠加就是「切集后一直转圈」。剩下的兜底交给换线路与用户
  // 手动重试。
  static const maxRefreshes = 1;
  // 全局冷却跨 reset 保留：连续切集/快速故障时不让全链解析反复叠加。
  static const refreshCooldown = Duration(seconds: 60);
  int _attempts = 0;
  int _refreshes = 0;
  bool _reused = false;
  DateTime? _lastRefresh;

  void reset() {
    _attempts = 0;
    _refreshes = 0;
    _reused = false;
    // 故意不清 _lastRefresh：换集后短时间内仍需受全局冷却约束。
  }

  /// 恢复顺序：原地重开 → 换线路 → 重新解析。
  ///
  /// 原地重开（reuse）零网络、零解析开销：源站首字节抖动导致的卡顿
  /// 大概率在重开后自愈，不必付出「重新解析要等数秒」的代价；换线路
  /// 与重新解析依次兜底更严重的问题。
  PlaybackRecoveryAction next(PlaybackPlan plan) {
    if (_attempts >= maxAttempts) {
      return PlaybackRecoveryAction.stop;
    }
    if (!_reused) {
      _reused = true;
      _attempts++;
      return PlaybackRecoveryAction.reuse;
    }
    if (plan.hasAlternative) {
      _attempts++;
      return PlaybackRecoveryAction.alternative;
    }
    if (_refreshes < maxRefreshes &&
        (_lastRefresh == null ||
            DateTime.now().difference(_lastRefresh!) >= refreshCooldown)) {
      _attempts++;
      _refreshes++;
      _lastRefresh = DateTime.now();
      return PlaybackRecoveryAction.refresh;
    }
    return PlaybackRecoveryAction.stop;
  }
}

class PlaybackHealth {
  /// 卡顿判定阈值。源站首字节实测可等 0.3~16 秒，20 秒太紧，
  /// 正常慢响应会被误判成卡死并触发整段重建。
  static const stallTimeout = Duration(seconds: 45);
  Duration? _position;
  DateTime? _lastProgress;

  void reset() {
    _position = null;
    _lastProgress = null;
  }

  bool stalled({
    required Duration position,
    required bool playing,
    required bool foreground,
    required DateTime now,
  }) {
    if (!playing || !foreground || position != _position) {
      _position = position;
      _lastProgress = now;
      return false;
    }
    _lastProgress ??= now;
    return now.difference(_lastProgress!) >= stallTimeout;
  }
}
