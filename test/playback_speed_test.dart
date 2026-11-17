import 'package:duanju_app/playback_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('倍速档位包含 1.1x 且保持升序', () {
    expect(playbackSpeeds, contains(1.1));
    for (var index = 1; index < playbackSpeeds.length; index++) {
      expect(playbackSpeeds[index], greaterThan(playbackSpeeds[index - 1]));
    }
  });

  test('1.1x 能被播放偏好接受，非法倍速仍被拒绝', () {
    final parsed = PlaybackPreferences.fromJson(<String, dynamic>{
      'speed': 1.1,
      'quality': 720,
    });
    expect(parsed.speed, 1.1);

    expect(
      () => PlaybackPreferences.fromJson(<String, dynamic>{'speed': 1.3}),
      throwsFormatException,
    );
  });
}
