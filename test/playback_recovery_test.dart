import 'package:duanju_app/models.dart';
import 'package:duanju_app/playback_recovery.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  PlaybackPlan route(int index, {int count = 3}) => PlaybackPlan(
    url: 'https://media.test/$index.mp4',
    session: 'session-$index',
    routeIndex: index,
    routeCount: count,
  );

  test('reuses the current route first, then tries alternates, then refreshes', () {
    final recovery = PlaybackRecovery();
    // 原地重开零网络、零解析，源站首字节抖动时最优先。
    expect(recovery.next(route(0)), PlaybackRecoveryAction.reuse);
    expect(recovery.next(route(1)), PlaybackRecoveryAction.alternative);
    expect(recovery.next(route(2)), PlaybackRecoveryAction.refresh);
    expect(recovery.next(route(0)), PlaybackRecoveryAction.alternative);
    expect(recovery.next(route(0)), PlaybackRecoveryAction.stop);
    recovery.reset();
    expect(recovery.next(route(0)), PlaybackRecoveryAction.reuse);
  });

  test('one-route sources refresh twice without endless retrying', () {
    final recovery = PlaybackRecovery();
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.reuse);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.refresh);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.refresh);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.stop);
    expect(recovery.next(route(0, count: 1)), PlaybackRecoveryAction.stop);
  });

  test('many failing alternatives cannot exceed the automatic retry limit', () {
    final recovery = PlaybackRecovery();
    expect(recovery.next(route(0, count: 10)), PlaybackRecoveryAction.reuse);
    for (var i = 0; i < 3; i++) {
      expect(
        recovery.next(route(i + 1, count: 10)),
        PlaybackRecoveryAction.alternative,
      );
    }
    expect(recovery.next(route(4, count: 10)), PlaybackRecoveryAction.stop);
  });

  test(
    'a stalled foreground stream times out but paused and background playback do not',
    () {
      final health = PlaybackHealth();
      final start = DateTime(2026, 9, 18);
      bool stalled(
        int seconds, {
        bool playing = true,
        bool foreground = true,
        int position = 5,
      }) => health.stalled(
        position: Duration(seconds: position),
        playing: playing,
        foreground: foreground,
        now: start.add(Duration(seconds: seconds)),
      );
      expect(stalled(0), isFalse);
      // 卡顿阈值放宽到 45 秒：源站首字节实测可等 16 秒，20 秒会误判。
      expect(stalled(44), isFalse);
      expect(stalled(45), isTrue);
      expect(stalled(46, position: 6), isFalse);
      expect(stalled(60, position: 6), isFalse);
      expect(stalled(80, playing: false, position: 6), isFalse);
      expect(stalled(100, playing: false, position: 6), isFalse);
      expect(stalled(120, foreground: false, position: 6), isFalse);
      expect(stalled(121, position: 6), isFalse);
      health.reset();
      expect(stalled(200, position: 6), isFalse);
    },
  );
}
