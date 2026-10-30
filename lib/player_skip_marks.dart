import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'app_icons.dart';

/// 片头/片尾标记（单位：秒，**按整部剧保存**，同剧所有集共享）。
///
/// 一部剧的片头通常每集都一样，所以只需要用户在某一集上标定一次：
/// 之后每一集都会在同样的时间点自动跳过片头、到达片尾时自动接下一集。
/// 0 表示该段未设置。
class EpisodeSkipMarks {
  const EpisodeSkipMarks({this.introEnd = 0, this.outroStart = 0});

  /// 片头结束位置：这个点之后才是正片。从更早的位置进入时直接跳到这里。
  final double introEnd;

  /// 片尾开始位置：走到这里就当作这一集播完了（有下一集时自动接上）。
  final double outroStart;

  bool get hasIntro => introEnd > 0;
  bool get hasOutro => outroStart > 0;
  bool get isEmpty => !hasIntro && !hasOutro;

  EpisodeSkipMarks copyWith({double? introEnd, double? outroStart}) =>
      EpisodeSkipMarks(
        introEnd: introEnd == null
            ? this.introEnd
            : introEnd.clamp(0, double.infinity).toDouble(),
        outroStart: outroStart == null
            ? this.outroStart
            : outroStart.clamp(0, double.infinity).toDouble(),
      );

  factory EpisodeSkipMarks.fromJson(Map<String, dynamic> json) {
    double read(String key) {
      final value = json[key];
      if (value is num) return value.toDouble();
      if (value is String) return double.tryParse(value) ?? 0;
      return 0;
    }

    return EpisodeSkipMarks(
      introEnd: read('introEnd'),
      outroStart: read('outroStart'),
    );
  }

  Map<String, dynamic> toJson() => {
        'introEnd': introEnd,
        'outroStart': outroStart,
      };

  @override
  bool operator ==(Object other) =>
      other is EpisodeSkipMarks &&
      other.introEnd == introEnd &&
      other.outroStart == outroStart;

  @override
  int get hashCode => Object.hash(introEnd, outroStart);

  @override
  String toString() =>
      'EpisodeSkipMarks(introEnd: $introEnd, outroStart: $outroStart)';
}

/// 播到某个位置时应该对这一集做什么。
enum SkipMarkAction {
  /// 什么都不做。
  none,

  /// 跳到片头结束位置。
  skipIntro,

  /// 走到片尾了，接下一集。
  skipOutro,
}

/// 判定当前位置该触发哪个跳过动作（纯函数，便于单测覆盖边界）。
///
/// - [duration] 未知（还没拿到片长）时一律不跳，避免 seek 到不合理的点。
/// - [introApplied]/[outroApplied] 是「这一集已经跳过」的自家标记，用来保证
///   一次播放里每段只生效一次：用户手动拖回片头/片尾重看时不会被再次拽走。
SkipMarkAction resolveSkipAction({
  required double position,
  required double duration,
  required EpisodeSkipMarks marks,
  required bool introApplied,
  required bool outroApplied,
  required bool hasNextEpisode,
}) {
  if (duration <= 0 || position < 0 || marks.isEmpty) {
    return SkipMarkAction.none;
  }
  // 换源/换线路导致片长变短，标记点落在片长之外就作废这一段：
  // 宁可不跳，也不能把用户带到莫名其妙的位置。
  final introValid = marks.introEnd > 0 && marks.introEnd < duration - 1;
  final outroValid = marks.outroStart > 0 && marks.outroStart < duration - 1;
  // 两个标记打架（片尾起点不晚于片头终点）时只保留片头。
  final conflicting =
      introValid && outroValid && marks.outroStart <= marks.introEnd + 1;

  if (!introApplied && introValid && position < marks.introEnd - 1) {
    return SkipMarkAction.skipIntro;
  }
  if (!outroApplied &&
      outroValid &&
      !conflicting &&
      position >= marks.outroStart) {
    return hasNextEpisode ? SkipMarkAction.skipOutro : SkipMarkAction.none;
  }
  return SkipMarkAction.none;
}

/// 秒 -> mm:ss（超过一小时走 h:mm:ss，长视频也够用）。
String skipMarkClock(double seconds) {
  final total = seconds <= 0 ? 0 : seconds.round();
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final secondsPart = total % 60;
  final mm = hours > 0 ? minutes.toString().padLeft(2, '0') : '$minutes';
  final body = '$mm:${secondsPart.toString().padLeft(2, '0')}';
  return hours > 0 ? '$hours:$body' : body;
}

