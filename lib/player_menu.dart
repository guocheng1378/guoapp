import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'models.dart';
import 'episode_browser.dart';
import 'playback_preferences.dart';
import 'video_enhancement.dart';
import 'video_enhancement_settings.dart';
import 'app_icons.dart';

enum PlayerMenuSection { episodes, speed, quality, settings }

class PlayerMenu extends StatefulWidget {
  const PlayerMenu({
    super.key,
    required this.section,
    required this.episodes,
    required this.currentIndex,
    required this.preferences,
    required this.qualities,
    required this.actualQuality,
    required this.local,
    required this.favorite,
    required this.mobile,
    required this.onEpisode,
    required this.onPreferences,
    required this.onFavorite,
    this.showDanmaku = false,
    this.danmakuStatus = '',
    this.onRetryDanmaku,
    this.preloadStatus = '',
    this.enhancement,
    this.onCompareEnhancement,
  });

  final PlayerMenuSection section;
  final List<Episode> episodes;
  final int currentIndex;
  final PlaybackPreferences preferences;
  final List<int> qualities;
  final int actualQuality;
  final bool local;
  final bool favorite;
  final bool mobile;
  final bool showDanmaku;
  final String danmakuStatus;
  final VoidCallback? onRetryDanmaku;
  final String preloadStatus;
  final VideoEnhancementController? enhancement;
  final VoidCallback? onCompareEnhancement;
  final ValueChanged<int> onEpisode;
  final Future<void> Function(PlaybackPreferences) onPreferences;
  final Future<void> Function() onFavorite;

  @override
  State<PlayerMenu> createState() => _PlayerMenuState();
}

