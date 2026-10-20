import 'models.dart';

enum PlaybackRecoveryAction { reuse, alternative, refresh, stop }

class PlaybackRecovery {
  static const maxAttempts = 4;
  static const maxRefreshes = 2;
  int _attempts = 0;
  int _refreshes = 0;
  bool _reused = false;

  void reset() {
    _attempts = 0;
    _refreshes = 0;
    _reused = false;
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
    if (_refreshes < maxRefreshes) {
      _attempts++;
      _refreshes++;
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