/// 片头/片尾标定面板：放在播放页右侧滑出面板里用。
///
/// 边播边标定是最省事的方式——播放到片头结束那一刻点「设为片头结束」，
/// 面板里的标记立刻生效（落盘由外层处理）。
class SkipMarksPanel extends StatefulWidget {
  const SkipMarksPanel({
    super.key,
    required this.player,
    required this.marks,
    required this.onSaved,
    this.scrollable = true,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 20),
  });

  final Player player;
  final EpisodeSkipMarks marks;

  /// 变更回调（清除时传出空的 [EpisodeSkipMarks]）。
  final ValueChanged<EpisodeSkipMarks> onSaved;

  /// 自己滚动（独占一个面板）还是长成一段静态内容（嵌进别的滚动列表里）。
  final bool scrollable;
  final EdgeInsets padding;

  @override
  State<SkipMarksPanel> createState() => _SkipMarksPanelState();
}

class _SkipMarksPanelState extends State<SkipMarksPanel> {
  late EpisodeSkipMarks _marks = widget.marks;

  @override
  void didUpdateWidget(covariant SkipMarksPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.marks != widget.marks) _marks = widget.marks;
  }

  void _save(EpisodeSkipMarks next) {
    setState(() => _marks = next);
    widget.onSaved(next);
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return StreamBuilder<Duration>(
      stream: widget.player.stream.position,
      initialData: widget.player.state.position,
      builder: (context, snapshot) {
        final position = snapshot.data ?? Duration.zero;
        final seconds = position.inMilliseconds / 1000;
        final duration = widget.player.state.duration;
        final children = <Widget>[
            Text(
              '对一部剧标定一次，之后每集自动跳过。'
              '边播边设最准：播到片头刚结束的位置点右侧按钮即可。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: Colors.white.withValues(alpha: .5),
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                AppIcon(
                  AppIcons.fastForward,
                  size: 18,
                  color: Colors.white.withValues(alpha: .6),
                ),
                const SizedBox(width: 8),
                const Text(
                  '当前位置',
                  style: TextStyle(fontSize: 13, color: Colors.white70),
                ),
                const SizedBox(width: 8),
                Text(
                  skipMarkClock(seconds),
                  key: const ValueKey('skip-marks-position'),
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: primary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  '/ ${skipMarkClock(duration.inMilliseconds / 1000)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: .45),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _markTile(
              keyPrefix: 'intro',
              title: '片头结束',
              value: _marks.introEnd,
              onSet: duration <= Duration.zero
                  ? null
                  : () => _save(_marks.copyWith(introEnd: seconds)),
              onClear: _marks.hasIntro
                  ? () => _save(_marks.copyWith(introEnd: 0))
                  : null,
            ),
            const SizedBox(height: 10),
            _markTile(
              keyPrefix: 'outro',
              title: '片尾开始',
              value: _marks.outroStart,
              onSet: duration <= Duration.zero
                  ? null
                  : () => _save(_marks.copyWith(outroStart: seconds)),
              onClear: _marks.hasOutro
                  ? () => _save(_marks.copyWith(outroStart: 0))
                  : null,
            ),
            const SizedBox(height: 18),
            Text(
              '片头：起播或从更早位置进入时直接跳到标记点。\n'
              '片尾：走到标记点自动播下一集（最后一集不生效）。\n'
              '每段一次播放只生效一次，手动拖回不会被拽走。',
              style: TextStyle(
                fontSize: 12,
                height: 1.6,
                color: Colors.white.withValues(alpha: .45),
              ),
            ),
        ];
        if (!widget.scrollable) {
          return Padding(
            padding: widget.padding,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          );
        }
        return ListView(padding: widget.padding, children: children);
      },
    );
  }

  Widget _markTile({
    required String keyPrefix,
    required String title,
    required double value,
    required VoidCallback? onSet,
    required VoidCallback? onClear,
  }) {
    final set = value > 0;
    final primary = Theme.of(context).colorScheme.primary;
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: .06),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 14, color: Colors.white),
                ),
              ),
              Text(
                set ? skipMarkClock(value) : '未设置',
                key: ValueKey('skip-$keyPrefix-value'),
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: set ? primary : Colors.white.withValues(alpha: .4),
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                key: ValueKey('skip-$keyPrefix-set'),
                onPressed: onSet,
                child: Text(set ? '设为当前位置' : '标定'),
              ),
              const SizedBox(width: 4),
              TextButton(
                key: ValueKey('skip-$keyPrefix-clear'),
                onPressed: onClear,
                child: const Text('清除'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
