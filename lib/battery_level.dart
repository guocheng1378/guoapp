import 'dart:async';

import 'package:flutter/foundation.dart';

import 'app_layout.dart';

/// 一次电量读数。[level] 0~100，[charging] 是否在充电。
@immutable
class BatteryReading {
  const BatteryReading({required this.level, required this.charging});

  final int level;
  final bool charging;

  @override
  bool operator ==(Object other) =>
      other is BatteryReading &&
      other.level == level &&
      other.charging == charging;

  @override
  int get hashCode => Object.hash(level, charging);

  @override
  String toString() => 'BatteryReading($level%, charging: $charging)';
}

/// 播放器状态区的电量来源。
///
/// 通道复用 `duanju/device` 的 `battery` 方法（Android 走 BatteryManager，
/// Windows 走 GetSystemPowerStatus）。取不到数据（旧版本原生端没有该分支、
/// 台式机无电池、测试环境无桩）时 [reading] 保持 null，UI 整颗电池不渲染。
class BatteryLevel extends ChangeNotifier {
  BatteryLevel({
    this.interval = const Duration(seconds: 10),
    Future<BatteryReading?> Function()? reader,
  }) : _reader = reader ?? readChannel;

  /// 轮询间隔：电量变化是分钟级事件，10 秒足够，还不至于每帧唤醒原生。
  final Duration interval;

  final Future<BatteryReading?> Function() _reader;

  BatteryReading? _reading;
  Timer? _timer;
  bool _running = false;

  /// 串行化：上一次读数还没回来时不叠加请求（切后台再回前台会连续触发）。
  Future<void>? _inflight;

  BatteryReading? get reading => _reading;

  /// 开始轮询。重复调用无副作用。
  void start() {
    if (_running) return;
    _running = true;
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  /// 停止轮询（页面销毁时调用，避免定时器泄漏）。
  void stop() {
    _running = false;
    _timer?.cancel();
    _timer = null;
  }

  /// 回前台强制刷新一次（系统省电策略会冻结定时器）。
  void resumed() => unawaited(refresh());

  Future<void> refresh() {
    final pending = _inflight;
    if (pending != null) return pending;
    final future = _read().whenComplete(() => _inflight = null);
    _inflight = future;
    return future;
  }

  Future<void> _read() async {
    BatteryReading? next;
    try {
      next = await _reader();
    } catch (_) {
      // 通道缺失/原生异常一律按「读不到」处理，不打扰播放体验。
      next = null;
    }
    if (_disposedFlag) return;
    final changed = next != _reading;
    _reading = next;
    // 电量没变也要通知：状态区那个时钟是搭这趟车刷新的。电量本身十分钟才
    // 变一次，只在变化时通知会让画面上的时间长时间停在旧值。
    if (changed || next != null) notifyListeners();
  }

  bool _disposedFlag = false;

  @override
  void dispose() {
    _disposedFlag = true;
    stop();
    super.dispose();
  }

  /// 原生通道读数。任何异常（MissingPluginException / PlatformException /
  /// 返回结构不符）都返回 null。
  static Future<BatteryReading?> readChannel() async {
    try {
      final data = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'battery',
      );
      if (data == null) return null;
      final level = data['level'];
      if (level is! int) return null;
      return BatteryReading(
        level: level.clamp(0, 100),
        charging: data['charging'] == true,
      );
    } catch (_) {
      return null;
    }
  }
}
