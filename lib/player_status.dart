import 'dart:async';

import 'package:flutter/material.dart';

/// 网速文案（移植自上游 player_status.dart）：≥1 MB/s 保留一位小数，
/// 其余取整到 KB/s。不显示 0 值，避免静止画面时状态栏跳动。
String formatNetworkSpeed(int bytesPerSecond) {
  if (bytesPerSecond >= 1024 * 1024) {
    return '${(bytesPerSecond / 1024 / 1024).toStringAsFixed(1)} MB/s';
  }
  return '${(bytesPerSecond / 1024).round()} KB/s';
}

/// 时钟文案 HH:mm（24 小时制）。
String formatClock(DateTime now) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${two(now.hour)}:${two(now.minute)}';
}

/// 播放页右上角的实时网速。每秒拉一次读数，读数没变就不重建。
/// 用回调而不是仓库类型，测试里可以直接塞一个固定值。
class NetworkSpeedText extends StatefulWidget {
  const NetworkSpeedText({
    super.key,
    required this.read,
    this.style,
    this.interval = const Duration(seconds: 1),
  });

  final Future<int> Function() read;
  final TextStyle? style;
  final Duration interval;

  @override
  State<NetworkSpeedText> createState() => _NetworkSpeedTextState();
}

class _NetworkSpeedTextState extends State<NetworkSpeedText> {
  Timer? _timer;
  int _bytesPerSecond = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(widget.interval, (_) => _poll());
    _poll();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    final value = await widget.read();
    if (!mounted || value == _bytesPerSecond) return;
    setState(() => _bytesPerSecond = value);
  }

  @override
  Widget build(BuildContext context) {
    // 0 值不占位：缓冲中/暂停时不该出现「0 KB/s」。
    if (_bytesPerSecond <= 0) return const SizedBox.shrink();
    return Text(formatNetworkSpeed(_bytesPerSecond), style: widget.style);
  }
}

/// 播放页右上角的时钟。每 10 秒对一次表，分钟没变就不重建。
class ClockText extends StatefulWidget {
  const ClockText({super.key, this.style, this.now});

  final TextStyle? style;

  /// 测试注入固定时间；为空时读系统时钟。
  final DateTime Function()? now;

  @override
  State<ClockText> createState() => _ClockTextState();
}

class _ClockTextState extends State<ClockText> {
  Timer? _timer;
  late DateTime _now = widget.now?.call() ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 10), (_) {
      final now = widget.now?.call() ?? DateTime.now();
      if (now.minute == _now.minute && now.hour == _now.hour) return;
      setState(() => _now = now);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Text(formatClock(_now), style: widget.style);
  }
}
