import 'video_enhancement_preferences.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.preload = true,
    this.brightness = 1,
    this.volume = 100,
    this.enhancement = const VideoEnhancementPreferences(),
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final bool preload;

  /// 遮罩亮度（0.05~1）与播放器音量（0~100），跨剧沿用用户上次的手感
  final double brightness;
  final double volume;
  final VideoEnhancementPreferences enhancement;

  PlaybackPreferences copyWith({
    double? speed,
    int? quality,
    bool? autoAdvance,
    bool? danmaku,
    bool? preload,
    double? brightness,
    double? volume,
    VideoEnhancementPreferences? enhancement,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    preload: preload ?? this.preload,
    brightness: brightness ?? this.brightness,
    volume: volume ?? this.volume,
    enhancement: enhancement ?? this.enhancement,
  );

  Map<String, dynamic> toJson() => {
    'speed': speed,
    'quality': quality,
    'autoAdvance': autoAdvance,
    'danmaku': danmaku,
    'preload': preload,
    'brightness': brightness,
    'volume': volume,
    'enhancement': enhancement.toJson(),
  };

  factory PlaybackPreferences.fromJson(Map<String, dynamic> value) {
    final speed = (value['speed'] as num? ?? 1).toDouble();
    final quality = value['quality'] as int? ?? 0;
    final autoAdvance = value['autoAdvance'] as bool? ?? true;
    final danmaku = value['danmaku'] as bool? ?? true;
    final preload = value['preload'] as bool? ?? true;
    // 亮度/音量只做夹取不做校验，旧备份缺字段时用默认值即可通过
    final brightness = ((value['brightness'] as num?)?.toDouble() ?? 1).clamp(
      .05,
      1.0,
    );
    final volume = ((value['volume'] as num?)?.toDouble() ?? 100).clamp(
      0.0,
      100.0,
    );
    if (!playbackSpeeds.contains(speed) || quality < 0 || quality > 4320) {
      throw const FormatException('播放偏好无效');
    }
    return PlaybackPreferences(
      speed: speed,
      quality: quality,
      autoAdvance: autoAdvance,
      danmaku: danmaku,
      preload: preload,
      brightness: brightness,
      volume: volume,
      enhancement: VideoEnhancementPreferences.fromJson(value['enhancement']),
    );
  }
}