class _PlayerMenuState extends State<PlayerMenu> {
  bool _busy = false;
  String? _error;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _error = '未能保存设置，请检查存储空间后重试。');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final landscape = size.width > size.height;
    final title = switch (widget.section) {
      PlayerMenuSection.episodes => '选集 · 共 ${widget.episodes.length} 集',
      PlayerMenuSection.speed => '播放倍速',
      PlayerMenuSection.quality => '清晰度',
      PlayerMenuSection.settings => '播放设置',
    };
    return Dialog(
      key: const ValueKey('player-menu'),
      alignment: landscape ? Alignment.centerRight : Alignment.bottomCenter,
      insetPadding: const EdgeInsets.all(12),
      backgroundColor: Colors.transparent,
      // 形态：**不再有整块大玻璃底**（用户 2026-10-29 定调「播放界面的弹窗
      // 和大玻璃都要改单独胶囊」）——面板里的每一项（标题、倍速/清晰度胶囊、
      // 选集格子、设置开关行）各自是独立胶囊，直接浮在画面上。
      child: Material(
        type: MaterialType.transparency,
        child: SizedBox(
          width: landscape ? math.min(440, size.width * .6) : 600,
          height: landscape ? size.height : size.height * .72,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                child: _CapsuleRow(
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          title,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭菜单',
                        onPressed: () => Navigator.pop(context),
                        icon: AppIcon(AppIcons.close),
                      ),
                    ],
                  ),
                ),
              ),
              if (_busy) const LinearProgressIndicator(minHeight: 2),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  child: _CapsuleRow(
                    child: Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFFB4A8)),
                    ),
                  ),
                ),
              Expanded(
                child: widget.section == PlayerMenuSection.episodes
                    ? PlayerEpisodeGrid(
                        episodes: widget.episodes,
                        currentIndex: widget.currentIndex,
                        keyPrefix: 'menu-episode',
                        onSelected: widget.onEpisode,
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(4, 4, 4, 20),
                        child: _settings(),
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settings() {
    final preferences = widget.preferences;
    final all = widget.section == PlayerMenuSection.settings;
    final colors = Theme.of(context).colorScheme;
    final helperStyle = TextStyle(
      fontSize: 13,
      color: colors.onSurfaceVariant,
      height: 1.5,
    );
    final qualities = {
      0,
      ...widget.qualities.where((quality) => quality > 0),
    }.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (all || widget.section == PlayerMenuSection.speed) ...[
          const Text('倍速'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final speed in playbackSpeeds)
                ChoiceChip(
                  key: ValueKey('menu-speed-$speed'),
                  label: Text('${speed}x'),
                  selected: speed == preferences.speed,
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(speed: speed),
                          ),
                        ),
                ),
            ],
          ),
          const SizedBox(height: 20),
        ],
        // 站点没有任何画质档位时不显示这一整段：只剩一个空标题和一片空
        // 胶囊，看着像没加载出来。本地播放仍显示，因为这里设置的是「后续
        // 在线播放」的画质偏好。
        if ((all || widget.section == PlayerMenuSection.quality) &&
            (widget.qualities.any((value) => value > 0) || widget.local)) ...[
          const Text('清晰度'),
          const SizedBox(height: 8),
          Text(
            widget.local
                ? '本集正在播放本地原画，画质偏好用于后续在线播放。'
                : widget.actualQuality > 0
                ? '当前播放 ${widget.actualQuality}P'
                : '使用源站可用画质',
            style: helperStyle,
          ),
          const SizedBox(height: 8),
          // 用户定调：列表里不再提供「自动」档（0 只是内部兜底语义），
          // 只让用户挑具体分辨率。
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final quality in qualities.where((quality) => quality > 0))
                ChoiceChip(
                  key: ValueKey('menu-quality-$quality'),
                  label: Text('${quality}P'),
                  // 用户没存过档（0）时高亮本集实际播放的那一档，别让整排
                  // 胶囊全是未选中态。
                  selected:
                      quality ==
                      (preferences.quality > 0
                          ? preferences.quality
                          : widget.actualQuality),
                  onSelected: _busy
                      ? null
                      : (_) => _run(
                          () => widget.onPreferences(
                            preferences.copyWith(quality: quality),
                          ),
                        ),
                ),
            ],
          ),
          if (preferences.quality > 0 &&
              !qualities.contains(preferences.quality))
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '已保存 ${preferences.quality}P 偏好，本集暂无此画质。',
                style: helperStyle,
              ),
            ),
          const SizedBox(height: 20),
        ],
        if ((all || widget.section == PlayerMenuSection.quality) &&
            widget.enhancement != null)
          VideoEnhancementSettings(
            controller: widget.enhancement!,
            busy: _busy,
            onChanged: (enhancement) => _run(
              () => widget.onPreferences(
                preferences.copyWith(enhancement: enhancement),
              ),
            ),
            onCompare: widget.onCompareEnhancement ?? () {},
          ),
        if (all && widget.showDanmaku) ...[
          _CapsuleRow(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SwitchListTile.adaptive(
              key: const ValueKey('player-danmaku-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('弹幕'),
              subtitle: Text(widget.danmakuStatus),
              value: preferences.danmaku,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      () => widget.onPreferences(
                        preferences.copyWith(danmaku: value),
                      ),
                    ),
            ),
          ),
          if (widget.onRetryDanmaku != null)
            TextButton.icon(
              key: const ValueKey('player-danmaku-retry'),
              onPressed: _busy ? null : widget.onRetryDanmaku,
              icon: AppIcon(AppIcons.refresh),
              label: const Text('重试弹幕'),
            ),
          const SizedBox(height: 8),
        ],
        if (all) ...[
          _CapsuleRow(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SwitchListTile.adaptive(
              key: const ValueKey('player-preload-enabled'),
              contentPadding: EdgeInsets.zero,
              title: const Text('下一集预加载'),
              subtitle: Text(widget.local ? '本地播放不预取网络视频' : widget.preloadStatus),
              value: preferences.preload,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      () => widget.onPreferences(
                        preferences.copyWith(preload: value),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          _CapsuleRow(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: SwitchListTile.adaptive(
              key: const ValueKey('player-auto-advance'),
              contentPadding: EdgeInsets.zero,
              title: const Text('自动连播'),
              subtitle: const Text('关闭后，播放结束停在当前集'),
              value: preferences.autoAdvance,
              onChanged: _busy
                  ? null
                  : (value) => _run(
                      () => widget.onPreferences(
                        preferences.copyWith(autoAdvance: value),
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            key: const ValueKey('player-favorite'),
            style: OutlinedButton.styleFrom(
              // 方形圆角矩形（用户定调：大胶囊换方的）。
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
              side: BorderSide(color: Colors.white.withValues(alpha: .34)),
              foregroundColor: Colors.white,
            ),
            onPressed: _busy ? null : () => _run(widget.onFavorite),
            icon: widget.favorite
                ? AppIcon(AppIcons.bookmark, filled: true)
                : AppIcon(AppIcons.bookmark),
            label: Text(widget.favorite ? '取消追剧' : '加入追剧'),
          ),
          const SizedBox(height: 20),
          Text(
            widget.mobile
                ? '长按画面临时 3 倍速，松开恢复。竖屏轻点暂停，横屏轻点显示控制；双击播放或暂停。'
                : '空格：播放 / 暂停\n左右键：后退 / 快进 5 秒\n长按右键或画面：临时 3 倍速\n上下键：音量 ±5%，M：静音\nF、F11、Ctrl+F：全屏\nEsc：先关闭菜单，再退出全屏',
            style: helperStyle.copyWith(height: 1.6),
          ),
        ],
      ],
    );
  }
}

/// 播放器浮层里的**独立玻璃条**容器：半透黑底 + 磨砂，浮在画面上。
///
/// 替代原来的整块大玻璃面板——面板一整块时读作"一块玻璃板"；而形态上
/// **必须是方形圆角矩形**（用户 2026-10-29「那些大胶囊换成方的」）：宽扁的
/// 药丸容器会把行内文字挤到圆弧里、读不清。
class _CapsuleRow extends StatelessWidget {
  const _CapsuleRow({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    // 铁律：blur 直挂 ClipRRect，中间不隔 saveLayer 类 widget。
    return ClipRRect(
      borderRadius: BorderRadius.circular(18),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: Container(
          padding: padding,
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .34),
            borderRadius: BorderRadius.circular(18),
          ),
          // 胶囊自带底色，里面的 ListTile/SwitchListTile 没有 Material 祖先：
          // 选中底色与点击水波纹会被这层底色盖住（Flutter 也会直接断言报错）。
          // 补一层透明 Material，只提供绘制祖先，不改变外观。
          child: Material(
            type: MaterialType.transparency,
            child: child,
          ),
        ),
      ),
    );
  }
}

class PlayerEpisodeGrid extends StatelessWidget {
  const PlayerEpisodeGrid({
    super.key,
    required this.episodes,
    required this.currentIndex,
    required this.onSelected,
    this.keyPrefix = 'play-episode',
    this.compact = false,
    this.dense = false,
    this.title = '选集',
    this.note = '',
  });
  final List<Episode> episodes;
  final int currentIndex;
  final ValueChanged<int> onSelected;
  final String keyPrefix;
  final bool compact;
  /// 小格子密度档：右侧面板窄容器下用 5 列 / 42dp 行高。
  final bool dense;
  final String title;
  /// 标题追加的剧集状态（已完结 / 连载中），空则不显示。
  final String note;
  @override
  Widget build(BuildContext context) => EpisodeBrowser(
    episodes: episodes,
    currentNumber: episodes.isEmpty
        ? null
        : episodes[currentIndex.clamp(0, episodes.length - 1)].number,
    onSelected: onSelected,
    keyPrefix: keyPrefix,
    compact: compact,
    dense: dense,
    title: title,
    note: note,
  );
}
