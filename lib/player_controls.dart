import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';

import 'danmaku_controller.dart';
import 'lan_controller.dart';
import 'player_interactions.dart';
import 'widgets.dart';
import 'video_enhancement.dart';
import 'app_icons.dart';

class PlayerControls extends StatefulWidget {
  const PlayerControls({
    super.key,
    required this.player,
    required this.interactions,
    required this.enabled,
    required this.fullscreen,
    required this.showOnPlaybackReady,
    this.onFullscreen,
    this.forceLandscape = false,
    required this.onBack,
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
    this.onDisplayOptions,
    this.skipMarksSet = false,
    this.showDanmaku = false,
    this.danmakuEnabled = false,
    this.danmaku,
    this.swipeEnabled = false,
    this.panelOpen = false,
    this.onSeek,
    this.onDanmaku,
    this.onRetryDanmaku,
    this.onPush,
    this.onPictureInPicture,
    this.enhancement,
    this.onNext,
    this.hasNext = false,
    this.compact = false,
    this.landscapeChrome = false,
    this.showQuality = true,
    this.onPortraitFullscreen,
    this.onLandscapeFullscreen,
    this.onExitFullscreen,
    this.onLockChanged,
    this.danmakuStatusText = '',
    this.batteryLevel,
  });

  final Player player;
  final PlayerInteractions interactions;
  final bool enabled;
  final bool fullscreen;
  final bool showOnPlaybackReady;
  final VoidCallback? onFullscreen;

  final bool forceLandscape;
  final VoidCallback onBack;
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

  /// 画面比例 / 音轨 / 片头尾入口（右侧面板，一颗按钮全包）。
  final Future<void> Function()? onDisplayOptions;

  /// 这部剧是否已标定过片头尾：真则上行「画面」按钮点亮。
  final bool skipMarksSet;
  final bool showDanmaku;
  final bool danmakuEnabled;
  final DanmakuController? danmaku;
  final bool swipeEnabled;
  final bool panelOpen;
  final Future<void> Function(Duration)? onSeek;
  final Future<void> Function()? onDanmaku;
  final Future<void> Function()? onRetryDanmaku;
  final Future<void> Function()? onPush;
  final Future<void> Function()? onPictureInPicture;
  final VideoEnhancementController? enhancement;

  /// 下一集（横屏下行左侧「▶|」）；hasNext=false 时置灰。
  final VoidCallback? onNext;
  final bool hasNext;

  /// 非全屏竖屏：视频区只有 200 来 dp，套两行会吃掉半屏画面，
  /// 降级为单行紧凑栏。
  final bool compact;

  /// 当前是否横屏全屏（决定上行/下行的按钮组合）。
  final bool landscapeChrome;

  /// 清晰度只对红果源开放（用户定调：其他源不要这颗按钮）。
  final bool showQuality;
  final VoidCallback? onPortraitFullscreen;

  /// 右下角「横屏全屏」键：非全屏时进横屏全屏，横屏全屏态下改为退出全屏。
  final VoidCallback? onLandscapeFullscreen;
  final VoidCallback? onExitFullscreen;

  /// 锁定状态变化回调：横屏锁屏时外层要据此把屏幕朝向钉住，
  /// 否则锁了照样能旋转设备看画面。
  final ValueChanged<bool>? onLockChanged;

  /// 弹幕只读状态文案（本项目无发送能力，替代参考 App 的输入框）。
  final String danmakuStatusText;
  final int? batteryLevel;

  @override
  State<PlayerControls> createState() => _PlayerControlsState();
}

class _PlayerControlsState extends State<PlayerControls> {
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  Timer? _hideTimer;
  bool _visible = true;

