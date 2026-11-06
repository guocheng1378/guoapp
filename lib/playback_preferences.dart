import 'video_enhancement_preferences.dart';

const playbackSpeeds = [.5, .75, 1.0, 1.25, 1.5, 2.0, 3.0];

/// 解码方式：跟随平台默认 / 硬解·兼容（auto-safe）/ 软解·兼容（关硬解）。
/// 用于排查部分电视盒子硬解「有声无画」的问题。
const playbackDecodeAuto = 'auto';
const playbackDecodeHardware = 'hw';
const playbackDecodeSoftware = 'sw';
const playbackDecodeModes = [
  playbackDecodeAuto,
  playbackDecodeHardware,
  playbackDecodeSoftware,
];

String playbackDecodeLabel(String decode) => switch (decode) {
  playbackDecodeHardware => '硬解 · 兼容',
  playbackDecodeSoftware => '软解 · 兼容',
  _ => '自动',
};

/// 偏好到 mpv `hwdec` 属性的映射；`auto` 返回 null 表示不动平台默认
/// （Android 媒体引擎默认 auto-safe，Windows 默认 auto）。
String? playbackDecodeHwdec(String decode) => switch (decode) {
  playbackDecodeHardware => 'auto-safe',
  playbackDecodeSoftware => 'no',
  _ => null,
};

class PlaybackPreferences {
  const PlaybackPreferences({
    this.speed = 1,
    this.quality = 0,
    this.autoAdvance = true,
    this.danmaku = true,
    this.preload = true,
    this.decode = playbackDecodeAuto,
    this.brightness = 1,
    this.volume = 100,
    this.enhancement = const VideoEnhancementPreferences(),
  });

  final double speed;
  final int quality;
  final bool autoAdvance;
  final bool danmaku;
  final bool preload;

  /// 解码方式（auto/hw/sw），电视端「有声无画」排查用
  final String decode;

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
    String? decode,
    double? brightness,
    double? volume,
    VideoEnhancementPreferences? enhancement,
  }) => PlaybackPreferences(
    speed: speed ?? this.speed,
    quality: quality ?? this.quality,
    autoAdvance: autoAdvance ?? this.autoAdvance,
    danmaku: danmaku ?? this.danmaku,
    preload: preload ?? this.preload,
    decode: decode ?? this.decode,
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
    'decode': decode,
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
    // 解码方式宽容回退：未知值（上游/旧备份）落回 auto，不做硬校验——
    // 亮/音量同理，避免一个坏字段把整份偏好判废。
    var decode = value['decode'] as String? ?? playbackDecodeAuto;
    if (!playbackDecodeModes.contains(decode)) decode = playbackDecodeAuto;
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
      decode: decode,
      brightness: brightness,
      volume: volume,
      enhancement: VideoEnhancementPreferences.fromJson(value['enhancement']),
    );
  }
}
