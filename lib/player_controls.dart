import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'lan_controller.dart';
import 'player_interactions.dart';
import 'widgets.dart';
import 'video_enhancement.dart';

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    this.onFullscreen,
    required this.onBack,
    required this.onPrevious,
    required this.onNext,
    required this.title,
    required this.onTogglePlayback,
    required this.onEpisodes,
    required this.onSpeed,
    required this.onQuality,
    required this.speed,
    required this.qualityLabel,
    required this.onFocusSurface,
    this.routeLabel,
    this.onRoute,
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.danmakuStatus = '',
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.onSeek,
    this.onDanmaku,
    this.onRetryDanmaku,
    this.onPush,
    this.onPictureInPicture,
    this.enhancement,
  });

  final Player player;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final VoidCallback? onFullscreen;
  final VoidCallback onBack;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final String title;
  final VoidCallback onTogglePlayback;
  final Future<void> Function() onEpisodes;
  final Future<void> Function() onSpeed;
  final Future<void> Function() onQuality;
  final double speed;
  final String qualityLabel;
  final VoidCallback onFocusSurface;
  final String? routeLabel;
  final Future<void> Function()? onRoute;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final String danmakuStatus;
  final bool swipeEnabled;
  final bool panelOpen;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function()? onDanmaku;
  final Future<void> Function()? onRetryDanmaku;
  final Future<void> Function()? onPush;
  final Future<void> Function()? onPictureInPicture;
  final VideoEnhancementController? enhancement;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  bool _visible = true;

  /// 控制栏子树是否在树上：淡出 180ms 窗口内保持，结束后下线停绘。
  bool _fading = true;
  Timer? _fadeTimer;
  bool _lastPlaying = false;
  double? _seekValue;
  int _rippleSeq = 0;
  _TapRipple? _ripple;

  @override
  void initState() {
    super.initState();
    _visible = widget.showOnPlaybackReady;
    _lastPlaying = widget.player.state.playing;
    // position/duration/buffer 是播放中最高频的流（~4 次/秒），不再
    // 在这里整树 setState——由 _progressRow 内的 StreamBuilder 自行
    // 订阅 position 局部重建；duration/buffer 变化稀少，跟随其事件
    // 顺带刷新即可（episode 切换时 position 必然跳动）。
    for (final stream in [
      widget.player.stream.playing,
      widget.player.stream.buffering,
      widget.player.stream.volume,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          if (mounted) setState(() {});
        }),
      );
    }
    _subscriptions.add(
      widget.player.stream.playing.listen((playing) {
        final wasPlaying = _lastPlaying;
        _lastPlaying = playing;
        if (!mounted || !widget.enabled) return;
        // 暂停与恢复播放都不再主动弹出控制栏（旧逻辑在这里 _show()，
        // 导致「做什么它都出来」）；只在恢复播放时重新安排一次自动隐藏
        if (playing && !wasPlaying) {
          _scheduleHide();
        }
      }),
    );
    widget.interactions.addListener(_interactionChanged);
    _scheduleHide();
  }

  @override
  void didUpdateWidget(PlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      _seekValue = null;
      // 显示即上线（_fading 可能在上次淡出后被置 false）；
      // 隐藏则等淡出结束后把子树下线。
      _fading = true;
      if (!widget.enabled && oldWidget.enabled) {
        // 播放出错进入错误面板时收起控制栏
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        // 播放就绪只提示一次；暂停恢复不再自动弹工具栏，避免中央三按钮常驻
        _visible = widget.showOnPlaybackReady;
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      if (!_visible) _scheduleControlsOffline();
      _scheduleHide();
    }
  }

  void _interactionChanged() {
    if (!mounted) return;
    // 滑动调进度：直接继续播放，不把工具栏顶出来打扰
    if (widget.interactions.hudState.type == SwipeAction.seek) {
      if (_visible) _setVisible(false);
      return;
    }
    // 刚滑完进度的一小段时间里，提示照弹但不把工具栏唤出来
    if (widget.interactions.feedback.isNotEmpty && !widget.interactions.quiet) {
      _show();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    // 暂停中也要照常收起：以前这里把「暂停」当成不隐藏的条件，
    // 结果点了暂停后中央三按钮就长期杵在画面上
    if (!widget.enabled || widget.panelOpen || _seekValue != null) {
      return;
    }
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted &&
          widget.enabled &&
          !widget.panelOpen &&
          !widget.player.state.buffering &&
          !widget.interactions.boosting &&
          _seekValue == null) {
        _setVisible(false);
      }
    });
  }

  /// 淡出动画结束（180ms + 20ms 余量）后把控制栏子树下线停绘。
  void _scheduleControlsOffline() {
    _fadeTimer?.cancel();
    _fadeTimer = Timer(const Duration(milliseconds: 200), () {
      if (mounted && !_visible) setState(() => _fading = false);
    });
  }

  /// 统一切换控制栏可见性：显示即上线，隐藏等淡出结束后下线。
  void _setVisible(bool value) {
    if (!mounted) return;
    setState(() {
      _visible = value;
      _fading = true;
    });
    if (!value) _scheduleControlsOffline();
  }

  void _show() {
    if (!mounted) return;
    if (!_visible) _setVisible(true);
    _scheduleHide();
  }

  void _tap() {
    if (widget.interactions.suppressTap) return;
    widget.onFocusSurface();
    // 单击切换控制条显隐（横竖屏一致）；播放/暂停走中央按钮
    setState(() => _visible = !_visible);
    _scheduleHide();
  }

  Future<void> _panel(Future<void> Function() open) async {
    _hideTimer?.cancel();
    widget.interactions.cancel();
    await open();
    _show();
  }

  void _spawnRipple(Offset origin, {required bool forward}) {
    setState(() {
      _rippleSeq++;
      _ripple = _TapRipple(seq: _rippleSeq, origin: origin, forward: forward);
    });
  }

  Widget _buildTapRipple(BoxConstraints constraints) {
    final ripple = _ripple!;
    return Positioned.fill(
      child: IgnorePointer(
        child: Center(
          child: Transform.translate(
            offset: Offset(
              ripple.origin.dx - constraints.maxWidth / 2,
              ripple.origin.dy - constraints.maxHeight / 2,
            ),
            child: TweenAnimationBuilder<double>(
              key: ValueKey('tap-ripple-${ripple.seq}'),
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 480),
              onEnd: () {
                if (mounted && _ripple?.seq == ripple.seq) {
                  setState(() => _ripple = null);
                }
              },
              builder: (context, t, child) {
                final fade = t < .6 ? 1.0 : 1 - (t - .6) / .4;
                return Opacity(
                  opacity: fade.clamp(0.0, 1.0),
                  child: Transform.scale(scale: .6 + .4 * t, child: child),
                );
              },
              child: Container(
                width: 116,
                height: 116,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white.withValues(alpha: .16),
                  border: Border.all(color: Colors.white24),
                ),
                alignment: Alignment.center,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      ripple.forward
                          ? Icons.fast_forward_rounded
                          : Icons.fast_rewind_rounded,
                      color: Colors.white,
                      size: 26,
                    ),
                    Text(
                      ripple.forward ? '+10 秒' : '-10 秒',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _fadeTimer?.cancel();
    widget.interactions.removeListener(_interactionChanged);
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.player.state;
    // 手势进行中（滑动调进度/亮度/音量/切集）强制隐藏控制栏：
    // 滑动 seek 会冻结预览（临时暂停），不能因「未播放」把中间按钮顶出来挡 HUD
    final gestureActive =
        widget.interactions.hudState.type != SwipeAction.none;
    // 只有用户主动唤出或面板打开时才显示：暂停、缓冲都不再自动弹出，
    // 否则中央的上一集/播放/下一集会常驻在画面上（很突兀）
    final visible = (_visible || widget.panelOpen) && !gestureActive;
    return MouseRegion(
      onHover: (_) => _show(),
      cursor: visible ? SystemMouseCursors.basic : SystemMouseCursors.none,
      child: LayoutBuilder(
        builder: (context, constraints) => Stack(
          fit: StackFit.expand,
          children: [
            Listener(
              key: const ValueKey('player-gesture-surface'),
              behavior: HitTestBehavior.opaque,
              onPointerDown: (event) {
                widget.onFocusSurface();
                // 控件显示时，落在底部控制区的手势交给控件自己处理（否则裸
                // Listener 会先启动长按，把按钮长按抢成 2 倍速）；控件隐藏时
                // 整屏手势都归播放器，底部照样能上下滑调亮度/音量
                if (visible &&
                    _hitsControlBand(
                      event.localPosition,
                      constraints.biggest,
                    )) {
                  return;
                }
                widget.interactions.pointerDown(
                  event,
                  swipeEnabled: widget.swipeEnabled,
                  width: constraints.maxWidth,
                  height: constraints.maxHeight,
                );
              },
              onPointerMove: widget.interactions.pointerMove,
              onPointerUp: widget.interactions.pointerUp,
              onPointerCancel: widget.interactions.pointerCancel,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _tap,
                onDoubleTap: () {
                  if (!widget.enabled || widget.interactions.suppressTap) {
                    return;
                  }
                  final origin = widget.interactions.lastTapOrigin;
                  final width = widget.interactions.viewWidth;
                  if (origin != null && width > 0 && widget.onSeek != null) {
                    final back = origin.dx < width * 0.5;
                    final target = Duration(
                      seconds:
                          widget.player.state.position.inSeconds + (back ? -10 : 10),
                    );
                    unawaited(widget.onSeek!(target));
                    widget.interactions.hint(back ? '快退 10 秒' : '快进 10 秒');
                    _spawnRipple(origin, forward: !back);
                    _show();
                  } else {
                    widget.onTogglePlayback();
                    _show();
                  }
                },
              ),
            ),
            if (_ripple != null) _buildTapRipple(constraints),
            if (state.buffering && widget.enabled)
              const IgnorePointer(
                child: Center(child: CircularProgressIndicator()),
              ),
            IgnorePointer(
              ignoring: !visible,
              child: ExcludeFocus(
                excluding: !visible,
                // 淡出动画结束（+20ms 余量）后把整棵控制栏下线：早期
                // AnimatedOpacity 常驻 opacity:0，子树仍参与布局与绘制
                // （顶栏/按钮/渐变层/弹幕开关全画一遍）。
                child: _fading
                    ? AnimatedOpacity(
                        opacity: visible ? 1 : 0,
                        duration: const Duration(milliseconds: 180),
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const IgnorePointer(
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: LinearGradient(
                                    begin: Alignment.topCenter,
                                    end: Alignment.bottomCenter,
                                    colors: [
                                      Color(0xAA000000),
                                      Colors.transparent,
                                      Color(0xE6000000),
                                    ],
                                    stops: [0, .45, 1],
                                  ),
                                ),
                              ),
                            ),
                            Padding(
                              padding: EdgeInsets.fromLTRB(
                                8,
                                _topChromeInset(),
                                8,
                                _bottomChromeInset(),
                              ),
                              child: Stack(
                                children: [
                                  if (widget.fullscreen) _topBar(),
                                  if (!state.buffering &&
                                      widget.enabled &&
                                      constraints.maxHeight >=
                                          (widget.swipeEnabled ? 168 : 220))
                                    _centerPlayback(
                                      state.playing,
                                      showSkip: true,
                                    ),
                                  _sideDanmakuControl(),
                                  _bottomControls(
                                    constraints: constraints,
                                    volume: state.volume,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
            // 顶部剧集信息行跟随控制栏一起淡出：常驻会一直占着画面上方一条
            if (widget.swipeEnabled && !widget.fullscreen && widget.enabled)
              IgnorePointer(
                ignoring: !visible,
                child: AnimatedOpacity(
                  opacity: visible ? 1 : 0,
                  duration: const Duration(milliseconds: 180),
                  child: _feedTopBar(),
                ),
              ),
            _gestureFeedback(),
          ],
        ),
      ),
    );
  }

  /// 竖屏沉浸（feed）模式的常驻顶栏：返回 + 剧名·第N集 + 旋转，
  /// 不随控制条淡出——红果短剧的做法，切集后始终能看到当前剧集上下文。
  Widget _feedTopBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 4, top: 8),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: '返回',
              onPressed: widget.onBack,
              icon: Icons.arrow_back_ios_new_rounded,
            ),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ),
            if (widget.onFullscreen != null)
              _overlayIconButton(
                tooltip: '旋转与全屏',
                onPressed: widget.onFullscreen,
                icon: Icons.screen_rotation_alt_rounded,
              ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, right: 4),
        child: Row(
          children: [
            _overlayIconButton(
              tooltip: '退出全屏',
              onPressed: widget.onFullscreen,
              icon: Icons.arrow_back_rounded,
            ),
            Expanded(
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  shadows: [Shadow(blurRadius: 8, color: Colors.black54)],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required IconData icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: Icon(icon),
    ),
  );

  Widget _centerPlayback(bool playing, {required bool showSkip}) => Center(
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (showSkip) ...[
          IconButton(
            tooltip: '上一集',
            onPressed: widget.onPrevious,
            icon: const Icon(Icons.skip_previous_rounded),
          ),
          const SizedBox(width: 12),
        ],
        IconButton.filledTonal(
          tooltip: playing ? '暂停播放' : '开始播放',
          iconSize: 38,
          onPressed: () {
            widget.onTogglePlayback();
            _show();
          },
          icon: Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded),
        ),
        if (showSkip) ...[
          const SizedBox(width: 12),
          IconButton(
            tooltip: '下一集',
            onPressed: widget.onNext,
            icon: const Icon(Icons.skip_next_rounded),
          ),
        ],
      ],
    ),
  );

  Widget _sideDanmakuControl() {
    if (!widget.showDanmaku) return const SizedBox.shrink();
    return Align(
      alignment: Alignment.centerRight,
      child: Padding(
        padding: EdgeInsets.only(right: widget.swipeEnabled ? 0 : 4),
        child: _danmakuTool(),
      ),
    );
  }

  Widget _bottomControls({
    required BoxConstraints constraints,
    required double volume,
  }) {
    final width = constraints.maxWidth;
    final fullscreen = widget.fullscreen;
    final mobile = widget.swipeEnabled;
    final showEpisodes = fullscreen;
    final showSpeedQuality =
        mobile || fullscreen && width >= 720 || !fullscreen && width >= 560;
    final showPush =
        widget.onPush != null &&
        (mobile || fullscreen && width >= 860 || !fullscreen && width >= 680);
    final showCompare = fullscreen && width >= 820;
    final showVolume = !widget.swipeEnabled && width >= 360;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mobile)
            _mobileControlRow(fullscreen: fullscreen)
          else
            _desktopControlRow(
              fullscreen: fullscreen,
              showEpisodes: showEpisodes,
              showSpeedQuality: showSpeedQuality,
              showPush: showPush,
              showCompare: showCompare,
              showVolume: showVolume,
              volume: volume,
            ),
          _progressRow(),
        ],
      ),
    );
  }

  /// 进度行独立订阅 position 流：播放中唯一 ~4 次/秒的事件只重建这一行，
  /// 不再拖着整棵控制栏（顶栏/按钮/弹幕开关/渐变层）一起重建。
  Widget _progressRow() {
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, _) {
        final state = player.state;
        return _progressRowContent(
          duration: state.duration.inMilliseconds / 1000,
          position: state.position.inMilliseconds / 1000,
          buffered: state.buffer.inMilliseconds / 1000,
        );
      },
    );
  }

  double _topChromeInset() {
    if (widget.fullscreen) {
      final top = MediaQuery.paddingOf(context).top;
      if (top <= 0) return 16;
      return (top + 16).clamp(40.0, 80.0);
    }
    if (widget.swipeEnabled) {
      return 10;
    }
    return 0;
  }

  double _bottomChromeInset() {
    if (widget.fullscreen) {
      return (MediaQuery.viewPaddingOf(context).bottom + 12).clamp(48.0, 80.0);
    }
    return 0;
  }

  Widget _progressRowContent({
    required double duration,
    required double position,
    required double buffered,
  }) {
    final timeStyle = TextStyle(
      fontSize: 12,
      color: Colors.white.withValues(alpha: .82),
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 2),
      child: SizedBox(
        height: 28,
        child: Row(
          children: [
            SizedBox(
              width: 43,
              child: Text(
                formatPosition(_seekValue ?? position),
                style: timeStyle,
                textAlign: TextAlign.end,
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, trackConstraints) {
                  final trackWidth = trackConstraints.maxWidth;
                  return Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.centerLeft,
                    children: [
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 3,
                          secondaryActiveTrackColor: Colors.white38,
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 6,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 14,
                          ),
                        ),
                        child: Slider(
                          key: const ValueKey('player-progress'),
                          value: (_seekValue ?? position).clamp(
                            0,
                            duration > 0 ? duration : 1,
                          ),
                          max: duration > 0 ? duration : 1,
                          secondaryTrackValue: buffered.clamp(
                            0,
                            duration > 0 ? duration : 1,
                          ),
                          semanticFormatterCallback: formatPosition,
                          onChangeStart: widget.enabled && duration > 0
                              ? (_) {
                                  widget.interactions.cancel();
                                  _hideTimer?.cancel();
                                }
                              : null,
                          onChanged: !widget.enabled || duration <= 0
                              ? null
                              : (value) {
                                  _hideTimer?.cancel();
                                  setState(() => _seekValue = value);
                                },
                          onChangeEnd: (value) {
                            if (widget.enabled && duration > 0) {
                              (widget.onSeek ?? widget.player.seek)(
                                Duration(milliseconds: (value * 1000).round()),
                              );
                            }
                            setState(() => _seekValue = null);
                            _show();
                          },
                        ),
                      ),
                      if (_seekValue != null && duration > 0)
                        Positioned(
                          bottom: 16,
                          left: () {
                            final frac = (_seekValue! / duration).clamp(
                              0.0,
                              1.0,
                            );
                            return (frac * (trackWidth - 24)).clamp(
                              0.0,
                              (trackWidth - 72).clamp(0.0, 100000.0),
                            );
                          }(),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: .78),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              formatPosition(_seekValue!),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            SizedBox(
              width: 43,
              child: Text(formatPosition(duration), style: timeStyle),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolIcon({
    required Key key,
    required String tooltip,
    required IconData icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: Icon(icon, size: 22),
  );

  Widget _toolText({
    required Key key,
    required String tooltip,
    required String label,
    required VoidCallback? onPressed,
    double width = 52,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    visualWidth: width,
    child: Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
    ),
  );

  Widget _toolButton({
    required Key key,
    required String tooltip,
    required Widget child,
    required VoidCallback? onPressed,
    bool selected = false,
    double visualWidth = 36,
  }) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    final foreground = selected
        ? scheme.primary
        : Colors.white.withValues(alpha: enabled ? .92 : .48);
    final targetWidth = visualWidth < 40 ? 44.0 : visualWidth + 8;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: GestureDetector(
          key: key,
          behavior: HitTestBehavior.opaque,
          onTap: onPressed,
          child: SizedBox(
            width: targetWidth,
            height: 44,
            child: Center(
              child: IconTheme.merge(
                data: IconThemeData(color: foreground, size: 22),
                child: DefaultTextStyle.merge(
                  style: TextStyle(
                    color: foreground,
                    fontSize: 13.5,
                    height: 1,
                    fontWeight: FontWeight.w700,
                  ),
                  child: child,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _lanPushTool(Key key) {
    final link = LanController.current;
    if (link == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: link,
      builder: (context, _) => _toolButton(
        key: key,
        tooltip: link.connection == null
            ? '推送'
            : '推送到 ${link.connection!.peer.name}',
        onPressed: widget.enabled ? () => _panel(widget.onPush!) : null,
        child: link.pushing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                link.connection == null
                    ? Icons.cast_rounded
                    : Icons.cast_connected_rounded,
                size: 22,
              ),
      ),
    );
  }

  Widget _clusteredToolRow(List<Widget> tools) {
    if (tools.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisAlignment: MainAxisAlignment.end, children: tools);
  }

  /// 控件带命中判定：底部控制区（进度条 + 工具行）与右侧竖排控件（弹幕/音量）。
  /// 底部高度比常规 44px 工具行更宽，进度条本身还要留出拖动区。
  /// 控件带命中判定：只圈底部控制区（进度条 + 工具行）。
  /// 带高度按视口比例设上限，避免在小尺寸布局下把手势区整片吃掉
  /// （那会让右侧音量、中间切集等手势全部失灵）。
  bool _hitsControlBand(Offset position, Size size) {
    if (!size.width.isFinite || !size.height.isFinite) return false;
    if (size.width <= 0 || size.height <= 0) return false;
    final band = math.min(150.0, size.height * .22);
    return position.dy >= size.height - band;
  }

  /// 弹幕状态徽标：状态原本只挂在 tooltip 上，而真机上长按工具按钮会被
  /// 视频区的长按手势抢走（触发倍速播放），用户永远看不到弹幕到底怎么了。
  /// 这里把关键状态压缩成两三个字常驻显示在按钮上方。
  String? _danmakuBadge() {
    final status = widget.danmakuStatus;
    if (status.isEmpty) return null;
    const labels = {
      '本集暂不支持弹幕': '不支持',
      '本地播放不加载弹幕': '本地',
      '弹幕暂不可用，可重试': '重试',
      '正在加载弹幕': '加载中',
      '这段暂无弹幕': '暂无',
    };
    for (final entry in labels.entries) {
      if (status == entry.key) return entry.value;
    }
    final loaded = RegExp(r'^已载入 (\d+) 条弹幕$').firstMatch(status);
    if (loaded != null) return '${loaded.group(1)} 条';
    return null; // 已关闭 / 等待播放：按钮颜色已经说明，不再占位
  }

  Widget _danmakuTool() {
    final button = _toolButton(
      key: const ValueKey('player-danmaku-toggle'),
      tooltip: widget.danmakuStatus.isEmpty
          ? (widget.danmakuEnabled ? '关闭弹幕' : '打开弹幕')
          : widget.danmakuStatus,
      visualWidth: 36,
      selected: widget.danmakuEnabled,
      onPressed: widget.enabled
          ? () => _panel(widget.onRetryDanmaku ?? widget.onDanmaku!)
          : null,
      child: widget.onRetryDanmaku != null
          ? const Icon(Icons.refresh_rounded, size: 21)
          : Text(
              '弹',
              style: TextStyle(
                fontSize: 14,
                height: 1,
                fontWeight: FontWeight.w800,
                color: widget.danmakuEnabled
                    ? Theme.of(context).colorScheme.primary
                    : Colors.white.withValues(alpha: .86),
              ),
            ),
    );
    final badge = _danmakuBadge();
    if (badge == null) return button;
    final alert = badge == '重试' || badge == '不支持';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          // 与按钮同宽（_toolButton visualWidth 36 → 44），不撑开工具行间距
          width: 44,
          height: 12,
          child: Text(
            badge,
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.clip,
            style: TextStyle(
              fontSize: 9.5,
              height: 1.1,
              fontWeight: FontWeight.w700,
              color: alert
                  ? Colors.orangeAccent
                  : Colors.white.withValues(alpha: .78),
            ),
          ),
        ),
        button,
      ],
    );
  }

  Widget _desktopControlRow({
    required bool fullscreen,
    required bool showEpisodes,
    required bool showSpeedQuality,
    required bool showPush,
    required bool showCompare,
    required bool showVolume,
    required double volume,
  }) {
    final tools = [
      if (showSpeedQuality) ...[
        _toolText(
          key: const ValueKey('player-speed'),
          tooltip: '倍速',
          label: '${widget.speed}x',
          onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
          width: 50,
        ),
        _toolText(
          key: const ValueKey('player-quality'),
          tooltip: '清晰度',
          label: widget.qualityLabel,
          onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
          width: 52,
        ),
        if (widget.routeLabel != null && widget.onRoute != null)
          _toolText(
            key: const ValueKey('player-route'),
            tooltip: '切换播放线路',
            label: widget.routeLabel!,
            onPressed: widget.enabled ? () => _panel(widget.onRoute!) : null,
            width: 62,
          ),
      ],
      if (showPush) _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (showEpisodes)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (showCompare) _enhancementCompareButton(),
      if (showVolume)
        _toolIcon(
          key: const ValueKey('player-volume'),
          tooltip: '音量',
          icon: volume == 0
              ? Icons.volume_off_rounded
              : Icons.volume_up_rounded,
          onPressed: widget.enabled
              ? () => _panel(() => _openVolume(volume))
              : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
      if (widget.onFullscreen != null)
        _toolIcon(
          key: const ValueKey('player-fullscreen'),
          tooltip: fullscreen ? '退出全屏' : '旋转与全屏',
          icon: fullscreen
              ? Icons.fullscreen_exit_rounded
              : Icons.fullscreen_rounded,
          onPressed: widget.onFullscreen,
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Widget _mobileControlRow({required bool fullscreen}) {
    final tools = [
      _toolText(
        key: const ValueKey('player-speed'),
        tooltip: '倍速',
        label: '${widget.speed}x',
        onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
        width: 50,
      ),
      _toolText(
        key: const ValueKey('player-quality'),
        tooltip: '清晰度',
        label: widget.qualityLabel,
        onPressed: widget.enabled ? () => _panel(widget.onQuality) : null,
        width: 52,
      ),
      if (widget.routeLabel != null && widget.onRoute != null)
        _toolText(
          key: const ValueKey('player-route'),
          tooltip: '切换播放线路',
          label: widget.routeLabel!,
          onPressed: widget.enabled ? () => _panel(widget.onRoute!) : null,
          width: 62,
        ),
      if (widget.onPush != null)
        _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (fullscreen)
        _toolIcon(
          key: const ValueKey('player-episodes'),
          tooltip: '选集',
          icon: Icons.grid_view_rounded,
          onPressed: widget.enabled ? () => _panel(widget.onEpisodes) : null,
        ),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: Icons.picture_in_picture_alt_rounded,
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
      // 右下角固定全屏键：竖屏进入全屏、全屏时退出
      _toolIcon(
        key: const ValueKey('player-fullscreen-toggle'),
        tooltip: fullscreen ? '退出全屏' : '进入全屏',
        icon: fullscreen
            ? Icons.fullscreen_exit_rounded
            : Icons.fullscreen_rounded,
        onPressed: widget.enabled && widget.onFullscreen != null
            ? widget.onFullscreen
            : null,
      ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 0, 2, 0),
      child: _clusteredToolRow(tools),
    );
  }

  Future<void> _openVolume(double initialVolume) async {
    var volume = initialVolume.clamp(0.0, 100.0);
    await showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.transparent,
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (dialogContext, animation, secondaryAnimation) =>
          StatefulBuilder(
            builder: (context, setState) => SafeArea(
              child: Align(
                alignment: Alignment.bottomRight,
                child: Padding(
                  padding: EdgeInsets.only(
                    right: widget.swipeEnabled ? 12 : 20,
                    bottom: widget.fullscreen ? 88 : 74,
                  ),
                  child: Material(
                    color: Colors.black.withValues(alpha: .88),
                    borderRadius: BorderRadius.circular(18),
                    child: SizedBox(
                      width: 62,
                      height: 192,
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            tooltip: volume == 0 ? '恢复音量' : '静音',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 40,
                            ),
                            padding: EdgeInsets.zero,
                            onPressed: () {
                              final next = volume == 0 ? 100.0 : 0.0;
                              setState(() => volume = next);
                              unawaited(widget.player.setVolume(next));
                            },
                            icon: Icon(
                              volume == 0
                                  ? Icons.volume_off_rounded
                                  : Icons.volume_up_rounded,
                              size: 22,
                              color: Colors.white,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 112,
                            child: RotatedBox(
                              quarterTurns: -1,
                              child: SliderTheme(
                                data: SliderTheme.of(context).copyWith(
                                  trackHeight: 3,
                                  thumbShape: const RoundSliderThumbShape(
                                    enabledThumbRadius: 6,
                                  ),
                                  overlayShape: const RoundSliderOverlayShape(
                                    overlayRadius: 14,
                                  ),
                                ),
                                child: Slider(
                                  value: volume,
                                  max: 100,
                                  divisions: 20,
                                  onChanged: (value) {
                                    setState(() => volume = value);
                                    unawaited(widget.player.setVolume(value));
                                  },
                                ),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 28,
                            child: Center(
                              child: Text(
                                '${volume.round()}%',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontFeatures: [FontFeature.tabularFigures()],
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
      transitionBuilder: (context, animation, secondaryAnimation, child) =>
          FadeTransition(
            opacity: animation,
            child: SlideTransition(
              position:
                  Tween<Offset>(
                    begin: const Offset(.04, .08),
                    end: Offset.zero,
                  ).animate(
                    CurvedAnimation(parent: animation, curve: Curves.easeOut),
                  ),
              child: child,
            ),
          ),
    );
  }

  Widget _enhancementCompareButton() {
    final enhancement = widget.enhancement;
    if (enhancement == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: enhancement,
      builder: (_, _) {
        if (!enhancement.canCompare) return const SizedBox.shrink();
        return _toolIcon(
          key: const ValueKey('player-enhancement-compare'),
          tooltip: enhancement.comparing ? '原画对比中，点击恢复增强' : '原画对比',
          icon: Icons.compare_rounded,
          onPressed: widget.enabled
              ? () {
                  widget.interactions.cancel();
                  unawaited(enhancement.toggleCompare());
                  _show();
                }
              : null,
          selected: enhancement.comparing,
        );
      },
    );
  }

  Widget _gestureFeedback() => AnimatedBuilder(
    animation: widget.interactions,
    builder: (context, _) {
      final feedback = widget.interactions.feedback;
      if (feedback.isEmpty) return const SizedBox.shrink();
      // 长按倍速这类常驻提示要克制：半透明小胶囊 + 上移，避免整块黑幕压画面
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.62),
          child: AnimatedOpacity(
            opacity: feedback.contains('松开恢复') ? .72 : .9,
            duration: const Duration(milliseconds: 180),
            child: Container(
              margin: const EdgeInsets.all(16),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: .38),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                feedback,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  height: 1.2,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _TapRipple {
  const _TapRipple({
    required this.seq,
    required this.origin,
    required this.forward,
  });
  final int seq;
  final Offset origin;
  final bool forward;
}