  /// 横屏锁定：控制栏收起且点击画面不再唤出，只留左中锁钮可解锁。
  bool _locked = false;

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
        if (mounted) setState(() {});
        // 暂停与恢复播放都不再主动弹出控制栏（旧逻辑在这里 _show()，
        // 导致「做什么它都出来」）；只在恢复播放时重新安排一次自动隐藏
        if (playing && !wasPlaying && widget.enabled) {
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
    // 退出横屏版式（退回内嵌/转竖屏）时必须解掉锁定：竖屏没有锁钮，
    // 留着 _locked 会让控制栏再也唤不出来，只能退出播放页。
    if (!widget.landscapeChrome && _locked) {
      _locked = false;
      _visible = true;
      _fading = true;
      _scheduleHide();
      // 离开横屏版式自动解锁：外层钉住的方向也要一并松开，
      // 否则退回竖屏后方向还被锁着。
      widget.onLockChanged?.call(false);
    }
    if (widget.enabled != oldWidget.enabled ||
        widget.panelOpen != oldWidget.panelOpen ||
        widget.fullscreen != oldWidget.fullscreen ||
        widget.showOnPlaybackReady != oldWidget.showOnPlaybackReady) {
      _seekValue = null;
      // 显示即上线（_fading 可能在上次淡出后被置 false）；
      // 隐藏则等淡出结束后把子树下线。
      _fading = true;
      if (!widget.enabled && oldWidget.enabled) {
        // 播放出错/切集（enabled=false）时收起控制栏
        _visible = false;
      }
      if (widget.enabled && !oldWidget.enabled) {
        // 播放就绪只提示一次；暂停恢复不再自动弹工具栏
        _visible = widget.showOnPlaybackReady;
      } else if (widget.panelOpen != oldWidget.panelOpen ||
          widget.fullscreen != oldWidget.fullscreen) {
        _visible = true;
      }
      if (_locked) _visible = false;
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
    // 长按倍速只弹提示胶囊，不把工具栏顶出来（否则倍速全程 HUD 挡画面）；
    // 刚滑完进度的一小段时间里，提示照弹但不把工具栏唤出来
    if (widget.interactions.feedback.isNotEmpty &&
        !widget.interactions.boosting &&
        !widget.interactions.quiet) {
      _show();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    // 暂停中也要照常收起：以前这里把「暂停」当成不隐藏的条件，
    // 结果点了暂停后中央按钮就长期杵在画面上
    if (!widget.enabled || widget.panelOpen || _seekValue != null || _locked) {
      return;
    }
    _hideTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted ||
          !widget.enabled ||
          widget.panelOpen ||
          _seekValue != null ||
          _locked) {
        return;
      }
      // 倍速/缓冲中直接收起，不再续期：倍速有提示胶囊、缓冲有中央转圈，
      // 控制栏继续杵着只会挡画面
      _setVisible(false);
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
    if (value && _locked) return;
    setState(() {
      _visible = value;
      _fading = true;
    });
    if (!value) {
      _scheduleControlsOffline();
    }
  }

  void _show() {
    if (!mounted || _locked) return;
    if (!_visible) _setVisible(true);
    _scheduleHide();
  }

  void _tap() {
    if (widget.interactions.suppressTap || _locked) return;
    widget.onFocusSurface();
    // 单击切换控制条显隐；控制栏收起后子树会下线，必须走 _setVisible
    // 才会重新上线。
    _setVisible(!_visible);
    _scheduleHide();
  }

  /// 横屏锁定：收起控制栏并禁止唤出，再点左中锁钮解锁。
  /// 锁定还要真的锁住屏幕方向（通知外层把朝向钉住），否则旋转设备
  /// 画面照样跟着转，锁了等于没锁。
  void _toggleLock() {
    setState(() {
      _locked = !_locked;
      _visible = !_locked;
      _fading = true;
    });
    widget.onLockChanged?.call(_locked);
    if (_locked) {
      _hideTimer?.cancel();
      _scheduleControlsOffline();
    } else {
      _scheduleHide();
    }
  }

  Future<void> _panel(Future<void> Function() open) async {
    if (_locked) return;
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
                    ripple.forward
                        ? AppIcon(AppIcons.fastForward, color: Colors.white, size: 26)
                        : AppIcon(AppIcons.fastRewind, color: Colors.white, size: 26),
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
    // 手势 HUD 的显隐（gestureActive）逐帧变化，把依赖 interactions 的
    // 可见性判断收进 ListenableBuilder：手势期间只重建控制层子树。
    return ListenableBuilder(
      listenable: widget.interactions,
      builder: (context, _) {
        final state = widget.player.state;
        final gestureActive =
            widget.interactions.hudState.type != SwipeAction.none;
        // 锁定后控制栏彻底不出现（面板也不弹），只留左中锁钮。
        final visible =
            (_visible || widget.panelOpen) && !gestureActive && !_locked;
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
                    if (_locked) return;
                    // 控件显示时，落在底部控制区的手势交给控件自己处理，
                    // 否则裸 Listener 会先启动长按，把按钮长按抢成 2 倍速。
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
                  onPointerMove: (event) {
                    if (_locked) return;
                    widget.interactions.pointerMove(event);
                  },
                  onPointerUp: (event) {
                    if (_locked) return;
                    widget.interactions.pointerUp(event);
                  },
                  onPointerCancel: widget.interactions.pointerCancel,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _tap,
                    onDoubleTap: () {
                      if (_locked ||
                          !widget.enabled ||
                          widget.interactions.suppressTap) {
                        return;
                      }
                      final origin = widget.interactions.lastTapOrigin;
                      final width = widget.interactions.viewWidth;
                      if (origin != null &&
                          width > 0 &&
                          widget.onSeek != null) {
                        final back = origin.dx < width * 0.5;
                        final state = widget.player.state;
                        final durationSec = state.duration.inSeconds;
                        var target =
                            state.position.inSeconds + (back ? -10 : 10);
                        if (durationSec > 0) {
                          target = target.clamp(0, durationSec);
                        } else if (target < 0) {
                          target = 0;
                        }
                        unawaited(widget.onSeek!(Duration(seconds: target)));
                        widget.interactions.hint(
                          back ? '快退 10 秒' : '快进 10 秒',
                        );
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
                    // 淡出动画结束（+20ms 余量）后把整棵控制栏下线停绘。
                    child: _fading
                        ? AnimatedOpacity(
                            opacity: visible ? 1 : 0,
                            duration: const Duration(milliseconds: 180),
                            child: _chromeLayer(constraints),
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
                // 左中锁钮：横屏全屏常驻（控制栏显示时也在）。
                // 锁定时不看 enabled：加载中/出错时若把锁钮一起藏掉，用户就
                // 再也解不开锁、只能退出页面。
                if (widget.landscapeChrome && (widget.enabled || _locked))
                  _lockButton(visible || _locked),
                _gestureFeedback(),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 控制栏主体：上行（返回/标题/状态钮）+ 进度行 + 下行（播放/切集/功能）。
  /// 版式按参考截图：进度条在按钮行上方，按钮行分左右两组。
  Widget _chromeLayer(BoxConstraints constraints) {
    return Stack(
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
            4 + _sideChromeInset(left: true),
            _topChromeInset(),
            4 + _sideChromeInset(left: false),
            _bottomChromeInset(),
          ),
          child: Column(
            children: [
              _topRow(),
              const Spacer(),
              // 下行自带进度行（横竖屏都是「进度在上、按钮在下」）。
              _bottomRow(width: constraints.maxWidth),
            ],
          ),
        ),
      ],
    );
  }

  /// 上行栏：返回 + 剧名 + 画质小标签，右端状态钮组（比例/投屏/画中画）
  /// 与电池时间。返回恒为「返回上一页」，退出全屏另有独立键。
  Widget _topRow() {
    final landscape = widget.landscapeChrome;
    // 窄屏（真机竖屏逻辑宽常常只有 320）上行挤满状态钮后，Expanded 会被
    // 压到 0 —— 剧名整条消失。这里让紧凑档让位：时间文字与画质标签收窄，
    // 保证标题始终有可读宽度。
    final width = MediaQuery.sizeOf(context).width;
    final dense = !landscape && width < 400;
    return Row(
      children: [
        _overlayIconButton(
          tooltip: '返回',
          onPressed: widget.onBack,
          icon: AppIcon(AppIcons.arrowBack, size: 22),
        ),
        const SizedBox(width: 2),
        Expanded(
          child: Row(
            children: [
              Flexible(
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
              if (widget.showQuality && widget.qualityLabel.isNotEmpty)
                _qualityTag(dense: dense),
            ],
          ),
        ),
        ..._topStatusButtons(landscape, dense: dense),
        if (widget.batteryLevel != null) _batteryStatus(dense: dense),
      ],
    );
  }

  /// 画质小标签：11px 白 70%，点开清晰度面板（旧版是一颗方块按钮，
  /// 和倍速/线路挤在一行，现在收进标题行右侧）。
  Widget _qualityTag({bool dense = false}) => Padding(
    padding: EdgeInsets.only(left: dense ? 4 : 6),
    child: GestureDetector(
      key: const ValueKey('player-quality'),
      behavior: HitTestBehavior.opaque,
      onTap: widget.enabled ? () => _panel(widget.onQuality) : null,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 4 : 6,
          vertical: dense ? 1 : 2,
        ),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .14),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          widget.qualityLabel,
          maxLines: 1,
          style: TextStyle(
            fontSize: dense ? 10 : 11,
            height: 1.2,
            fontWeight: FontWeight.w600,
            color: Colors.white.withValues(alpha: .78),
          ),
        ),
      ),
    ),
  );

  /// 上行右侧状态钮：横屏给比例/投屏/画中画/退出全屏，竖屏给弹幕/投屏/画中画。
  List<Widget> _topStatusButtons(bool landscape, {bool dense = false}) {
    final danmakuInTop = !landscape && widget.showDanmaku && widget.danmaku != null;
    return [
      if (danmakuInTop) _danmakuTool(badge: false),
      // 画面比例 + 音轨 + 片头尾合成一颗，两栏都在上行（用户定调）。
      if (widget.onDisplayOptions != null)
        _toolIcon(
          key: const ValueKey('player-display'),
          tooltip: '画面比例与片头尾',
          icon: AppIcon(AppIcons.tune, size: 20),
          onPressed: widget.enabled
              ? () => _panel(widget.onDisplayOptions!)
              : null,
          selected: widget.skipMarksSet,
        ),
      if (widget.onPush != null)
        _lanPushTool(const ValueKey('fullscreen-lan-push')),
      if (widget.onPictureInPicture != null)
        _toolIcon(
          key: const ValueKey('player-picture-in-picture'),
          tooltip: '画中画',
          icon: AppIcon(AppIcons.pip, size: 20),
          onPressed: widget.enabled
              ? () => _panel(widget.onPictureInPicture!)
              : null,
        ),
    ];
  }

  /// 电池 + 当前时间（照参考截图）：电量换算成图标内部填充宽度，
  /// 取不到电量时整颗不渲染。窄屏只留电池图标——把 38dp 让给剧名更值。
  Widget _batteryStatus({bool dense = false}) {
    final level = widget.batteryLevel!.clamp(0, 100);
    final now = DateTime.now();
    final clock =
        '${now.hour.toString().padLeft(2, '0')}:'
        '${now.minute.toString().padLeft(2, '0')}';
    return Padding(
      padding: EdgeInsets.only(left: dense ? 4 : 6, right: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Tooltip(
            message: '$level%',
            child: _BatteryMeter(level: level),
          ),
          if (!dense) ...[
            const SizedBox(width: 4),
            Text(
              clock,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: .9),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _overlayIconButton({
    required String tooltip,
    required VoidCallback? onPressed,
    required Widget icon,
  }) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 2),
    child: IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 44, height: 44),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
      icon: icon,
    ),
  );

  /// 中央不再挂常驻控件（旧版那颗独立生命周期的播放键是「什么时候都在
  /// 冒出来」的根源）：播放/暂停收到下行栏左侧。
  Widget _playPauseButton({required bool playing, double size = 26}) => _toolIcon(
    key: const ValueKey('player-play-pause'),
    tooltip: playing ? '暂停播放' : '开始播放',
    icon: AppIcon(playing ? AppIcons.playerPause : AppIcons.playerPlay, size: size),
    onPressed: widget.enabled
        ? () {
            widget.onTogglePlayback();
            _show();
          }
        : null,
  );

  /// 左中锁钮：只在横屏出现，跟控制栏一起显隐。
  /// 锁定后控制栏消失、这颗常驻，图标换成「开锁」——用户要能一眼看出
  /// 现在锁着、点它就是解锁（旧版一直是同一把锁，看不出可点）。
  Widget _lockButton(bool show) {
    return Align(
      alignment: const Alignment(-.94, 0),
      child: IgnorePointer(
        ignoring: !show,
        child: AnimatedOpacity(
          opacity: show ? 1 : 0,
          duration: const Duration(milliseconds: 120),
          child: GestureDetector(
            key: const ValueKey('player-lock'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggleLock,
            child: Tooltip(
              message: _locked ? '点击解锁' : '锁定屏幕',
              child: Opacity(
                opacity: _locked ? .78 : 1,
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _locked
                        ? Colors.white.withValues(alpha: .3)
                        : Colors.white.withValues(alpha: .22),
                  ),
                  alignment: Alignment.center,
                  child: _locked
                      ? AppIcon(
                          AppIcons.playerLockOpen,
                          size: 20,
                          color: Colors.white,
                        )
                      : AppIcon(
                          AppIcons.playerLock,
                          size: 20,
                          color: Colors.white.withValues(alpha: .9),
                        ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _bottomRow({required double width}) {
    return widget.landscapeChrome
        ? _landscapeBottomRow(width: width)
        : _portraitBottomRow(width: width);
  }

  /// 弹幕状态文字（横屏下行按钮右侧）：状态随加载进度变化，这里局部监听，
  /// 不惊动整棵控制栏。[danmakuStatusText] 非空时优先（宿主可覆盖文案）。
  Widget _danmakuStatusLabel() {
    if (widget.danmakuStatusText.isNotEmpty) {
      return _danmakuStatusText(widget.danmakuStatusText);
    }
    final danmaku = widget.danmaku;
    if (danmaku == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: danmaku,
      builder: (context, _) {
        final status = danmaku.status;
        if (status.isEmpty) return const SizedBox.shrink();
        return _danmakuStatusText(status);
      },
    );
  }

  Widget _danmakuStatusText(String text) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 12,
      height: 1.2,
      color: Colors.white.withValues(alpha: .7),
    ),
  );

  /// 横屏下行：进度行在上，按钮行在下（左：播放/下一集/弹幕+状态文字，
  /// 右：播放源/倍速/选集）。不再用 FittedBox 等比缩小整行——按钮被压小
  /// 正是旧版「挤成一坨」的根源。
  Widget _landscapeBottomRow({required double width}) {
    final playing = widget.player.state.playing;
    final hasDanmaku = widget.showDanmaku && widget.danmaku != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 与竖屏、参考截图同一层次：进度条在按钮行上方。
        _progressRow(),
        SizedBox(
          height: 46,
          child: Row(
            children: [
              _playPauseButton(playing: playing),
              _toolIcon(
                key: const ValueKey('player-next-episode'),
                tooltip: '下一集',
                icon: AppIcon(AppIcons.skipNext, size: 22),
                onPressed:
                    widget.enabled && widget.hasNext && widget.onNext != null
                    ? widget.onNext
                    : null,
              ),
              if (hasDanmaku) ...[
                const SizedBox(width: 4),
                _danmakuTool(badge: false),
              ],
              if (widget.showDanmaku && widget.danmaku != null) ...[
                const SizedBox(width: 8),
                Flexible(child: _danmakuStatusLabel()),
              ],
              const Spacer(),
              // 右侧按钮组（线路/倍速/选集/增强对比/转竖屏全屏/退出全屏）
              // 包进横向滚动容器：窄宽（测试以竖屏设备模拟横屏视图模式，宽约
              // 390）下不再溢出，所有按钮始终保留（不再按宽度隐藏线路钮）；
              // reverse:true 让最右的「退出全屏」始终贴右边缘可见。
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  reverse: true,
                  child: Row(
                    children: [
                      if (widget.routeLabel != null && widget.onRoute != null)
                        _toolText(
                          key: const ValueKey('player-route'),
                          tooltip: '切换播放线路',
                          label: widget.routeLabel!,
                          onPressed: widget.enabled
                              ? () => _panel(widget.onRoute!)
                              : null,
                          width: 84,
                        ),
                      const SizedBox(width: 12),
                      _toolText(
                        key: const ValueKey('player-speed'),
                        tooltip: '倍速',
                        label: '${widget.speed}x',
                        onPressed:
                            widget.enabled ? () => _panel(widget.onSpeed) : null,
                        width: 50,
                      ),
                      const SizedBox(width: 12),
                      _toolText(
                        key: const ValueKey('player-episodes'),
                        tooltip: '选集',
                        label: '选集',
                        onPressed: widget.enabled
                            ? () => _panel(widget.onEpisodes)
                            : null,
                        width: 44,
                      ),
                      if (width >= 820) _enhancementCompareButton(),
                      // 横屏全屏态下给「转竖屏全屏」键：视频类全屏后没有任何旋转入口，
                      // 与最右的「退出全屏」组成右下角固定双钮簇（短剧也有，和底栏去重）。
                      if (widget.onPortraitFullscreen != null)
                        _toolIcon(
                          key: const ValueKey('player-portrait-fullscreen'),
                          tooltip: '竖屏全屏',
                          icon: AppIcon(AppIcons.screenRotate, size: 20),
                          onPressed: widget.onPortraitFullscreen,
                        ),
                      // 退出全屏放最右下（用户定调）：下行最右一颗，不再占上行。
                      if (widget.onExitFullscreen != null) ...[
                        const SizedBox(width: 8),
                        _toolIcon(
                          key: const ValueKey('player-fullscreen-exit'),
                          tooltip: '退出全屏',
                          icon: AppIcon(AppIcons.fullscreenExit, size: 20),
                          onPressed: widget.onExitFullscreen,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 竖屏下行：进度行在上、按钮行在下（与横屏同一套视觉层次）。
  /// 按钮是固定宽度的一行，按可用宽度逐级让位（横屏全屏键 <340 不出现），
  /// 绝不再整行 FittedBox 等比缩小。
  Widget _portraitBottomRow({required double width}) {
    final playing = widget.player.state.playing;
    // 半屏内嵌（compact）：进度条与按钮合并成一条 44 高的单行（见
    // _compactBottomRow），不再上下两行吃掉半屏画面；极窄时自动藏全屏钮。
    if (widget.compact) return _compactBottomRow(width: width);
    // 窄屏（<360）逐级让位：按钮收窄、低频的「片头尾」整颗收起，
    // 保证任何宽度下都不会整行溢出（旧版靠 FittedBox 缩，按钮被压得看不清）。
    final dense = width < 360;
    // 半屏（内嵌）与全屏给不同的按钮组：半屏藏掉三颗大按钮。
    final full = !widget.compact;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _progressRow(),
        SizedBox(
          height: 46,
          child: Row(
            children: [
              _playPauseButton(playing: playing),
              // 半屏（内嵌）只留播放与两颗全屏键：播放源/倍速/选集都收进
              // 下方详情页，视频区不再被大按钮压住，主体更干净。
              if (full && widget.routeLabel != null && widget.onRoute != null)
                _toolText(
                  key: const ValueKey('player-route'),
                  tooltip: '切换播放线路',
                  label: '播放源',
                  onPressed: widget.enabled
                      ? () => _panel(widget.onRoute!)
                      : null,
                  width: dense ? 48 : 52,
                ),
              if (full)
                _toolText(
                  key: const ValueKey('player-speed'),
                  tooltip: '倍速',
                  label: '${widget.speed}x',
                  onPressed: widget.enabled ? () => _panel(widget.onSpeed) : null,
                  width: dense ? 40 : 44,
                ),
              const Spacer(),
              if (full)
                _toolText(
                  key: const ValueKey('player-episodes'),
                  tooltip: '选集',
                  label: '选集',
                  onPressed: widget.enabled
                      ? () => _panel(widget.onEpisodes)
                      : null,
                  width: dense ? 36 : 40,
                ),
              // 竖屏全屏 / 横屏全屏 两颗互斥切换：所在形态那颗变「退出全屏」，
              // 另一颗变交叉切换（竖↔横），任何时候都能一键换形态。
              _toolIcon(
                key: const ValueKey('player-portrait-fullscreen'),
                tooltip: widget.fullscreen
                    ? (widget.landscapeChrome ? '竖屏全屏' : '退出全屏')
                    : '竖屏全屏',
                icon: AppIcon(
                  widget.fullscreen && !widget.landscapeChrome
                      ? AppIcons.fullscreenExit
                      : AppIcons.fullscreen,
                  size: 20,
                ),
                onPressed: widget.enabled
                    ? (widget.fullscreen
                          ? (widget.landscapeChrome
                                ? widget.onPortraitFullscreen
                                : (widget.onExitFullscreen ??
                                    widget.onFullscreen))
                          : widget.onPortraitFullscreen)
                    : null,
              ),
              _toolIcon(
                key: const ValueKey('player-landscape-fullscreen'),
                tooltip: widget.landscapeChrome ? '退出全屏' : '横屏全屏',
                icon: AppIcon(AppIcons.screenRotate, size: 20),
                onPressed: widget.enabled
                    ? (widget.landscapeChrome
                          ? (widget.onExitFullscreen ?? widget.onFullscreen)
                          : widget.onLandscapeFullscreen)
                    : null,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 半屏内嵌（compact）：进度条与按钮合并成一条 44 高的单行——播放键在左，
  /// 中间是进度滑块（不显示两侧时间，省宽度），右侧两颗全屏切换钮。原版上下两行
  /// 会吃掉小窗近三分之一画面，单行更矮更干净。内嵌小窗可能很窄（首页续播条 /
  /// 详情页窄列），低于 200dp 时藏掉两颗全屏钮只留播放+进度，绝不溢出黄黑条。
  Widget _compactBottomRow({required double width}) {
    final playing = widget.player.state.playing;
    final showRotate = width >= 200;
    final slider = Expanded(child: _progressRow(showTimes: false));
    return SizedBox(
      height: 44,
      child: Row(
        children: [
          _playPauseButton(playing: playing),
          slider,
          if (showRotate && widget.onPortraitFullscreen != null)
            _toolIcon(
              key: const ValueKey('player-portrait-fullscreen'),
              tooltip: widget.fullscreen
                  ? (widget.landscapeChrome ? '竖屏全屏' : '退出全屏')
                  : '竖屏全屏',
              icon: AppIcon(
                widget.fullscreen && !widget.landscapeChrome
                    ? AppIcons.fullscreenExit
                    : AppIcons.fullscreen,
                size: 20,
              ),
              onPressed: widget.enabled
                  ? (widget.fullscreen
                        ? (widget.landscapeChrome
                              ? widget.onPortraitFullscreen
                              : (widget.onExitFullscreen ?? widget.onFullscreen))
                        : widget.onPortraitFullscreen)
                  : null,
            ),
          if (showRotate && widget.onLandscapeFullscreen != null)
            _toolIcon(
              key: const ValueKey('player-landscape-fullscreen'),
              tooltip: widget.landscapeChrome ? '退出全屏' : '横屏全屏',
              icon: AppIcon(AppIcons.screenRotate, size: 20),
              onPressed: widget.enabled
                  ? (widget.landscapeChrome
                        ? (widget.onExitFullscreen ?? widget.onFullscreen)
                        : widget.onLandscapeFullscreen)
                  : null,
            ),
        ],
      ),
    );
  }

  /// 进度行独立订阅 position 流：播放中唯一 ~4 次/秒的事件只重建这一行，
  /// 不再拖着整棵控制栏（顶栏/按钮/弹幕开关/渐变层）一起重建。
  Widget _progressRow({bool showTimes = true}) {
    final player = widget.player;
    return StreamBuilder<Duration>(
      stream: player.stream.position,
      initialData: player.state.position,
      builder: (context, _) {
        final state = player.state;
        return _progressRowContent(
          showTimes: showTimes,
          duration: state.duration.inMilliseconds / 1000,
          position: state.position.inMilliseconds / 1000,
          buffered: state.buffer.inMilliseconds / 1000,
        );
      },
    );
  }

  double _topChromeInset() {
    // 全屏走 immersiveSticky：系统栏是本应用自己隐藏的，但 viewPadding 依旧
    // 会报状态栏高度——按它退让就等于「画面已经贴边、HUD 还挂在下面一条」，
    // 用户看到的就是「HUD 也在规避状态栏」。全屏一律按贴边处理。
    if (widget.fullscreen) return 8;
    // 非全屏竖屏：外层 SafeArea 已经给系统栏让过位，这里不再叠加。
    if (!widget.swipeEnabled) return 0;
    final top = MediaQuery.viewPaddingOf(context).top;
    if (top <= 0) return 8;
    return (top + 6).clamp(14.0, 60.0);
  }

  double _bottomChromeInset() {
    // 同理：全屏手势条已隐藏，底部只留极小余量，不再按导航栏高度顶起工具行。
    return widget.fullscreen ? 12 : 0;
  }

  /// 横屏时挖孔会落在左右边缘（本机左边缘 144px），画面铺满整屏不让位，
  /// 但返回/标题这些控件必须避开它，否则会被摄像头区域挡住。
  double _sideChromeInset({required bool left}) {
    if (!widget.fullscreen && !widget.swipeEnabled) return 0;
    final padding = MediaQuery.paddingOf(context);
    final inset = left ? padding.left : padding.right;
    if (inset <= 0) return 0;
    return inset.clamp(0.0, 160.0);
  }

  Widget _progressRowContent({
    bool showTimes = true,
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
            if (showTimes)
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
            if (showTimes)
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
    required Widget icon,
    required VoidCallback? onPressed,
    bool selected = false,
  }) => _toolButton(
    key: key,
    tooltip: tooltip,
    onPressed: onPressed,
    selected: selected,
    child: icon,
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
    return ValueListenableBuilder<LanController?>(
      key: key,
      valueListenable: LanController.currentLink,
      builder: (context, link, _) {
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
                : link.connection == null
                    ? AppIcon(AppIcons.playerCast, size: 22)
                    : AppIcon(AppIcons.playerCastConnected, size: 22),
          ),
        );
      },
    );
  }

  /// 控件带命中判定：只圈底部控制区（48 按钮行 + 28 进度行）。
  /// 26% 视口比例只是「别把手势区整片吃掉」的上限；小视口（竖屏内嵌视频区
  /// 只有 ~220dp）里 26% 比控件本身还矮，按钮下半部会落进手势区，点按被
  /// 长按抢成 2 倍速，所以下限必须压住控件真实高度。
  bool _hitsControlBand(Offset position, Size size) {
    if (!size.width.isFinite || !size.height.isFinite) return false;
    if (size.width <= 0 || size.height <= 0) return false;
    // compact 内嵌是单行 44 高（进度与按钮合并），非 compact 是按钮行 46 + 进度行 28。
    final chrome = (widget.compact ? 44 : 46 + 28) + _bottomChromeInset();
    final band = math.min(190.0, math.max(chrome + 8, size.height * .26));
    return position.dy >= size.height - band;
  }

  /// 弹幕状态徽标：状态原本只挂在 tooltip 上，而真机上长按工具按钮会被
  /// 视频区的长按手势抢走（触发倍速播放），用户永远看不到弹幕到底怎么了。
  /// 这里把关键状态压缩成两三个字常驻显示在按钮上方。
  String? _danmakuBadge(String status) {
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

  /// 弹幕按钮。[badge] 为 false 时不带上方状态小字——上行栏只有 44 高，
  /// 状态文字改由横屏下行的 danmakuStatusText 承担。
  Widget _danmakuTool({bool badge = true}) {
    final danmaku = widget.danmaku;
    if (danmaku == null) return const SizedBox.shrink();
    // 弹幕状态（加载中/已载入 N 条/可重试…）随播放进度频繁变化：
    // 在这里局部监听，只重建徽标与按钮，不惊动整个播放页。
    return ListenableBuilder(
      listenable: danmaku,
      builder: (context, _) {
        final status = danmaku.status;
        final retryable = danmaku.canRetry && widget.onRetryDanmaku != null;
        final button = _toolButton(
          key: const ValueKey('player-danmaku-toggle'),
          tooltip: status.isEmpty
              ? (widget.danmakuEnabled ? '关闭弹幕' : '打开弹幕')
              : status,
          visualWidth: 36,
          selected: widget.danmakuEnabled,
          onPressed: widget.enabled
              ? () => _panel(retryable
                    ? widget.onRetryDanmaku!
                    : widget.onDanmaku!)
              : null,
          child: retryable
              ? AppIcon(AppIcons.refresh, size: 21)
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
        final label = badge ? _danmakuBadge(status) : null;
        if (label == null) return button;
        return _danmakuBadgeColumn(label, button);
      },
    );
  }

  Widget _danmakuBadgeColumn(String badge, Widget button) {
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
          icon: AppIcon(AppIcons.compare, size: 22),
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
      // 长按倍速这类常驻提示要克制：半透明小胶囊 + 画面正中偏上，
      // 顶部让给手势 HUD 的新细条，避免两者叠在一起。
      return IgnorePointer(
        child: Align(
          alignment: const Alignment(0, -.5),
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

/// 电量图标：外框 + 按电量填充的内条 + 右端小凸起，低电转橙红。
/// 自己画而不是引图标资源，省得为一个 22×11 的小件加 SVG。
class _BatteryMeter extends StatelessWidget {
  const _BatteryMeter({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    final low = level <= 20;
    final color = low
        ? const Color(0xFFFF7043)
        : Colors.white.withValues(alpha: .9);
    final ratio = (level.clamp(0, 100)) / 100;
    return SizedBox(
      width: 22,
      height: 12,
      child: Row(
        children: [
          Expanded(
            child: Container(
              padding: const EdgeInsets.all(1.5),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: color, width: 1.1),
              ),
              child: Align(
                alignment: Alignment.centerLeft,
                child: FractionallySizedBox(
                  widthFactor: ratio == 0 ? 0.08 : ratio,
                  child: Container(
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Container(
            width: 1.8,
            height: 5,
            margin: const EdgeInsets.only(left: 1),
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(1),
            ),
          ),
        ],
      ),
    );
  }
}
