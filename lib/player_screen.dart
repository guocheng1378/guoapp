import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'battery_level.dart';
import 'catalog_browser.dart' show dramaIsLongDrama;
import 'core_bridge.dart';
import 'danmaku_controller.dart';
import 'danmaku_overlay.dart';
import 'detail_screen.dart';
import 'download_picker.dart';
import 'download_summary.dart';
import 'downloads_screen.dart';
import 'follow_state.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_preloader.dart';
import 'playback_recovery.dart';
import 'playback_preferences.dart';
import 'related_catalog_screen.dart';
import 'related_dramas.dart';
import 'player_controls.dart';
import 'player_interactions.dart';
import 'player_menu.dart';
import 'player_side_panel.dart';
import 'player_skip_marks.dart';
import 'screen_brightness.dart';
import 'television_controls.dart';
import 'widgets.dart';
import 'sources_screen.dart';
import 'lan_controller.dart';
import 'lan_screen.dart';
import 'video_enhancement.dart';
import 'video_enhancement_settings.dart';
import 'video_output_size.dart';
import 'app_icons.dart';

/// 画面比例档位：自适应/铺满/拉伸直接换 Video 的 fit；带 aspect 的档位
/// 额外把画面裁进固定比例的框（cover），用来消黑边或统一画面形状。
enum _PlayerFitMode {
  contain('自适应', BoxFit.contain, null),
  cover('铺满裁剪', BoxFit.cover, null),
  fill('拉伸填满', BoxFit.fill, null),
  ratio16x9('16:9', BoxFit.cover, 16 / 9),
  ratio4x3('4:3', BoxFit.cover, 4 / 3),
  ratio9x16('9:16', BoxFit.cover, 9 / 16);

  const _PlayerFitMode(this.label, this.fit, this.aspect);

  final String label;
  final BoxFit fit;
  final double? aspect;
}

/// 播放视图状态：替代旧版 `_showFullscreen` + `_forceLandscape` 两个布尔互相
/// 纠缠的写法（那是「返回/全屏/旋转」三种语义混乱的根源）。
enum PlaybackViewMode {
  /// 视频 + 下方详情面板。
  inline,

  /// 竖屏沉浸（短剧默认形态，长剧也可手动进入）。
  portraitFullscreen,

  /// 横屏全屏。
  landscapeFullscreen,
}

class PlayerScreen extends StatefulWidget {
  const PlayerScreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
    this.localOnly = false,
    this.allowOnlineFallback = true,
    this.mediaId,
    this.playerFactory,
    this.videoBuilder,
    this.handoff,
  });
  final DramaDetail detail;
  final int initialIndex;
  final double initialPosition;
  final bool localOnly;
  final bool allowOnlineFallback;
  final String? mediaId;
  final AppRepository repository;
  final LocalStore store;
  final LanIncomingPlayback? handoff;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController? _video;
  late final VideoEnhancementController _enhancement;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  bool _preloadEnabled = true;
  late final DanmakuController _danmaku;
  int _seekSequence = 0;
  bool _danmakuEnabled = true;
  late final PlayerInteractions _interactions;
  double _savedBrightness = 1;
  double _savedVolume = 100;
  Timer? _mediaMemoryTimer;
  /// 播完一集到自动接下一集的等待秒数；0 = 播完立即连播，不显示倒计时。
  static const advanceCountdownSeconds = 0;
  int _advanceSeconds = 0;
  Timer? _advanceTimer;
  final _playerFocus = FocusNode(debugLabel: 'player-surface');
  final _videoPaneKey = GlobalKey();
  final _menuRevision = ValueNotifier<int>(0);
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final _recovery = PlaybackRecovery();
  Object _lanIdentity = Object();
  bool _handoffOwned = true;
  double? _lanFirstPosition;
  String? _savedProgressKey;
  // 本次播放是否已用 notify 通知过「继续观看」（周期保存静默，只在退出/切集时通知一次）。
  bool _watchNotified = false;
  // 位置流重活节流：上次执行时的播放位置（毫秒），-1 表示需要立刻执行一次。
  int _lastAppliedPositionMs = -1;
  // 打开后的首个位置事件只做节流基线：resume 初始位置（上次停留处）落在
  // 片头/片尾区间内不应自动拽走，跳片只对后续的播放推进生效。
  bool _positionPrimed = false;
  static const int _positionApplyStepMs = 150;
  final _health = PlaybackHealth();
  Timer? _saveTimer;
  Timer? _healthTimer;
  Timer? _errorTimer;
  Timer? _pictureInPictureExitTimer;
  Future<void> _operations = Future<void>.value();
  late int _index;
  late final int _profileEpoch;
  int _openedIndex = -1;
  int _generation = 0;
  int _requestedQuality = 0;
  bool _loading = true;
  // 切集两阶段：false=还在解析新地址（旧画面暂停定格在屏上），
  // true=地址已就绪、正在换源出首帧（此刻才允许整幅黑遮罩）。
  bool _swapping = false;
  bool _forceOnline = false;
  bool _localFailure = false;
  bool _fullscreen = false;
  bool _automaticFullscreenSuppressed = false;
  // 短剧竖屏播放：进入即竖屏全屏（_portraitFullscreenApplied 守卫只执行一次），
  // _forceLandscape=用户手动旋转到横屏，_forcePortrait=长剧手动进竖屏全屏。
  bool _forceLandscape = false;
  bool _forcePortrait = false;
  bool _portraitFullscreenApplied = false;
  // 「混入横屏视频自动退全屏」只判首集一次：切集时不再把形态踢回半屏。
  bool _portraitFallbackChecked = false;
  bool _panelOpen = false;
  int _mobileTab = 0;
  bool _autoAdvance = true;
  bool? _systemFullscreen;
  bool _exitImmersive = false;
  Orientation? _lastOrientation;
  bool _closed = false;
  bool _acceptErrors = false;
  bool _foreground = true;
  bool _playIntent = true;

  /// 因进后台而暂停播放，回前台要自动续上（用户自己按暂停的不算）
  bool _resumeAfterBackground = false;
  bool _showControlsOnPlaybackReady = true;
  bool _pendingError = false;
  bool _pictureInPictureSupported = false;
  bool _pictureInPictureActive = false;
  bool _pictureInPictureRequested = false;
  bool _pictureInPictureHandlerInstalled = false;
  AppLifecycleState _lifecycleState = AppLifecycleState.resumed;
  String _loadingMessage = '正在准备播放';
  String? _error;
  String? _saveWarning;
  PlaybackPlan? _plan;
  double _speed = 1;
  double _aspectRatio = 9 / 16;
  _PlayerFitMode _fitMode = _PlayerFitMode.contain;
  double _resumePosition = 0;

  /// 片头/片尾标记（按剧保存在 store 里，播放中据此自动跳过）。
  EpisodeSkipMarks _skipMarks = const EpisodeSkipMarks();

  /// 当前这一集是否已跳过片头/片尾：保证一段播放里每段只生效一次。
  bool _introSkipped = false;
  bool _outroSkipped = false;

  /// 标记的存储身份：在线剧按剧 id，本地媒体按 mediaId（两套命名空间）。
  String get _skipMarksId => widget.mediaId ?? widget.detail.drama.id;

  bool _rotating = false;
  /// 横屏锁屏：锁定期间把屏幕朝向钉在当前方向（旋转设备画面不跟随）。
  bool _screenLocked = false;
  /// 竖屏全屏的选集面板是否已展开（底部滑入、推挤视频那种）。
  bool _episodeSheetOpen = false;
  bool _television = false;
  AppOrientationController? _orientationController;
  late final BatteryLevel _battery;
  bool get _pictureInPictureVisible =>
      _pictureInPictureActive || _pictureInPictureRequested;
  bool get _canUsePictureInPicture =>
      !_television &&
      defaultTargetPlatform == TargetPlatform.android &&
      _pictureInPictureSupported;
  bool get _mobile =>
      !_television &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// 短剧竖屏播放形态：手机端且按**整剧**判定为短剧。
  /// 进入播放器直接竖屏全屏，视频保持原始比例；长剧走原行为。
  ///
  /// 判定信号（**不看时长**——时长会漂移：缓存里有无、详情回填自愈，
  /// 同一剧前后判定不一致会让形态在切集时跳变）：
  /// 1) 红果官方竖屏标记按**整剧**聚合：任一集为竖屏即整剧按短剧处理。
  ///    原先取「当前集」的标记，切集会翻转形态（底栏旋转键随之失效）。
  /// 2) 回退全局信号链（显式定性 / 分类标签 / 站源属性，与首页「长剧·短剧」
  ///    分类条同口径，见 catalog_browser.dramaIsLongDrama）。
  bool get _portraitDrama {
    if (!_mobile) return false;
    final verticals = widget.detail.episodes
        .map((episode) => episode.vertical)
        .whereType<bool>()
        .toList();
    if (verticals.isNotEmpty) return verticals.any((vertical) => vertical);
    return !dramaIsLongDrama(
      widget.detail.drama,
      SourceSite.byId(widget.detail.drama.source),
    );
  }
  VideoEnhancementController? get _enhancementForUi =>
      _enhancement.supported ? _enhancement : null;
  PlaybackPreferences get _preferences => PlaybackPreferences(
    speed: _speed,
    quality: _requestedQuality,
    autoAdvance: _autoAdvance,
    danmaku: _danmakuEnabled,
    preload: _preloadEnabled,
    brightness: _interactions.brightness,
    volume: _interactions.volume,
    enhancement: _enhancement.preferences,
  );
  /// 工具行清晰度标签：显示「本集实际播放」的档位（用户定调：界面不再出现
  /// 「自动」这个选项）。站点根本没有画质档位（qualities 全空）时返回空串，
  /// 工具行就不渲染这颗按钮——否则挂个「高清」纯属误导。
  String get _qualityLabel {
    if (_plan?.local == true) return '本地原画';
    // 实际播放档位优先：偏好里存的 1080P 换到只有 720P 的源时，后端会退到
    // 720P 播放（nativePlaybackChoices 找不到该档就不过滤），此时按偏好显示
    // 「1080P」就是在骗人。
    final actual = _plan?.quality ?? 0;
    if (actual > 0) return '${actual}P';
    // plan 还没回来（解析中/换源）时才用持久化偏好兜底，避免按钮闪一下消失。
    if (_requestedQuality > 0) return '${_requestedQuality}P';
    final selectable = (_plan?.qualities ?? const <int>[]).where((q) => q > 0);
    if (selectable.isEmpty) return '';
    return '${selectable.reduce((a, b) => a > b ? a : b)}P';
  }
  String get _session => _plan?.session ?? '';
  double get _currentPosition =>
      _openedIndex == _index && _player.state.position.inMilliseconds > 0
      ? _player.state.position.inMilliseconds / 1000
      : _resumePosition;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _profileEpoch = widget.handoff?.profileEpoch ?? widget.store.profileEpoch;
    final preferences = widget.store.playbackPreferences;
    _speed = preferences.speed;
    _requestedQuality = preferences.quality;
    _autoAdvance = preferences.autoAdvance;
    _danmakuEnabled = preferences.danmaku;
    _preloadEnabled = preferences.preload;
    _skipMarks = widget.store.skipMarksOf(_skipMarksId);
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);
    _danmaku = DanmakuController(widget.repository)
      ..setEnabled(_danmakuEnabled);
    widget.store.addListener(_accessChanged);
    _player =
        widget.playerFactory?.call() ??
        Player(
          configuration: const PlayerConfiguration(
            // 缓冲 64MB：红果等站点的 CDN 首字节等待实测 0.3~16 秒，
            // 缓冲太小会在源站抖动时直接露底成「卡住」；一集短剧 360p
            // 约 10~30MB，64MB 足够把整集铺满。
            bufferSize: 64 * 1024 * 1024,
            logLevel: MPVLogLevel.error,
          ),
        );
    _video = widget.videoBuilder == null
        ? VideoController(
            _player,
            configuration: VideoControllerConfiguration(
              enableHardwareAcceleration: !Platform.isIOS,
            ),
          )
        : null;
    _enhancement = VideoEnhancementController(
      player: _player,
      video: _video,
      preferences: preferences.enhancement,
      category: widget.detail.drama.category,
      tags: widget.detail.drama.tags,
    );
    _interactions = PlayerInteractions(
      player: _player,
      available: () =>
          !_closed &&
          widget.store.profileEpoch == _profileEpoch &&
          !_loading &&
          _error == null &&
          _foreground &&
          !_panelOpen,
      baseSpeed: () => _speed,
      onTogglePlayback: _togglePlayback,
      onSeek: _seekTo,
      onFullscreen: _fullscreenSupported ? _rotate : null,
      onEpisode: (direction) {
        final next = _index + direction;
        if (next < 0) return '已经是第一集';
        if (next >= widget.detail.episodes.length) return '已经是最后一集';
        unawaited(_play(next));
        return '第 ${widget.detail.episodes[next].number} 集';
      },
      initialBrightness: preferences.brightness,
      initialVolume: preferences.volume,
      // 连播倒计时中用户一碰屏幕就取消，避免和手势打架
      onGestureStart: _cancelAdvanceCountdown,
    );
    // 亮度以系统当前亮度为起点：跟系统走才不突兀（之前是画面叠黑纱）
    ScreenBrightness.current().then((value) {
      if (!mounted || _closed || value == null) return;
      unawaited(_interactions.adoptSystemBrightness(value));
    });
    _interactions.addListener(_onInteractionChanged);
    _playerFocus.addListener(() {
      if (!_playerFocus.hasPrimaryFocus && !_closed) _interactions.cancel();
    });
    // 状态区电池：10 秒轮询，读不到数据就整颗不渲染（不打扰播放）。
    _battery = BatteryLevel()..start();
    _configurePictureInPicture();
    _subscriptions.add(
      _player.stream.error.listen((error) {
        if (_enhancement.handlePlaybackError(error)) return;
        if (!_closed && _acceptErrors && mounted && error.trim().isNotEmpty) {
          _queueRecovery();
        }
      }),
    );
    _subscriptions.add(
      _player.stream.completed.listen((completed) {
        if (completed &&
            !_loading &&
            !_closed &&
            _acceptErrors &&
            _error == null) {
          final duration = _player.state.duration;
          // 短剧（几十秒）播完时解码器常停在末尾几秒前，固定 2 秒容差会把
          // 「正常播完」误判成「播放故障」而走进恢复流程；按片长比例放宽。
          final tolerance = Duration(
            milliseconds: (duration.inMilliseconds * .05).round().clamp(
              2000,
              10000,
            ),
          );
          if (duration <= Duration.zero ||
              _player.state.position < duration - tolerance) {
            _queueRecovery();
          } else if (_autoAdvance &&
              _foreground &&
              !_panelOpen &&
              _index + 1 < widget.detail.episodes.length) {
            _startAdvanceCountdown();
          } else {
            _playIntent = false;
            _interactions.cancel();
            unawaited(_player.pause());
            unawaited(_saveProgress(flush: true));
          }
        }
      }),
    );
    _subscriptions.add(
      _player.stream.position.listen((position) {
        if (!_closed && _openedIndex == _index && position > Duration.zero) {
          _resumePosition = position.inMilliseconds / 1000;
        }
        // 位置事件可能高达 10+/s，重活按位置增量节流（约 150ms 一次）；
        // 位置回跳/大幅跳转立即执行，避免跳片与握手确认被吞。
        final ms = position.inMilliseconds;
        final delta = ms - _lastAppliedPositionMs;
        if (!_positionPrimed) {
          // 打开后的首个事件（resume 初始位置）只做基线：不自动跳片，
          // 弹幕/预加载/握手照常收敛。
          _positionPrimed = true;
          _lastAppliedPositionMs = ms;
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
          return;
        }
        if (_lastAppliedPositionMs >= 0 &&
            delta >= 0 &&
            delta < _positionApplyStepMs) {
          return;
        }
        _lastAppliedPositionMs = ms;
        _applySkipMarks(position);
        _syncDanmaku();
        _syncPreload();
        _acknowledgeHandoff();
      }),
    );
    for (final stream in [
      _player.stream.duration,
      _player.stream.buffer,
      _player.stream.playing,
      _player.stream.buffering,
      _player.stream.rate,
      _player.stream.completed,
    ]) {
      _subscriptions.add(
        stream.listen((_) {
          // 状态切换时补一次轻量同步：位置节流窗口内的弹幕/预加载/握手
          // 在下一次状态事件里立刻收敛。跳片只由位置流驱动——缓冲/暂停
          // 等状态事件不应把暂停在片头区间内的用户拽走。
          _syncDanmaku();
          _syncPreload();
          _acknowledgeHandoff();
        }),
      );
    }
    _subscriptions.add(
      _player.stream.videoParams.listen((parameters) {
        final size = videoDisplaySize(parameters);
        if (size == null || !mounted || _closed) return;
        var fallback = false;
        setState(() {
          _aspectRatio = size.width / size.height;
          // 短剧竖屏全屏里混入横屏视频：contain 会上下大黑边，**首集**自动
          // 退回常规形态（横屏设备仍可自动全屏）；用户手动旋转过则尊重。
          //
          // 只判首集一次：原先每集都判，手势切集遇到横屏素材集就把整个
          // 界面踢回半屏（形态突变）。切集后保持竖屏全屏，横屏素材 contain
          // 居中显示、上下黑边。
          if (!_portraitFallbackChecked) {
            _portraitFallbackChecked = true;
            if (_portraitFullscreenApplied &&
                _fullscreen &&
                !_forceLandscape &&
                _aspectRatio >= 1) {
              _fullscreen = false;
              fallback = true;
            }
          }
        });
        if (fallback) {
          unawaited(_syncPlaybackOrientation(fullscreen: false));
        }
        _scheduleSystemUi();
      }),
    );
    _saveTimer = Timer.periodic(
      const Duration(seconds: 5),
      (_) => _saveProgress(),
    );
    _healthTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!_closed &&
          _acceptErrors &&
          !_loading &&
          _error == null &&
          _health.stalled(
            position: _player.state.position,
            playing: _player.state.playing && _playIntent,
            foreground: _foreground,
            now: DateTime.now(),
          )) {
        unawaited(_recover());
      }
    });
    final handoff = widget.handoff;
    if (handoff != null) {
      handoff.consumed = true;
      handoff.stop = () async {
        if (_handoffOwned && !_closed) await _stopForLan();
      };
    }
    if (_profileEpoch != widget.store.profileEpoch ||
        handoff?.cancelled == true) {
      handoff?.fail('接收用户已变更，推送已取消');
      if (handoff != null)
        unawaited(widget.repository.release(handoff.plan.session));
      _loading = false;
      _swapping = false;
      _error = '播放接收已取消';
    } else {
      _play(
        _index,
        position: widget.initialPosition,
        handoffPlan: handoff?.plan,
      );
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_closed) {
        widget.repository.catalogUpdates.publish(
          widget.repository.catalogUpdates.current(widget.detail.drama),
          retryCover: true,
        );
      }
    });
  }

  void _accessChanged() {
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch || widget.store.locked)) {
      _preloader.clear();
      _enhancement.suspend();
      _handoffOwned = false;
      _playIntent = false;
      widget.handoff?.fail('接收端用户已变更');
      unawaited(_player.pause());
    }
    if (!_closed &&
        (widget.store.profileEpoch != _profileEpoch ||
            widget.store.locked ||
            !widget.store.allowsSource('hongguo'))) {
      _danmaku.setPlan(null);
    }
  }

  void _configurePictureInPicture() {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    _pictureInPictureHandlerInstalled = true;
    AppDevice.channel.setMethodCallHandler((call) async {
      if (call.method == 'pictureInPictureChanged') {
        final arguments = call.arguments;
        final active = arguments is Map && arguments['active'] == true;
        _setPictureInPictureStatus(active: active, delayHiddenPause: !active);
      }
    });
    unawaited(_refreshPictureInPictureStatus());
  }

  Future<void> _refreshPictureInPictureStatus() async {
    if (defaultTargetPlatform != TargetPlatform.android) return;
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'pictureInPictureStatus',
      );
      if (!mounted || _closed) return;
      _setPictureInPictureStatus(
        supported: status?['supported'] == true,
        active: status?['active'] == true,
      );
    } on PlatformException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    } on MissingPluginException {
      if (mounted && !_closed) {
        _setPictureInPictureStatus(supported: false, active: false);
      }
    }
  }

  void _setPictureInPictureStatus({
    bool? supported,
    bool? active,
    bool? requested,
    bool delayHiddenPause = false,
  }) {
    final nextSupported = supported ?? _pictureInPictureSupported;
    final nextActive = active ?? _pictureInPictureActive;
    final nextRequested =
        requested ?? (nextActive ? false : _pictureInPictureRequested);
    void assign() {
      _pictureInPictureSupported = nextSupported;
      _pictureInPictureActive = nextActive;
      _pictureInPictureRequested = nextRequested;
    }

    if (mounted && !_closed) {
      setState(assign);
    } else {
      assign();
    }
    if (_pictureInPictureVisible ||
        _lifecycleState == AppLifecycleState.resumed) {
      _pictureInPictureExitTimer?.cancel();
      _applyLifecycleVisibility(pauseWhenHidden: false);
      return;
    }
    _pictureInPictureExitTimer?.cancel();
    _applyLifecycleVisibility(pauseWhenHidden: !delayHiddenPause);
    if (delayHiddenPause) {
      _pictureInPictureExitTimer = Timer(const Duration(milliseconds: 700), () {
        if (!_closed &&
            !_pictureInPictureVisible &&
            _lifecycleState != AppLifecycleState.resumed) {
          _applyLifecycleVisibility();
        }
      });
    }
  }

  void _applyLifecycleVisibility({bool pauseWhenHidden = true}) {
    final visible =
        _lifecycleState == AppLifecycleState.resumed ||
        _pictureInPictureVisible;
    _foreground = visible;
    _enhancement.setForeground(_foreground);
    _syncDanmaku();
    _syncPreload();
    _health.reset();
    if (!visible) _interactions.cancel();
    // 只有真正进后台才暂停：下拉通知栏、来电横幅只是 inactive（短暂），
    // 那会儿暂停会让用户看到"下拉一下视频就停了"而且收回来也不会续播。
    final backgrounded = _lifecycleState == AppLifecycleState.paused ||
        _lifecycleState == AppLifecycleState.hidden;
    if (pauseWhenHidden && !visible && _mobile && backgrounded) {
      if (_player.state.playing) {
        _resumeAfterBackground = true;
        _playIntent = false;
        unawaited(_player.pause());
        unawaited(_saveProgress(flush: true));
      }
    } else if (visible && _resumeAfterBackground && _error == null && !_loading) {
      // 回到前台：把被后台打断的播放接着放回去
      _resumeAfterBackground = false;
      _playIntent = true;
      unawaited(_player.play());
    }
    if (visible && _pendingError) {
      _queueRecovery();
    }
  }

  Future<void> _enterPictureInPicture() async {
    if (!_canUsePictureInPicture ||
        _closed ||
        _loading ||
        _error != null ||
        _panelOpen) {
      return;
    }
    _interactions.cancel();
    final rawRatio = _aspectRatio.isFinite && _aspectRatio > 0
        ? _aspectRatio
        : 16 / 9;
    final ratio = rawRatio.clamp(1 / 2.39, 2.39).toDouble();
    final width = ratio >= 1 ? (1000 * ratio).round() : 1000;
    final height = ratio >= 1 ? 1000 : (1000 / ratio).round();
    _setPictureInPictureStatus(requested: true);
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted || _closed) return;
    final sourceRect = _pictureInPictureSourceRect();
    final arguments = <String, int>{'width': width, 'height': height};
    if (sourceRect != null) arguments.addAll(sourceRect);
    try {
      final status = await AppDevice.channel.invokeMapMethod<String, dynamic>(
        'enterPictureInPicture',
        arguments,
      );
      if (!mounted || _closed) return;
      final supported = status?['supported'] == true;
      final active = status?['active'] == true;
      final requested = status?['requested'] == true;
      _setPictureInPictureStatus(
        supported: supported,
        active: active,
        requested: requested && !active,
      );
      if (!supported || (!active && !requested)) {
        _notice('当前设备不支持画中画');
      } else if (requested && !active) {
        _pictureInPictureExitTimer?.cancel();
        _pictureInPictureExitTimer = Timer(const Duration(seconds: 2), () {
          if (!_closed &&
              _pictureInPictureRequested &&
              !_pictureInPictureActive) {
            _setPictureInPictureStatus(requested: false);
          }
        });
      }
    } on PlatformException {
      _setPictureInPictureStatus(requested: false);
      _notice('无法进入画中画，请检查系统权限');
    } on MissingPluginException {
      _setPictureInPictureStatus(supported: false, requested: false);
      _notice('当前平台不支持画中画');
    }
  }

  Map<String, int>? _pictureInPictureSourceRect() {
    final paneContext = _videoPaneKey.currentContext;
    final renderObject = paneContext?.findRenderObject();
    if (paneContext == null ||
        renderObject is! RenderBox ||
        !renderObject.hasSize) {
      return null;
    }
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final size = renderObject.size;
    final ratio =
        MediaQuery.maybeOf(paneContext)?.devicePixelRatio ??
        View.of(paneContext).devicePixelRatio;
    final left = (topLeft.dx * ratio).round().clamp(0, 100000);
    final top = (topLeft.dy * ratio).round().clamp(0, 100000);
    final right = ((topLeft.dx + size.width) * ratio).round().clamp(0, 100000);
    final bottom = ((topLeft.dy + size.height) * ratio).round().clamp(
      0,
      100000,
    );
    if (right <= left || bottom <= top) return null;
    return {'left': left, 'top': top, 'right': right, 'bottom': bottom};
  }

  void _attachLanPlayback() {
    LanController.current?.attachPlayback(
      LanPlaybackHost(
        identity: _lanIdentity,
        title:
            widget.detail.drama.title +
            ' · 第 ' +
            widget.detail.episodes[_index].number.toString() +
            ' 集',
        stop: _stopForLan,
      ),
    );
  }

  void _acknowledgeHandoff() {
    final handoff = widget.handoff;
    if (!_handoffOwned ||
        handoff == null ||
        handoff.cancelled ||
        handoff.started.isCompleted ||
        _closed ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        _index != widget.initialIndex ||
        widget.store.profileEpoch != _profileEpoch)
      return;
    final state = _player.state;
    final position = state.position.inMilliseconds / 1000;
    final duration = state.duration.inMilliseconds / 1000;
    if (duration > 0 && handoff.position > duration + 2) {
      handoff.fail('续播位置超过接收端分集时长');
      return;
    }
    if (!state.playing ||
        state.buffering ||
        (state.width ?? 0) <= 0 ||
        position < handoff.position - .5 ||
        position > handoff.position + 20)
      return;
    _lanFirstPosition ??= position;
    if (position >= _lanFirstPosition! + .15) handoff.acknowledge(position);
  }

  Future<void> _stopForLan() async {
    final generation = _generation;
    await _serialize(() async {
      if (_closed ||
          generation != _generation ||
          widget.store.profileEpoch != _profileEpoch)
        return;
      _playIntent = false;
      _interactions.cancel();
      _enhancement.suspend();
      _health.reset();
      await _player.pause();
      await _saveProgress(flush: true);
    });
  }

  Future<void> _pushToDevice() async {
    final link = LanController.current;
    if (link == null ||
        _panelOpen ||
        _closed ||
        _loading ||
        _error != null ||
        widget.mediaId != null)
      return;
    final generation = _generation;
    final index = _index;
    bool current() =>
        mounted &&
        !_closed &&
        generation == _generation &&
        index == _index &&
        widget.store.profileEpoch == _profileEpoch;
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showLanPush(
        context,
        link,
        snapshot: () => LanPlaybackIntent(
          drama: widget.detail.drama,
          episodeID: widget.detail.episodes[index].id,
          episode: widget.detail.episodes[index].number,
          position: _currentPosition,
        ),
        stillCurrent: current,
        onAccepted: () async {
          if (!current()) throw StateError('本机播放内容已变更');
          await _stopForLan();
          if (!current()) throw StateError('本机播放内容已变更');
        },
      );
    } catch (error) {
      if (mounted && !_closed) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(error.toString())));
      }
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
  }

  void _syncPreload() {
    if (_closed) return;
    if (!_preloadEnabled ||
        !_foreground ||
        widget.localOnly ||
        _plan?.local == true ||
        _loading ||
        _error != null ||
        _openedIndex != _index ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.store.locked ||
        _index + 1 >= widget.detail.episodes.length) {
      _preloader.clear();
      return;
    }
    final state = _player.state;
    if (!state.playing || state.buffering || !_playIntent) {
      _preloader.pause();
      return;
    }
    final duration = state.duration.inMilliseconds;
    final position = state.position.inMilliseconds;
    // 开播 2 秒、缓冲领先 3 秒就预载下一集：预载只是解析地址+预取首段，
    // 不必等本集播过半。短剧一集一两分钟，等播过半常等于没预载；
    // 2 分钟凭证过期由 preloader 自行重签。
    if (duration <= 0 ||
        position < 2000 ||
        state.buffer.inMilliseconds - position < 3000) {
      return;
    }
    _preloader.prepare(
      widget.detail.drama,
      widget.detail.episodes[_index + 1],
      quality: _requestedQuality,
    );
  }

  /// 一集播完自动接下一集：等待秒数为 0 时立即连播（无提示 UI），
  /// 正数时倒计时等待，点提示或任何操作都能取消。
  void _startAdvanceCountdown() {
    _advanceTimer?.cancel();
    if (!mounted || _closed) return;
    if (advanceCountdownSeconds <= 0) {
      unawaited(_play(_index + 1, showControlsOnReady: false));
      return;
    }
    setState(() => _advanceSeconds = advanceCountdownSeconds);
    _advanceTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (_closed || !mounted) {
        timer.cancel();
        return;
      }
      if (_advanceSeconds <= 1) {
        timer.cancel();
        _advanceTimer = null;
        setState(() => _advanceSeconds = 0);
        unawaited(_play(_index + 1, showControlsOnReady: false));
      } else {
        setState(() => _advanceSeconds -= 1);
      }
    });
  }

  void _cancelAdvanceCountdown() {
    if (_advanceTimer == null && _advanceSeconds == 0) return;
    _advanceTimer?.cancel();
    _advanceTimer = null;
    if (mounted && !_closed) setState(() => _advanceSeconds = 0);
  }

  /// 手势变化：滑动调完亮度/音量后落盘记忆（遮罩亮度/HUD 的刷新由
  /// build 里的 ListenableBuilder 局部监听承担，不再整屏 setState——
  /// 手势拖动时这个回调每帧触发，整屏重建是播放页最大的卡顿源）
  void _onInteractionChanged() {
    final brightness = _interactions.brightness;
    final volume = _interactions.volume;
    if (_savedBrightness == brightness && _savedVolume == volume) return;
    _savedBrightness = brightness;
    _savedVolume = volume;
    _mediaMemoryTimer?.cancel();
    _mediaMemoryTimer = Timer(const Duration(milliseconds: 600), () {
      if (_closed) return;
      unawaited(_persistMediaMemory());
    });
  }

  /// 把亮度/音量写入播放偏好（照抄 _setPreferences 的用户切换校验）
  Future<void> _persistMediaMemory() async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) return;
    try {
      await widget.store.setPlaybackPreferences(
        PlaybackPreferences(
          speed: _speed,
          quality: _requestedQuality,
          autoAdvance: _autoAdvance,
          danmaku: _danmakuEnabled,
          preload: _preloadEnabled,
          brightness: _savedBrightness,
          volume: _savedVolume,
          enhancement: _enhancement.preferences,
        ),
      );
    } catch (_) {
      // 记忆失败不影响播放，下一次手势变化会再试
    }
  }

  void _syncDanmaku({bool discontinuity = false}) {
    if (_closed) return;
    final state = _player.state;
    _danmaku.update(
      position: state.position,
      duration: state.duration,
      speed: state.rate,
      playing: state.playing && _playIntent && !state.completed,
      buffering: state.buffering,
      foreground: _foreground,
      available:
          !_loading &&
          _error == null &&
          _openedIndex == _index &&
          widget.store.profileEpoch == _profileEpoch &&
          !widget.store.locked &&
          widget.store.allowsSource('hongguo'),
      discontinuity: discontinuity,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final television = AppLayout.isTelevision(context);
    if (_television != television) {
      _fullscreen = false;
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _television = television;
    _orientationController = AppOrientationScope.maybeOf(context);
    // 短剧：进入即竖屏全屏直接播（手机端），锁竖屏。
    if (_portraitDrama && !_portraitFullscreenApplied && !_fullscreen) {
      _portraitFullscreenApplied = true;
      _fullscreen = true;
      unawaited(_syncPlaybackOrientation(fullscreen: true));
    }
    final orientation = MediaQuery.orientationOf(context);
    if (_lastOrientation != null && _lastOrientation != orientation) {
      _automaticFullscreenSuppressed = false;
      _interactions.cancel();
    }
    _lastOrientation = orientation;
    _scheduleSystemUi();
  }

  void _scheduleSystemUi() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _closed || (!_mobile && !_television)) return;
      final fullscreen = _showFullscreen;
      if (_systemFullscreen == fullscreen) return;
      _systemFullscreen = fullscreen;
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          fullscreen ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
        ),
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleState = state;
    _applyLifecycleVisibility();
    // 系统会冻结后台定时器，回前台补读一次电量（否则状态区电量停在旧值）。
    if (state == AppLifecycleState.resumed) _battery.resumed();
  }

  void _queueRecovery() {
    if (_closed || !_acceptErrors || _error != null) {
      return;
    }
    _pendingError = true;
    if (!_foreground || (_errorTimer?.isActive ?? false)) {
      return;
    }
    final ticket = _generation;
    final position = _player.state.position;
    _errorTimer = Timer(const Duration(milliseconds: 900), () {
      if (_closed || ticket != _generation || !_foreground || !_acceptErrors) {
        return;
      }
      _pendingError = false;
      final state = _player.state;
      if (state.playing &&
          !state.buffering &&
          (state.width ?? 0) > 0 &&
          state.position > position + const Duration(milliseconds: 300)) {
        return;
      }
      unawaited(_recover());
    });
  }

  Future<void> _recover() async {
    final current = _plan;
    if (_closed ||
        !_acceptErrors ||
        !_foreground ||
        current == null ||
        _error != null) {
      return;
    }
    _acceptErrors = false;
    _danmaku.setPlan(null);
    _errorTimer?.cancel();
    _pendingError = false;
    final position = _currentPosition;
    final action = current.local
        ? PlaybackRecoveryAction.stop
        : _recovery.next(current);
    if (action == PlaybackRecoveryAction.reuse) {
      await _reusePlayback(position);
      return;
    }
    if (action == PlaybackRecoveryAction.stop) {
      _resumePosition = position;
      final ticket = _generation;
      try {
        await _serialize(() async {
          if (_closed || ticket != _generation) {
            return;
          }
          try {
            await _saveProgress();
            _openedIndex = -1;
            await _player.stop();
          } finally {
            await widget.repository.release(current.session);
          }
        });
      } catch (_) {}
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _swapping = false;
          _localFailure = current.local;
          _error = current.local
              ? widget.allowOnlineFallback
                    ? '本地视频读取失败，请重试或重新下载；也可以手动改为在线播放。'
                    : '本地成品读取失败，请重试或重新生成。'
              : '自动恢复未成功，请检查网络后重试，也可换一集或选择其他清晰度。';
        });
      }
      return;
    }
    await _play(_index, position: position, recoveryAction: action);
  }

  /// 原地重开：沿用同一播放地址与流会话，只把播放器重新打开。
  ///
  /// 源站首字节抖动（红果实测 0.3~16 秒）造成的卡顿，重开后多半自愈；
  /// 这一步零网络、零解析开销，比「换线路 / 重新解析」快一个数量级。
  /// 重开失败时回到常规恢复链继续兜底。
  Future<void> _reusePlayback(double position) async {
    final plan = _plan;
    if (_closed || plan == null || plan.url.isEmpty) {
      return;
    }
    final ticket = _generation;
    _acceptErrors = false;
    _danmaku.setPlan(null);
    await _serialize(() async {
      if (_closed || ticket != _generation) {
        return;
      }
      try {
        await _player.stop();
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
      } catch (_) {
        if (!_closed && mounted && ticket == _generation) {
          _acceptErrors = true;
          _queueRecovery();
        }
        return;
      }
      if (_closed || ticket != _generation) {
        return;
      }
      _health.reset();
      if (mounted && !_closed && ticket == _generation) {
        setState(() {
          _loading = false;
          _swapping = false;
        });
        _acceptErrors = true;
        _danmaku.setPlan(plan);
        _syncDanmaku();
      }
    });
  }

  void _togglePlayback() {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已操作播放');
    _interactions.cancel();
    _playIntent = !_player.state.playing;
    if (_playIntent) _enhancement.mediaReady();
    _health.reset();
    if (_playIntent && _player.state.completed) {
      unawaited(_play(_index));
      return;
    }
    unawaited(_player.playOrPause());
    if (!_playIntent) unawaited(_saveProgress(flush: true));
    _syncDanmaku();
  }

  Future<void> _saveProgress({bool flush = false}) async {
    if (_openedIndex < 0 || widget.store.profileEpoch != _profileEpoch) {
      return;
    }
    final position = _player.state.position.inMilliseconds / 1000;
    final duration = _player.state.duration.inMilliseconds / 1000;
    if (position < .1) {
      return;
    }
    final store = widget.store;
    final progressKey =
        '${widget.mediaId ?? widget.detail.drama.id}:$_openedIndex:$position:$duration';
    // flush 时必须至少通知一次（周期保存是静默的），哪怕进度键没变。
    final needsNotify = flush && !_watchNotified && widget.mediaId == null;
    if (_savedProgressKey == progressKey && _saveWarning == null && !needsNotify) {
      if (flush && widget.mediaId == null) LanController.current?.flush();
      return;
    }
    final entry = WatchEntry(
      drama: widget.repository.catalogUpdates.current(widget.detail.drama),
      episode: widget.detail.episodes[_openedIndex].number,
      position: position,
      duration: duration,
      updatedAt: DateTime.now(),
    );
    try {
      await Future<void>.value();
      if (store.profileEpoch != _profileEpoch) return;
      if (widget.mediaId == null) {
        await store.saveWatch(entry, notify: needsNotify);
        if (needsNotify) _watchNotified = true;
        if (flush) LanController.current?.flush();
      } else {
        await store.saveMediaWatch(widget.mediaId!, entry);
      }
      _savedProgressKey = progressKey;
      if (mounted && !_closed && _saveWarning != null) {
        setState(() => _saveWarning = null);
      }
    } catch (_) {
      if (mounted && !_closed && _saveWarning == null) {
        setState(() => _saveWarning = '观看进度尚未保存，请检查存储空间后重试。');
      }
    }
  }

  Future<void> _serialize(Future<void> Function() operation) {
    final next = _operations.catchError((Object _) {}).then((_) => operation());
    _operations = next;
    return next;
  }

  Future<void> _play(
    int index, {
    double position = 0,
    PlaybackRecoveryAction? recoveryAction,
    bool playWhenReady = true,
    PlaybackPlan? handoffPlan,
    bool showControlsOnReady = true,
    int? route,
  }) async {
    if (_closed ||
        widget.store.profileEpoch != _profileEpoch ||
        index < 0 ||
        index >= widget.detail.episodes.length) {
      return;
    }
    _interactions.cancel();
    if (widget.handoff != null &&
        handoffPlan == null &&
        recoveryAction == null) {
      _handoffOwned = false;
      widget.handoff?.fail('接收端已更换播放内容');
    }
    if (index != _index) _forceOnline = false;
    final warmed =
        handoffPlan ??
        (recoveryAction == null && _preloadEnabled && !widget.localOnly
            ? _preloader.take(
                widget.detail.drama,
                widget.detail.episodes[index],
                quality: _requestedQuality,
                online: _forceOnline,
              )
            : null);
    _preloader.clear();
    final ticket = ++_generation;
    _seekSequence++;
    _danmaku.setPlan(null);
    _acceptErrors = false;
    _pendingError = false;
    _errorTimer?.cancel();
    _health.reset();
    if (recoveryAction == null) {
      _recovery.reset();
      _playIntent = playWhenReady;
    }
    _resumePosition = position;
    // 换一集重来：片头/片尾各允许生效一次。
    _introSkipped = false;
    _outroSkipped = false;
    // 重开后首个位置事件（open 的 resume 初始位置）只做节流基线：
    // 上次停留处落在片头/片尾区间内不应被自动拽走，跳片只对后续
    // 播放推进生效。重置必须发生在 open 之前——media.start 事件在
    // open 内同步入队，早于 open 返回后的任何代码。
    _positionPrimed = false;
    _showControlsOnPlaybackReady = showControlsOnReady;
    setState(() {
      _index = index;
      _loading = true;
      _swapping = false;
      _error = null;
      _localFailure = false;
      _loadingMessage = switch (recoveryAction) {
        PlaybackRecoveryAction.reuse => '正在重新连接播放',
        PlaybackRecoveryAction.alternative => '正在切换备用线路',
        PlaybackRecoveryAction.refresh => '正在重新获取播放地址',
        PlaybackRecoveryAction.route => '正在切换播放线路',
        _ => '正在准备第 ${widget.detail.episodes[index].number} 集',
      };
    });
    LanController.current?.detachPlayback(_lanIdentity);
    _lanIdentity = Object();
    _attachLanPlayback();
    PlaybackPlan? prepared;
    PlaybackPlan? retained;
    bool installed = false;
    try {
      // 阶段一：只定格不停播。暂停让旧集画面停在最后一帧，
      // 趁画面还在时先存进度，然后才去解析新集地址——
      // 解析（网络）期间屏幕有内容，不再整段黑屏干等。
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          return;
        }
        await _saveProgress(flush: true);
        if (_closed || ticket != _generation) return;
        try {
          await _player.pause();
        } catch (_) {}
      });
      if (_closed || ticket != _generation) {
        return;
      }
      // 选线：保留当前播放会话，按索引切到指定线路（真果·鉴多线路表）。
      final active = _plan;
      if (route != null && active != null) {
        prepared = await _loader.selectRoute(active, route);
      } else if (recoveryAction == PlaybackRecoveryAction.alternative &&
          active != null) {
        // 换备用线路走会话内切换（Go nativeNextPlayback）：零网络、零解析，
        // 还能保住原线路表与已选画质档。会话已失效（如长时间挂后台被回收）
        // 才退回完整重解析，等价旧行为。
        try {
          prepared = await _loader.fallback(active);
        } catch (_) {
          prepared = null;
        }
        if (prepared == null && !_closed && ticket == _generation) {
          prepared = await _loader.load(
            widget.detail.drama,
            widget.detail.episodes[index],
            quality: _requestedQuality,
            localOnly: widget.localOnly,
            online: _forceOnline,
          );
        }
      } else if (warmed != null) {
        prepared = await _loader.use(warmed);
      } else {
        prepared = await _loader.load(
          widget.detail.drama,
          widget.detail.episodes[index],
          quality: _requestedQuality,
          localOnly: widget.localOnly,
          online: _forceOnline,
        );
      }
      if (prepared == null) {
        return;
      }
      final plan = prepared;
      await _serialize(() async {
        if (_closed || ticket != _generation) {
          await widget.repository.release(plan.session);
          return;
        }
        if (plan.url.isEmpty) {
          throw AppFailure('站源未返回播放地址，请重试');
        }
        // 阶段二：新地址已到手才真正动播放器。挂起画质增强要先于
        // stop——此刻画面即将被替换，不再需要维持旧帧的滤镜。
        _enhancement.suspend();
        await _enhancement.beforeMedia();
        if (mounted && !_closed && ticket == _generation) {
          setState(() => _swapping = true);
        }
        _openedIndex = -1;
        await _player.stop();
        final previous = _plan;
        _plan = null;
        if (recoveryAction == PlaybackRecoveryAction.alternative &&
            route == null) {
          retained = previous;
        } else if (previous != null) {
          // 选线/普通重解析：新会话已接管，旧会话立即释放，避免 8 槽泄漏。
          await widget.repository.release(previous.session);
        }
        final platform = _player.platform;
        if (platform is NativePlayer) {
          await platform.setProperty(
            'demuxer-lavf-o',
            [
              // 分片失败多给两次重试：红果网页直链会随机 404/502，
              // 少一次重试就可能把一次抖动放大成一次播放失败。
              'seg_max_retry=5',
              'strict=experimental',
              'allowed_extensions=ALL',
              plan.local
                  ? 'protocol_whitelist=[file,crypto,data]'
                  : 'protocol_whitelist=[http,https,tcp,tls,crypto,data,file]',
              if (plan.decryptionKey.isNotEmpty)
                'decryption_key=${plan.decryptionKey}',
            ].join(','),
          );
          // 网络超时放宽到 30 秒：源站首字节实测可等 16 秒，
          // 20 秒会在正常慢响应上被误判为失败。
          await platform.setProperty('network-timeout', '30');
        }
        _plan = plan;
        installed = true;
        _acceptErrors = true;
        await _player.open(
          Media(
            plan.url,
            httpHeaders: plan.headers,
            start: position > 0
                ? Duration(milliseconds: (position * 1000).round())
                : null,
          ),
          play: _foreground && _playIntent,
        );
        if (_closed || ticket != _generation) {
          return;
        }
        _openedIndex = index;
        _watchNotified = false;
        _lastAppliedPositionMs = -1;
        _enhancement.mediaReady();
        _attachLanPlayback();
        _health.reset();
        await _interactions.applySpeed();
        // 换源后播放器音量会回到默认值，按记忆恢复用户手感
        unawaited(_player.setVolume(_interactions.volume));
        if (mounted && !_closed && ticket == _generation) {
          setState(() {
            _loading = false;
            _swapping = false;
          });
          _danmaku.setPlan(plan);
          _syncDanmaku();
          _acknowledgeHandoff();
          _menuRevision.value++;
        }
      });
    } catch (error) {
      if (!_closed && mounted && ticket == _generation) {
        if (prepared != null && identical(_plan, prepared)) {
          _acceptErrors = true;
          _queueRecovery();
        } else {
          if (prepared != null) {
            await widget.repository.release(prepared.session);
          }
          if (mounted && !_closed && ticket == _generation) {
            setState(() {
              _loading = false;
              _swapping = false;
              _localFailure =
                  (error is AppFailure && error.code == 'local_media') ||
                  (widget.localOnly && !_forceOnline);
              _error = error is AppFailure ? error.message : '无法播放这一集，请重试或换一集。';
              widget.handoff?.fail(_error!);
            });
          }
        }
      } else if (prepared != null && !installed) {
        await widget.repository.release(prepared.session);
      }
    } finally {
      if (warmed != null && !installed) {
        await widget.repository.release(warmed.session);
      }
      if (retained != null) {
        await widget.repository.release(retained!.session);
      }
    }
  }

  Future<void> _switchOnline() async {
    _forceOnline = true;
    await _retry();
  }

  Future<void> _retry({int? quality}) async {
    final position = _currentPosition;
    if (quality != null) {
      _requestedQuality = quality;
    }
    await _play(
      _index,
      position: position,
      playWhenReady: quality == null || _error != null || _player.state.playing,
    );
  }

  Future<void> _switchRoute() async {
    final plan = _plan;
    if (plan == null || plan.routeCount < 2) return;
    // 循环切到下一条：原先用 hasAlternative 早退（它的语义是「当前不是最后
    // 一条」），切到最后一条后电视端就再也换不了线；且传的是
    // alternative（失败恢复语义）而非用户主动切线，改走 _selectRoute 的
    // route 语义（按索引切，两阶段定格不断画面）。
    final next = (plan.routeIndex + 1) % plan.routeCount;
    await _selectRoute(next);
  }

  /// 按索引切换到指定线路（保留当前会话与进度，两阶段定格不断画面）。
  Future<void> _selectRoute(int index) async {
    final plan = _plan;
    if (plan == null || index < 0 || index >= plan.routeCount) return;
    if (index == plan.routeIndex) return;
    final position = _currentPosition;
    await _play(
      _index,
      position: position,
      recoveryAction: PlaybackRecoveryAction.route,
      playWhenReady: true,
      route: index,
    );
  }

  /// 线路面板：官方源平铺 + 第三方源折叠成一条入口，点选即切。
  /// 真果·鉴一集常带 20~30 条三方线，全平铺会把 1~5 条官方线淹没在长列表里。
  Future<void> _showRouteMenu() async {
    final plan = _plan;
    if (plan == null || plan.routeCount < 2 || !mounted) return;
    final labels = plan.routeLabels;
    String labelOf(int index) {
      final label = (index >= 0 && index < labels.length)
          ? labels[index].trim()
          : '';
      return label.isNotEmpty ? label : '线路 ${index + 1}';
    }
    final official = plan.officialRoutes;
    final thirdParty = plan.thirdPartyRoutes;
    final picked = await showPlayerSidePanel<int>(
      context: context,
      title: official.isEmpty
          ? '播放源 · ${plan.routeCount} 条'
          : '播放源 · ${official.length} 条官方',
      builder: (panelContext) => SideRouteList(
        labels: [for (var index = 0; index < plan.routeCount; index++) labelOf(index)],
        current: plan.routeIndex,
        official: official,
        thirdParty: thirdParty,
        onSelected: (index) => Navigator.pop(panelContext, index),
      ),
    );
    if (picked == null || !mounted) return;
    // 关面板动画约 180ms：等它收干净再切线，否则面板还压在新一帧上。
    await Future<void>.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    await _selectRoute(picked);
  }

  String? get _routeLabel {
    final plan = _plan;
    if (plan == null || plan.routeCount < 2) return null;
    final index = plan.routeIndex;
    final label = (index >= 0 && index < plan.routeLabels.length)
        ? plan.routeLabels[index].trim()
        : '';
    // 有真名显示真名（如「无水印资源」），否则回退计数。
    return label.isNotEmpty ? label : '线路 ${index + 1}/${plan.routeCount}';
  }

  /// 全屏/旋转能力：电视端、手机（全部站源）与桌面端都支持；
  /// 手机旋转自动全屏、桌面端走 windowManager.setFullScreen。
  bool get _fullscreenSupported => _television || _mobile || Platform.isWindows;

  bool get _showFullscreen =>
      _fullscreenSupported &&
      (_television ||
          _fullscreen ||
          (_mobile &&
              !_automaticFullscreenSuppressed &&
              _aspectRatio >= 1 &&
              MediaQuery.orientationOf(context) == Orientation.landscape));

  /// 当前视图状态：全屏时再按实际朝向分竖屏/横屏两种版式。
  PlaybackViewMode get _viewMode {
    if (!_showFullscreen) return PlaybackViewMode.inline;
    final landscape =
        _forceLandscape ||
        (!_forcePortrait &&
            MediaQuery.orientationOf(context) == Orientation.landscape);
    return landscape
        ? PlaybackViewMode.landscapeFullscreen
        : PlaybackViewMode.portraitFullscreen;
  }

  bool get _landscapeChrome =>
      _viewMode == PlaybackViewMode.landscapeFullscreen;

  /// 按当前全屏态与旋转态同步锁向（Windows 全屏窗口 / 手机锁竖横屏）。
  /// Windows 分支排除 _mobile：测试宿主可能 override android，
  /// 此时走 SystemChrome 路径而不是 windowManager 插件。
  Future<void> _syncPlaybackOrientation({required bool fullscreen}) async {
    if (Platform.isWindows && !_mobile) {
      await windowManager.setFullScreen(fullscreen);
    } else if (_mobile) {
      await (_orientationController?.setPlayback(
            this,
            fullscreen: fullscreen,
            aspectRatio: _aspectRatio,
            forceLandscape: _forceLandscape,
            forcePortrait: _forcePortrait,
          ) ??
          SystemChrome.setPreferredOrientations(
            AppOrientationController.orientations(
              television: _television,
              fullscreen: fullscreen,
              aspectRatio: _aspectRatio,
              forceLandscape: _forceLandscape,
              forcePortrait: _forcePortrait,
            ),
          ));
    }
  }

  /// 统一切换视图状态：竖屏全屏 / 横屏全屏 / 退回内嵌。
  /// 失败时整体回滚，避免「方向没切过去但 UI 已经当全屏了」。
  Future<void> _setViewMode(PlaybackViewMode mode) async {
    if (_rotating || !_fullscreenSupported) return;
    if (mode == _viewMode) return;
    _interactions.cancel();
    _rotating = true;
    final prevFullscreen = _fullscreen;
    final prevLandscape = _forceLandscape;
    final prevPortrait = _forcePortrait;
    final prevSuppressed = _automaticFullscreenSuppressed;
    final fullscreen = mode != PlaybackViewMode.inline;
    setState(() {
      _fullscreen = fullscreen;
      _forceLandscape = mode == PlaybackViewMode.landscapeFullscreen;
      _forcePortrait = mode == PlaybackViewMode.portraitFullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
      // 换形态时收起底部选集面板（面板属于竖屏沉浸态）。
      _episodeSheetOpen = false;
    });
    try {
      await _syncPlaybackOrientation(fullscreen: fullscreen);
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = prevFullscreen;
          _forceLandscape = prevLandscape;
          _forcePortrait = prevPortrait;
          _automaticFullscreenSuppressed = prevSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  /// 竖屏全屏时选集是否走「底部滑入、推挤视频」：手机竖屏沉浸态才用；
  /// 横屏宽度够，继续用右侧浮层覆盖。
  bool get _episodeSheetEligible =>
      _mobile &&
      !_television &&
      _viewMode == PlaybackViewMode.portraitFullscreen;

  void _openEpisodeSheet() {
    if (_episodeSheetOpen) return;
    setState(() => _episodeSheetOpen = true);
  }

  void _closeEpisodeSheet() {
    if (!_episodeSheetOpen) return;
    setState(() => _episodeSheetOpen = false);
  }

  /// 竖屏全屏的选集：底部滑入并把视频顶成顶部小窗（红果同款），
  /// 不是浮层盖在画面上；收起后视频复原铺满。
  Widget _portraitEpisodePushLayout(BuildContext context) {
    return _PortraitEpisodePushLayout(
      open: _episodeSheetOpen,
      video: _videoPane(context, hideControls: _episodeSheetOpen),
      panel: _episodeSheetPanel(context),
    );
  }

  /// 选集面板内容：标题栏（可收起）+ 选集格子。
  Widget _episodeSheetPanel(BuildContext context) {
    // 选集一律浅色白卡（与详情页、右侧滑出面板一致）：暗底暗边的格子在
    // 深色面板上几乎看不清，浅底深字最省眼。
    final onSurface = AppTheme.light.colorScheme.onSurface;
    return Theme(
      data: AppTheme.light,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppTheme.light.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: .28),
              blurRadius: 18,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '选集',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: onSurface,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const ValueKey('player-episode-sheet-close'),
                      tooltip: '收起选集',
                      onPressed: _closeEpisodeSheet,
                      icon: AppIcon(AppIcons.expandLess, color: onSurface),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: PlayerEpisodeGrid(
                  episodes: widget.detail.episodes,
                  currentIndex: _index,
                  keyPrefix: 'sheet-episode',
                  dense: true,
                  // 标题交给上面的标题栏，避免面板里出现两个「选集」。
                  title: '',
                  onSelected: (index) {
                    _closeEpisodeSheet();
                    if (index != _index) unawaited(_play(index));
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 横屏锁屏：锁定期间把屏幕朝向钉在当前方向，旋转设备画面不再跟随；
  /// 解锁时恢复跟随。锁钮本身在 PlayerControls 内部，点它时回调这里。
  Future<void> _setScreenLocked(bool locked) async {
    if (_screenLocked == locked) return;
    _screenLocked = locked;
    final controller = _orientationController;
    if (controller == null) return;
    if (!locked) {
      await controller.lockOrientations(null);
      return;
    }
    await controller.lockOrientations(_lockedOrientationsForNow());
  }

  /// 锁屏期间允许的方向：只锁「轴」——横屏锁横、竖屏锁竖。
  /// 不区分左右翻面（翻面无妨），但横↔竖的轴向切换会被拦住，
  /// 这才是锁屏要拦的误转。
  List<DeviceOrientation> _lockedOrientationsForNow() {
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    return landscape
        ? const [
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]
        : const [
            DeviceOrientation.portraitUp,
            DeviceOrientation.portraitDown,
          ];
  }

  Future<void> _rotate() async {
    if (_rotating || !_fullscreenSupported) {
      return;
    }
    final fullscreen = !_showFullscreen;
    final previous = _fullscreen;
    final previousSuppressed = _automaticFullscreenSuppressed;
    _interactions.cancel();
    _rotating = true;
    setState(() {
      _fullscreen = fullscreen;
      _automaticFullscreenSuppressed = !fullscreen;
    });
    try {
      await _syncPlaybackOrientation(fullscreen: fullscreen);
    } catch (_) {
      if (mounted && !_closed) {
        setState(() {
          _fullscreen = previous;
          _automaticFullscreenSuppressed = previousSuppressed;
        });
        _notice('无法切换全屏，请重试');
      }
    } finally {
      _rotating = false;
      if (mounted && !_closed) _scheduleSystemUi();
    }
  }

  void _notice(String message) {
    if (!mounted || _closed) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _setPreferences(PlaybackPreferences preferences) async {
    if (_closed || widget.store.profileEpoch != _profileEpoch) {
      throw StateError('当前用户已变更');
    }
    _interactions.cancel();
    final nextPreferences = preferences.copyWith(
      autoAdvance: true,
      preload: true,
    );
    await widget.store.setPlaybackPreferences(nextPreferences);
    if (!mounted || _closed || widget.store.profileEpoch != _profileEpoch)
      return;
    final qualityChanged = nextPreferences.quality != _requestedQuality;
    _enhancement.setPreferences(nextPreferences.enhancement);
    setState(() {
      _speed = nextPreferences.speed;
      _requestedQuality = nextPreferences.quality;
      _autoAdvance = true;
      _danmakuEnabled = nextPreferences.danmaku;
      _preloadEnabled = true;
    });
    _danmaku.setEnabled(_danmakuEnabled);
    _syncDanmaku();
    if (qualityChanged) _preloader.clear();
    _syncPreload();
    _menuRevision.value++;
    await _interactions.applySpeed();
    if (qualityChanged && _plan?.local != true) {
      await _retry(quality: nextPreferences.quality);
    }
  }

  Future<void> _toggleFavorite() async {
    try {
      await widget.store.toggleFavorite(widget.detail.drama);
      if (mounted && !_closed) setState(() {});
    } catch (_) {
      _notice('追剧记录未能保存，请检查存储空间后重试');
    }
  }

  Future<void> _toggleDanmaku() async {
    if (widget.detail.drama.source != 'hongguo') return;
    final next = !_danmakuEnabled;
    try {
      await _setPreferences(_preferences.copyWith(danmaku: next));
      if (!mounted || _closed) return;
      // 开了却拿不到弹幕身份时立刻说清楚，别让用户对着空画面等
      if (next && !_danmaku.supported) {
        _notice(_plan?.local == true ? '本地播放不加载弹幕' : '本集暂不支持弹幕');
      }
    } catch (_) {
      _notice('弹幕偏好未能保存，请重试');
    }
  }

  Future<void> _retryDanmakuFromControls() async {
    try {
      _danmaku.retry();
      _menuRevision.value++;
    } catch (_) {
      _notice('弹幕重试失败，请稍后再试');
    }
  }

  Future<void> _submitDownloadSelection(DownloadSelection selection) async {
    if (!widget.repository.supportsDownloads ||
        !widget.store.canDownload ||
        widget.store.profileEpoch != _profileEpoch ||
        widget.mediaId != null) {
      return;
    }
    final added = await widget.repository.enqueueDownloads(
      widget.detail,
      selection.episodes,
      quality: selection.quality,
    );
    if (!mounted || _closed) return;
    if (added > 0) DownloadSummary.instance.poke();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(added == 0 ? '所选集数已在下载列表中' : '已加入 $added 集，已有任务自动跳过'),
        action: SnackBarAction(
          label: '查看',
          onPressed: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => DownloadsScreen(
                  repository: widget.repository,
                  store: widget.store,
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Future<void> _openPanel(PlayerMenuSection section) async {
    if (_panelOpen || _closed) return;
    // 竖屏全屏的选集不走右侧浮层：改成底部滑入、把视频顶成顶部小窗
    // （红果同款），不再盖住画面。
    if (section == PlayerMenuSection.episodes && _episodeSheetEligible) {
      _openEpisodeSheet();
      return;
    }
    _cancelAdvanceCountdown();
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      // 选集/倍速/清晰度走右侧滑出面板（清晰度面板内一并收增强画质设置）；
      // 电视端所有面板仍走原来的居中弹窗（遥控焦点导航在该版式上可靠）。
      final sidePanel =
          !_television &&
          (section == PlayerMenuSection.episodes ||
              section == PlayerMenuSection.speed ||
              section == PlayerMenuSection.quality);
      if (sidePanel) {
        await _openSidePanel(section);
      } else {
        await _openWidePanel(section);
      }
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  /// 手机/桌面：二级功能一律从右侧滑出，不再开居中玻璃弹窗。
  Future<void> _openSidePanel(PlayerMenuSection section) async {
    switch (section) {
      case PlayerMenuSection.episodes:
        final picked = await showPlayerSidePanel<int>(
          context: context,
          title: '选集 · 共 ${widget.detail.episodes.length} 集',
          builder: (panelContext) => PlayerEpisodeGrid(
            episodes: widget.detail.episodes,
            currentIndex: _index,
            keyPrefix: 'menu-episode',
            // 面板只有 320dp 宽，标准 3 列格子又宽又高；这里换小格子密度档。
            dense: true,
            onSelected: (index) => Navigator.pop(panelContext, index),
          ),
        );
        if (picked != null && mounted && !_closed && picked != _index) {
          await _play(picked);
        }
      case PlayerMenuSection.speed:
        final picked = await showPlayerSidePanel<double>(
          context: context,
          title: '播放倍速',
          builder: (panelContext) => SideChoiceGrid(
            keyPrefix: 'side-speed',
            selected: _speed,
            choices: [
              for (final speed in playbackSpeeds)
                SideChoice(speed, '${speed}x'),
            ],
            onSelect: (choice) =>
                Navigator.pop(panelContext, choice.key as double),
          ),
        );
        if (picked != null && mounted && !_closed && picked != _speed) {
          await _setPreferences(_preferences.copyWith(speed: picked));
        }
      case PlayerMenuSection.quality:
        final qualities = (_plan?.qualities ?? const <int>[])
            .where((quality) => quality > 0)
            .toList();
        if (qualities.isEmpty) {
          _notice('本集没有可切换的画质');
          return;
        }
        final picked = await showPlayerSidePanel<int>(
          context: context,
          title: '清晰度',
          builder: (panelContext) {
            // _enhancementForUi 是 getter，无法在 spread 内被提升为非空类型，
            // 先存成局部变量再判空。
            final enhancementUi = _enhancementForUi;
            return ListView(
              padding: EdgeInsets.zero,
              children: [
                SideChoiceList(
                  keyPrefix: 'side-quality',
                  selected: _requestedQuality > 0
                      ? _requestedQuality
                      : _plan?.quality,
                  choices: [
                    for (final quality in qualities)
                      SideChoice(quality, '${quality}P'),
                  ],
                  onSelect: (choice) =>
                      Navigator.pop(panelContext, choice.key as int),
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                ),
                // 增强画质设置原来只在手机端「清晰度」玻璃弹窗里露面，改侧栏后
                // 必须一并收进来，否则手机端会失去增强设置入口（TV 端仍走玻璃弹窗）。
                if (enhancementUi != null) ...[
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: .08),
                  ),
                  VideoEnhancementSettings(
                    controller: enhancementUi,
                    onChanged: (enhancement) => _setPreferences(
                      _preferences.copyWith(enhancement: enhancement),
                    ),
                    onCompare: () => unawaited(_enhancement.toggleCompare()),
                  ),
                ],
              ],
            );
          },
        );
        if (picked != null &&
            mounted &&
            !_closed &&
            picked != _requestedQuality) {
          await _setPreferences(_preferences.copyWith(quality: picked));
        }
      case PlayerMenuSection.settings:
        // 播放设置面板只在电视端出现（遥控器需要一屏全览），手机端设置项
        // 分别在倍速/清晰度面板里。
        break;
    }
  }

  /// 电视端与宽屏兜底：保留原来的居中弹窗（遥控焦点导航在这个版式上可靠）。
  Future<void> _openWidePanel(PlayerMenuSection section) async {
    final menuTheme = _showFullscreen ? AppTheme.dark : Theme.of(context);
    final index = await showDialog<int>(
      context: context,
      builder: (menuContext) => AnimatedBuilder(
        animation: Listenable.merge([
          _menuRevision,
          widget.store,
          _danmaku,
          _preloader,
        ]),
        builder: (_, _) => Theme(
          data: menuTheme,
          child: PlayerMenu(
            section: section,
            episodes: widget.detail.episodes,
            currentIndex: _index,
            preferences: _preferences,
            qualities: _plan?.qualities ?? [],
            actualQuality: _plan?.quality ?? 0,
            local: _plan?.local == true,
            favorite: widget.store.isFavorite(widget.detail.drama.id),
            mobile: _mobile,
            onEpisode: (index) => Navigator.pop(menuContext, index),
            onPreferences: _setPreferences,
            showDanmaku: _plan?.danmakuId.isNotEmpty == true,
            danmakuStatus: _danmaku.status,
            onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
            preloadStatus: _preloader.status,
            enhancement: _enhancementForUi,
            onCompareEnhancement: () {
              unawaited(_enhancement.toggleCompare());
              Navigator.pop(menuContext);
            },
            onFavorite: () => widget.store.toggleFavorite(widget.detail.drama),
          ),
        ),
      ),
    );
    if (mounted && !_closed && index != null && index != _index) {
      await _play(index);
    }
  }

  /// 播到片头/片尾标记点时自动跳过（判定规则在 [resolveSkipAction]）。
  ///
  /// 加载中、出错、面板打开、后台与画中画都不打扰，免得和用户的操作打架；
  /// 每段一次播放只生效一次，用户拖回片头/片尾重看不会被拽走。
  void _applySkipMarks(Duration position) {
    if (_closed ||
        _loading ||
        _error != null ||
        _panelOpen ||
        _pictureInPictureVisible ||
        !_foreground) {
      return;
    }
    final marks = _skipMarks;
    if (marks.isEmpty) return;
    final action = resolveSkipAction(
      position: position.inMilliseconds / 1000,
      duration: _player.state.duration.inMilliseconds / 1000,
      marks: marks,
      introApplied: _introSkipped,
      outroApplied: _outroSkipped,
      hasNextEpisode: _index + 1 < widget.detail.episodes.length,
    );
    switch (action) {
      case SkipMarkAction.none:
        return;
      case SkipMarkAction.skipIntro:
        _introSkipped = true;
        _interactions.hint('已跳过片头');
        unawaited(
          _seekTo(Duration(milliseconds: (marks.introEnd * 1000).round())),
        );
      case SkipMarkAction.skipOutro:
        _outroSkipped = true;
        _cancelAdvanceCountdown();
        _interactions.hint('已跳过片尾');
        unawaited(_saveProgress(flush: true));
        unawaited(_play(_index + 1, showControlsOnReady: false));
    }
  }

  Future<void> _seekTo(Duration target) async {
    if (_closed || _loading || _error != null) return;
    _handoffOwned = false;
    widget.handoff?.fail('接收端已调整播放位置');
    final ticket = ++_seekSequence;
    final generation = _generation;
    _danmaku.beginSeek();
    _enhancement.ignorePerformance();
    var succeeded = false;
    try {
      await _player.seek(target);
      succeeded = true;
    } catch (_) {
      _notice('跳转失败，请重试');
    } finally {
      if (!_closed && ticket == _seekSequence && generation == _generation) {
        _danmaku.endSeek(succeeded ? target : _player.state.position);
      }
    }
  }

  void _seek(int seconds) {
    final desired = _player.state.position + Duration(seconds: seconds);
    final maxDuration = _player.state.duration;
    final target = desired < Duration.zero
        ? Duration.zero
        : maxDuration > Duration.zero && desired > maxDuration
        ? maxDuration
        : desired;
    unawaited(_seekTo(target));
  }

  Future<void> _televisionEpisodes(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    int? index;
    try {
      index = await showDialog<int>(
        context: context,
        builder: (_) => Theme(
          data: televisionTheme(AppTheme.dark),
          child: TelevisionEpisodeDialog(
            episodes: widget.detail.episodes,
            currentIndex: _index,
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (index != null && mounted && !_closed && index != _index) {
      await _play(index);
    }
  }

  Future<void> _televisionSettings(BuildContext context) async {
    if (_panelOpen || _closed) return;
    setState(() => _panelOpen = true);
    TelevisionPlaybackSetting? selection;
    try {
      selection = await showDialog<TelevisionPlaybackSetting>(
        context: context,
        builder: (menuContext) => AnimatedBuilder(
          animation: Listenable.merge([_danmaku, _preloader]),
          builder: (_, _) => Theme(
            data: televisionTheme(AppTheme.dark),
            child: TelevisionSettingsDialog(
              speed: _speed,
              quality: _requestedQuality,
              actualQuality: _plan?.quality ?? 0,
              qualities: _plan?.qualities ?? [],
              favorite: widget.store.isFavorite(widget.detail.drama.id),
              onFavorite: _toggleFavorite,
              autoAdvance: _autoAdvance,
              danmaku: _danmakuEnabled,
              showDanmaku: _plan?.danmakuId.isNotEmpty == true,
              danmakuStatus: _danmaku.status,
              onRetryDanmaku: _danmaku.canRetry ? _danmaku.retry : null,
              preload: _preloadEnabled,
              preloadStatus: _preloader.status,
              enhancement: _enhancementForUi,
              onCompareEnhancement: () {
                unawaited(_enhancement.toggleCompare());
                Navigator.pop(menuContext);
              },
            ),
          ),
        ),
      );
    } finally {
      if (mounted && !_closed) setState(() => _panelOpen = false);
    }
    if (selection == null || !mounted || _closed) return;
    try {
      await _setPreferences(
        _preferences.copyWith(
          speed: selection.speed,
          quality: selection.quality,
          autoAdvance: true,
          danmaku: selection.danmaku,
          preload: true,
          enhancement: selection.enhancement,
        ),
      );
    } catch (_) {
      _notice('播放偏好未能保存，请重试');
    }
  }

  /// 返回语义统一（用户定调）：左上返回键永远「返回上一页」，
  /// 退出全屏由独立键负责，系统返回手势则先退回内嵌形态。
  void _back() {
    _cancelAdvanceCountdown();
    Navigator.of(context).maybePop();
  }

  @override
  void dispose() {
    _closed = true;
    final enhancementClosed = _enhancement.close();
    LanController.current?.detachPlayback(_lanIdentity);
    widget.handoff?.fail('接收端已退出播放');
    widget.store.removeListener(_accessChanged);
    _danmaku.dispose();
    _preloader.dispose();
    _generation++;
    WidgetsBinding.instance.removeObserver(this);
    _saveTimer?.cancel();
    _mediaMemoryTimer?.cancel();
    _advanceTimer?.cancel();
    // 亮度改的是窗口真实亮度，离开播放器要还给系统
    unawaited(_interactions.releaseBrightness());
    _healthTimer?.cancel();
    _errorTimer?.cancel();
    _pictureInPictureExitTimer?.cancel();
    if (_pictureInPictureHandlerInstalled) {
      AppDevice.channel.setMethodCallHandler(null);
    }
    _battery.dispose();
    _interactions.dispose();
    _playerFocus.dispose();
    _menuRevision.dispose();
    unawaited(_saveProgress(flush: true));
    for (final subscription in _subscriptions) {
      subscription.cancel();
    }
    unawaited(widget.repository.release(_session));
    unawaited(_loader.close().catchError((Object _) {}));
    unawaited(
      _operations.catchError((Object _) {}).then((_) async {
        await _interactions.pendingRates.catchError((Object _) {});
        await enhancementClosed.catchError((Object _) {});
        await _player.dispose();
      }),
    );
    if (Platform.isWindows && !_mobile) {
      unawaited(windowManager.setFullScreen(false));
    } else if (_mobile || _television && Platform.isAndroid) {
      unawaited(
        (_orientationController?.releasePlayback(this) ??
                SystemChrome.setPreferredOrientations(
                  AppOrientationController.orientations(
                    television: _television,
                  ),
                ))
            .catchError((Object _) {}),
      );
      // 退出后按设备方向恢复：横屏回沉浸首页（衔接 home_screen 的沉浸
      // 同步），竖屏恢复常规 edgeToEdge。
      unawaited(
        SystemChrome.setEnabledSystemUIMode(
          _exitImmersive
              ? SystemUiMode.immersiveSticky
              : SystemUiMode.edgeToEdge,
        ),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final inherited = Theme.of(context);
    final theme = _television ? televisionTheme(inherited) : inherited;
    return Theme(
      data: theme,
      child: Builder(
        builder: (context) {
          // 缓存退出时是否手机横屏（dispose 无 context，恢复模式按此判定）。
          _exitImmersive = AppLayout.landscapePhone(context);
          final fullscreen = _showFullscreen;
          final overlayBrightness = fullscreen
              ? Brightness.dark
              : Theme.of(context).brightness;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            value: AppTheme.systemBars(overlayBrightness),
            child: _buildPlayer(context),
          );
        },
      ),
    );
  }

  Widget _buildPlayer(BuildContext context) {
    final theme = Theme.of(context);
    final title = widget.detail.drama.title;
    final fullscreen = _showFullscreen;
    final pictureInPicture = _pictureInPictureVisible;
    return PopScope(
      // 系统返回不再被改写成「旋转」：全屏时先退回内嵌，内嵌时才真的退出页面。
      canPop:
          _television ||
          _viewMode == PlaybackViewMode.inline ||
          _episodeSheetOpen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop || _television) return;
        // 选集面板开着时先收起它，再谈退出全屏。
        if (_episodeSheetOpen) {
          _closeEpisodeSheet();
          return;
        }
        unawaited(_setViewMode(PlaybackViewMode.inline));
      },
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): _back,
          const SingleActivator(LogicalKeyboardKey.goBack): _back,
        },
        child: Focus(
          focusNode: _playerFocus,
          onKeyEvent: (_, event) {
            if (_television ||
                _panelOpen ||
                !_playerFocus.hasPrimaryFocus ||
                !(ModalRoute.of(context)?.isCurrent ?? true)) {
              return KeyEventResult.ignored;
            }
            return _interactions.key(event);
          },
          autofocus: !_television,
          canRequestFocus: !_television,
          skipTraversal: _television,
          child: Scaffold(
            backgroundColor: fullscreen || pictureInPicture
                ? Colors.black
                : theme.scaffoldBackgroundColor,
            appBar: pictureInPicture || fullscreen || _mobile
                ? null
                : AppBar(
                    title: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    actions: [
                      IconButton(
                        tooltip: '旋转与全屏',
                        onPressed: _rotate,
                        icon: AppIcon(AppIcons.screenRotate),
                      ),
                    ],
                  ),
            body: pictureInPicture
                ? _videoPane(context)
                : SafeArea(
                    // 只有「手机 + 非全屏 + 竖屏」才需要给系统栏让位：
                    // 全屏走 immersiveSticky（系统栏已隐藏），横屏则要求画面
                    // 铺到屏幕边缘——两种情况再留状态栏高度都会让画面整体
                    // 下移、上下不对称，看起来像没居中。
                    top: !_television &&
                        !fullscreen &&
                        _mobile &&
                        MediaQuery.orientationOf(context) == Orientation.portrait,
                    bottom: !fullscreen,
                    // 手机横屏时挖孔会转到左侧（本机 1200×2608 竖屏、横屏后
                    // 左边缘 144px 是 displayCutout），SafeArea 默认会为它让位，
                    // 画面就被整体推右、左右黑边不对称。画面要铺满整屏，
                    // 让位交给控制栏自己（PlayerControls._sideChromeInset）。
                    left: !_mobile,
                    right: !_mobile,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        // 宽屏判定含高度门槛（同 detail_screen/home_screen）：
                        // 手机横屏逻辑高度 <600，仍走手机播放布局。
                        final desktop = constraints.maxWidth >= 840 &&
                            constraints.maxHeight >= 600;
                        if (fullscreen) {
                          // 竖屏全屏的选集走「底部滑入、推挤视频」布局，
                          // 其余形态维持普通铺满（横屏选集仍用右侧浮层）。
                          if (_episodeSheetEligible) {
                            return _portraitEpisodePushLayout(context);
                          }
                          return _videoPane(context);
                        }
                        if (desktop ||
                            constraints.maxWidth >
                                constraints.maxHeight * 1.3) {
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  children: [
                                    Expanded(child: _videoPane(context)),
                                  ],
                                ),
                              ),
                              SizedBox(
                                width: desktop ? 312 : 210,
                                child: _episodePanel(),
                              ),
                            ],
                          );
                        }
                        if (_mobile) {
                          final height = (constraints.maxWidth / _aspectRatio)
                              .clamp(0.0, constraints.maxHeight * .72);
                          return Column(
                            children: [
                              SizedBox(
                                height: height,
                                width: double.infinity,
                                child: _videoPane(context),
                              ),
                              Expanded(child: _mobilePlaybackPanel()),
                            ],
                          );
                        }
                        final height = (constraints.maxWidth / _aspectRatio)
                            .clamp(0.0, constraints.maxHeight * .64);
                        return Column(
                          children: [
                            SizedBox(
                              height: height,
                              width: double.infinity,
                              child: _videoPane(context),
                            ),
                            Expanded(child: _episodePanel()),
                          ],
                        );
                      },
                    ),
                  ),
          ),
        ),
      ),
    );
  }

  /// 画面层：按当前比例档位决定 fit。带 aspect 的档位（16:9 / 4:3 / 9:16）
  /// 把画面裁进固定形状的框里，用来消黑边或统一画面形状。
  Widget _videoLayer() {
    final mode = _fitMode;
    Widget surface(BoxFit fit) => Video(
      controller: _video!,
      fit: fit,
      controls: (_) => const SizedBox.shrink(),
    );
    final aspect = mode.aspect;
    if (aspect == null) return surface(mode.fit);
    return Center(
      child: AspectRatio(
        aspectRatio: aspect,
        child: ClipRect(child: surface(mode.fit)),
      ),
    );
  }

  /// 画面与片头尾：画面比例、音轨、片头/片尾标定合成一块右侧面板，
  /// 入口收在上行（用户定调：比例要和跳过片头在一起，别再各占一颗按钮）。
  Future<void> _showDisplayOptions() async {
    if (_panelOpen || _closed) return;
    _cancelAdvanceCountdown();
    _interactions.cancel();
    setState(() => _panelOpen = true);
    try {
      await showPlayerSidePanel<void>(
        context: context,
        title: '画面与片头尾',
        builder: (_) => _displayOptionsPanel(),
      );
    } finally {
      if (mounted && !_closed) {
        setState(() => _panelOpen = false);
        _playerFocus.requestFocus();
      }
    }
  }

  Widget _displayOptionsPanel() {
    return StatefulBuilder(
      builder: (context, setPanel) {
        final tracks = _player.state.tracks.audio;
        final current = _player.state.track.audio;
        return ListView(
          padding: const EdgeInsets.fromLTRB(18, 14, 18, 24),
          children: [
            _panelLabel('画面比例'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final mode in _PlayerFitMode.values)
                  _panelChip(
                    key: ValueKey('display-fit-${mode.name}'),
                    label: mode.label,
                    selected: mode == _fitMode,
                    onTap: () {
                      setState(() => _fitMode = mode);
                      setPanel(() {});
                    },
                  ),
              ],
            ),
            if (tracks.length > 1) ...[
              const SizedBox(height: 20),
              _panelLabel('音轨'),
              for (var index = 0; index < tracks.length; index++)
                _panelRow(
                  key: ValueKey('display-audio-$index'),
                  label: _audioTrackLabel(tracks[index], index),
                  selected: tracks[index].id == current.id,
                  onTap: () async {
                    try {
                      await _player.setAudioTrack(tracks[index]);
                    } catch (_) {
                      _notice('切换音轨失败，请重试');
                    }
                    if (mounted && !_closed) setPanel(() {});
                  },
                ),
            ],
            const SizedBox(height: 18),
            Divider(color: Colors.white.withValues(alpha: .08), height: 1),
            const SizedBox(height: 14),
            _panelLabel('片头尾'),
            SkipMarksPanel(
              player: _player,
              marks: _skipMarks,
              scrollable: false,
              padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
              onSaved: (next) async {
                _skipMarks = next;
                if (mounted && !_closed) setState(() {});
                await widget.store.setSkipMarks(_skipMarksId, next);
              },
            ),
          ],
        );
      },
    );
  }

  Widget _panelLabel(String text) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        letterSpacing: .3,
        color: Colors.white.withValues(alpha: .55),
      ),
    ),
  );

  Widget _panelChip({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) => GestureDetector(
    key: key,
    behavior: HitTestBehavior.opaque,
    onTap: onTap,
    child: Container(
      height: 40,
      constraints: const BoxConstraints(minWidth: 64),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: selected ? Colors.white : Colors.white.withValues(alpha: .1),
        borderRadius: BorderRadius.circular(8),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: selected ? Colors.black : Colors.white,
        ),
      ),
    ),
  );

  Widget _panelRow({
    required Key key,
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      key: key,
      onTap: onTap,
      child: SizedBox(
        height: 46,
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: selected ? FontWeight.w600 : null,
                  color: selected ? primary : Colors.white.withValues(alpha: .8),
                ),
              ),
            ),
            if (selected) AppIcon(AppIcons.check, size: 18, color: primary),
          ],
        ),
      ),
    );
  }

  String _audioTrackLabel(AudioTrack track, int index) {
    final title = track.title?.trim() ?? '';
    if (title.isNotEmpty) return title;
    final language = track.language?.trim() ?? '';
    if (language.isNotEmpty) return language;
    return '音轨 ${index + 1}';
  }

  /// 控制层（顶栏 + 进度行 + 按钮行）。
  ///
  /// 单独抽出来是为了让「竖屏全屏选集推挤」布局复用同一套控制栏：推挤时
  /// 把它淡出即可，不必把几十个参数再抄一份、也免得两处接线走偏。
  Widget _controlsOverlay({required bool hideOverlay}) {
    if (hideOverlay) return const SizedBox.shrink();
    final title =
        '${widget.detail.drama.title} · 第 ${widget.detail.episodes[_index].number} 集${_plan?.local == true ? ' · 本地' : ''}${widget.detail.episodes[_index].vip ? ' · VIP 试看' : ''}${(_plan?.routeIndex ?? 0) > 0 ? ' · 线路 ${_plan!.routeIndex + 1}' : ''}';
    return _television
        ? TelevisionControls(
            player: _player,
            title: title,
            enabled: !_loading && _error == null,
            showOnPlaybackReady: _showControlsOnPlaybackReady,
            enhancement: _enhancementForUi,
            onTogglePlayback: _togglePlayback,
            onSeek: _seek,
            onPrevious: _index > 0 ? () => _play(_index - 1) : null,
            onNext: _index + 1 < widget.detail.episodes.length
                ? () => _play(_index + 1)
                : null,
            onEpisodes: () => _televisionEpisodes(context),
            onSettings: () => _televisionSettings(context),
            onBack: _back,
          )
        : AnimatedBuilder(
            // 电量 10 秒变一次：只重建控制层，不拖着整个播放页重建。
            animation: _battery,
            builder: (context, _) => PlayerControls(
              player: _player,
              interactions: _interactions,
              enabled: !_loading && _error == null,
              enhancement: _enhancementForUi,
              panelOpen: _panelOpen,
              fullscreen: _showFullscreen,
              showOnPlaybackReady: _showControlsOnPlaybackReady,
              title: title,
              onTogglePlayback: _togglePlayback,
              swipeEnabled: _mobile,
              landscapeChrome: _landscapeChrome,
              compact: !_showFullscreen,
              batteryLevel: _battery.reading?.level,
              onFullscreen: _fullscreenSupported ? _rotate : null,
              forceLandscape: _landscapeChrome,
              onLockChanged: _setScreenLocked,
              onPortraitFullscreen: _mobile
                  ? () => _setViewMode(PlaybackViewMode.portraitFullscreen)
                  : null,
              onLandscapeFullscreen: _mobile
                  ? () => _setViewMode(PlaybackViewMode.landscapeFullscreen)
                  : null,
              onExitFullscreen: () => _setViewMode(PlaybackViewMode.inline),
              onBack: _back,
              onFocusSurface: _playerFocus.requestFocus,
              onSeek: _seekTo,
              onNext: _index + 1 < widget.detail.episodes.length
                  ? () => _play(_index + 1)
                  : null,
              hasNext: _index + 1 < widget.detail.episodes.length,
              speed: _speed,
              qualityLabel: _qualityLabel,
              showQuality: true,
              showDanmaku: _plan?.danmakuId.isNotEmpty == true,
              danmakuEnabled: _danmakuEnabled,
              danmaku: _danmaku,
              onEpisodes: () => _openPanel(PlayerMenuSection.episodes),
              onSpeed: () => _openPanel(PlayerMenuSection.speed),
              onQuality: () => _openPanel(PlayerMenuSection.quality),
              routeLabel: _routeLabel,
              // 入口可用性按「线路数 ≥2」判定，而非 hasAlternative（后者语义是
              // 「当前不是最后一条」，处在最后一条时为 false → 线路按钮整个
              // 消失，用户再也切不回来；真果·鉴一集常带 20~30 条线，必现）。
              onRoute: (_plan?.routeCount ?? 0) >= 2
                  ? (_television ? _switchRoute : _showRouteMenu)
                  : null,
              onDisplayOptions: _showDisplayOptions,
              skipMarksSet: !_skipMarks.isEmpty,
              onDanmaku: _plan?.danmakuId.isNotEmpty == true
                  ? _toggleDanmaku
                  : null,
              onRetryDanmaku: _retryDanmakuFromControls,
              onPush: widget.mediaId == null ? _pushToDevice : null,
              onPictureInPicture: _canUsePictureInPicture
                  ? _enterPictureInPicture
                  : null,
            ),
          );
  }

  Widget _videoPane(BuildContext context, {bool hideControls = false}) {
    final videoTheme = _television
        ? televisionTheme(AppTheme.dark)
        : AppTheme.dark;
    final hideOverlayForPictureInPicture = _pictureInPictureVisible;
    final Widget controls = _controlsOverlay(
      hideOverlay: hideOverlayForPictureInPicture || hideControls,
    );
    final layeredControls = Stack(
      fit: StackFit.expand,
      children: [
        if (!hideOverlayForPictureInPicture)
          DanmakuOverlay(controller: _danmaku, aspectRatio: _aspectRatio),
        controls,
      ],
    );
    return Theme(
      data: videoTheme,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final ratio = MediaQuery.devicePixelRatioOf(context);
          final pixels = Size(
            constraints.maxWidth * ratio,
            constraints.maxHeight * ratio,
          );
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && !_closed) {
              _enhancement.setViewport(pixels, television: _television);
            }
          });
          return Stack(
            key: _videoPaneKey,
            fit: StackFit.expand,
            children: [
              if (widget.videoBuilder != null)
                widget.videoBuilder!(layeredControls)
              else ...[
                // 画面与控件分成两层：比例档会把画面裁进固定形状的框，
                // 控件层跟着被裁就会只剩一小块可点区域。
                _videoLayer(),
                layeredControls,
              ],
              // 亮度遮罩模拟：手势亮度只调这层透明度，不修改系统亮度。
              // 手势期间逐帧变化，局部监听只重建这一层遮罩。
              if (!hideOverlayForPictureInPicture)
                ListenableBuilder(
                  listenable: _interactions,
                  builder: (context, _) {
                    if (_interactions.brightness >= 1 ||
                        _interactions.brightnessViaSystem) {
                      return const SizedBox.shrink();
                    }
                    return IgnorePointer(
                      child: ColoredBox(
                        color: Colors.black.withValues(
                          alpha: (1 - _interactions.brightness) * .72,
                        ),
                      ),
                    );
                  },
                ),
              if (_loading && !hideOverlayForPictureInPicture)
                ColoredBox(
                  // 解析新地址阶段（_swapping=false）画面还停在旧集最后一帧，
                  // 只垫一层浅遮罩让用户看得到画面；真正换源出首帧前才压黑。
                  color: Colors.black.withValues(alpha: _swapping ? .78 : .32),
                  child: Align(
                    // 进度反馈放画面中下部小胶囊：正中央留给旧集定格画面，
                    // 别让转圈+文案压住内容
                    alignment: const Alignment(0, 0.72),
                    child: Container(
                      margin: const EdgeInsets.all(16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .55),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            _loadingMessage,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              if (_error != null && !hideOverlayForPictureInPicture)
                ColoredBox(
                  color: Colors.black.withValues(alpha: .9),
                  child: StatusPanel(
                    title: '暂时无法播放',
                    message: _error!,
                    onRetry: () => _retry(),
                    action: _localFailure ? '重试本地播放' : '重试播放',
                    secondaryAction: _localFailure && widget.allowOnlineFallback
                        ? TextButton.icon(
                            onPressed: _switchOnline,
                            icon: AppIcon(AppIcons.cloud),
                            label: const Text('改为在线播放'),
                          )
                        : !_localFailure &&
                              !widget.localOnly &&
                              widget.repository.supportsSourceManagement
                        ? SourceDiagnosticsButton(
                            repository: widget.repository,
                            store: widget.store,
                            drama: widget.detail.drama,
                          )
                        : null,
                    icon: AppIcon(AppIcons.playDisabled),
                  ),
                ),
              // 移动端竖屏加载/出错时 PlayerControls 顶栏（_feedTopBar）因
              // enabled=false 不渲染，遮罩又盖住整个视频面，没有这个按钮
              // 就只能依赖系统返回手势。
              if (!_showFullscreen &&
                  _mobile &&
                  !hideOverlayForPictureInPicture &&
                  (_loading || _error != null))
                _overlayBackButton(),
              if ((_loading || _error != null) &&
                  !hideOverlayForPictureInPicture &&
                  _showFullscreen &&
                  !_television)
                SafeArea(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Row(
                      children: [
                        IconButton(
                          tooltip: '退出全屏',
                          onPressed: _rotate,
                          icon: AppIcon(AppIcons.arrowBack),
                        ),
                        const Spacer(),
                        TextButton(
                          onPressed: () =>
                              _openPanel(PlayerMenuSection.episodes),
                          child: const Text('选集'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (_saveWarning != null && !hideOverlayForPictureInPicture)
                Positioned(
                  top: 52,
                  left: 12,
                  right: 12,
                  child: SafeArea(
                    bottom: false,
                    child: Material(
                      color: const Color(0xE6322424),
                      borderRadius: BorderRadius.circular(8),
                      child: Padding(
                        padding: const EdgeInsets.all(8),
                        child: Wrap(
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              _saveWarning!,
                              style: const TextStyle(fontSize: 12),
                            ),
                            TextButton(
                              onPressed: _saveProgress,
                              child: const Text('重试保存'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              if (!hideOverlayForPictureInPicture)
                ListenableBuilder(
                  listenable: _interactions,
                  builder: (context, _) {
                    if (_advanceSeconds <= 0 &&
                        _interactions.hudState.type == SwipeAction.none) {
                      return const SizedBox.shrink();
                    }
                    return _buildGestureHud();
                  },
                ),
            ],
          );
        },
      ),
    );
  }

  /// 连播倒计时提示：显示下一集标题与剩余秒数，点击可取消
  Widget _buildAdvanceCountdown() {
    final episodes = widget.detail.episodes;
    final next = _index + 1;
    final title = next < episodes.length
        ? '即将播放第 ${episodes[next].number} 集'
        : '即将播放下一集';
    return Center(
      child: GestureDetector(
        key: const ValueKey('player-advance-countdown'),
        onTap: _cancelAdvanceCountdown,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: .62),
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                style: const TextStyle(color: Colors.white, fontSize: 15),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$_advanceSeconds',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    '秒后自动播放 · 点此取消',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGestureHud() {
    final hud = _interactions.hudState;
    if (_advanceSeconds > 0) return _buildAdvanceCountdown();
    switch (hud.type) {
      case SwipeAction.brightness:
      case SwipeAction.volume:
        final valuePct = (hud.value * 100).round().clamp(0, 100);
        final icon = hud.type == SwipeAction.brightness
            ? AppIcons.lightMode
            : valuePct == 0
            ? AppIcons.volumeOff
            : AppIcons.volumeUp;
        return _topGestureHud(
          leading: icon,
          text: '$valuePct%',
          ratio: valuePct / 100,
        );
      case SwipeAction.seek:
        final pos = hud.position ?? Duration.zero;
        final total = _player.state.duration;
        final forward = pos >= _player.state.position;
        final icon = forward ? AppIcons.fastForward : AppIcons.fastRewind;
        return _topGestureHud(
          leading: icon,
          text: total > Duration.zero
              ? '${formatPosition(pos.inMilliseconds / 1000)} / '
                    '${formatPosition(total.inMilliseconds / 1000)}'
              : formatPosition(pos.inMilliseconds / 1000),
          ratio: hud.value.clamp(0.0, 1.0),
        );
      case SwipeAction.episode:
        final forward = hud.value > 0;
        final icon = forward ? AppIcons.skipNext : AppIcons.skipPrevious;
        return _topGestureHud(
          leading: icon,
          text: hud.label ?? (forward ? '下一集' : '上一集'),
          ratio: 1,
          showBar: false,
        );
      case SwipeAction.none:
        return const SizedBox.shrink();
    }
  }

  /// 手势提示：只有顶部那一条「图标 + 细填充条 + 数字」。
  /// 旧版左中还杵着一颗主色大圆图标，用户明确不要（挡画面又抢注意力）。
  Widget _topGestureHud({
    required String leading,
    required String text,
    required double ratio,
    bool showBar = true,
  }) {
    final primary = Theme.of(context).colorScheme.primary;
    return IgnorePointer(
      child: Stack(
        children: [
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.only(top: 18),
              child: Align(
                alignment: Alignment.topCenter,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .42),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(leading, size: 18, color: Colors.white),
                      if (showBar) ...[
                        const SizedBox(width: 10),
                        // 条宽 200 是理想值，窄屏让位给文字（否则整行溢出）。
                        Flexible(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 200),
                            child: SizedBox(
                              height: 4,
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(2),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    ColoredBox(
                                      color: Colors.white.withValues(alpha: .3),
                                    ),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: FractionallySizedBox(
                                        widthFactor: ratio.clamp(0.0, 1.0),
                                        child: ColoredBox(color: primary),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          text,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12.5,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _overlayBackButton() {
    return Align(
      alignment: Alignment.topLeft,
      child: Padding(
        padding: const EdgeInsets.only(left: 4, top: 8),
        child: IconButton(
          tooltip: '返回',
          onPressed: _back,
          icon: AppIcon(AppIcons.arrowBack),
        ),
      ),
    );
  }

  Widget _mobilePlaybackPanel() {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _mobileTabs(colors),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: _mobileTab == 0
                      ? _episodePanel(compact: true)
                      : _mobileTab == 1
                      ? _mobileSynopsis()
                      : _mobileDownload(),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _mobileTabs(ColorScheme colors) => Padding(
    padding: const EdgeInsets.fromLTRB(8, 2, 8, 0),
    child: SizedBox(
      height: 42,
      child: Row(
        children: [
          _mobileTabButton(0, '选集'),
          _mobileTabButton(1, '简介'),
          _mobileTabButton(2, '下载'),
        ],
      ),
    ),
  );

  Widget _mobileTabButton(int value, String label) {
    final selected = _mobileTab == value;
    final colors = Theme.of(context).colorScheme;
    return Expanded(
      child: InkWell(
        onTap: () => setState(() => _mobileTab = value),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: selected ? colors.primary : Colors.transparent,
                width: 2,
              ),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? colors.onSurface : colors.onSurfaceVariant,
              fontSize: 13,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }

  void _openRelated(String label) => openRelatedCatalog(
    context,
    repository: widget.repository,
    store: widget.store,
    drama: widget.detail.drama,
    label: label,
  );

  Widget _mobileSynopsis() {
    final drama = widget.detail.drama;
    final colors = Theme.of(context).colorScheme;
    final sourceName = SourceSite.byId(drama.source)?.name ?? '未知源';
    final metaStyle = TextStyle(color: colors.onSurfaceVariant);
    final body = drama.description.trim().isEmpty
        ? '暂无简介'
        : drama.description;
    return ColoredBox(
      color: colors.surface,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 82,
                height: 123,
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    // 站源名与分类可点：跳该站源相关结果页（同详情页简介区）。
                    Wrap(
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        MetaLink(
                          label: sourceName,
                          tooltip: '查看$sourceName的全部作品',
                          onTap: () => openSourceCatalog(
                            context,
                            repository: widget.repository,
                            store: widget.store,
                            drama: drama,
                            sourceName: sourceName,
                          ),
                        ),
                        if (drama.episodes > 0) ...[
                          Text(' · ', style: metaStyle),
                          Text(drama.episodeLabel, style: metaStyle),
                        ],
                        if (drama.releaseStatus.isNotEmpty &&
                            drama.releaseStatus != 'unknown') ...[
                          Text(' · ', style: metaStyle),
                          Text(drama.releaseLabel, style: metaStyle),
                        ],
                        if (drama.category.isNotEmpty) ...[
                          Text(' · ', style: metaStyle),
                          MetaLink(
                            label: drama.category,
                            tooltip: '查看同类${drama.category}',
                            onTap: () => _openRelated(drama.category),
                          ),
                        ],
                      ],
                    ),
                    if (drama.onlineDate.isNotEmpty ||
                        drama.heat.isNotEmpty ||
                        drama.views.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        [
                          if (drama.onlineDate.isNotEmpty)
                            '${drama.onlineDate} 上线',
                          if (drama.heat.isNotEmpty) '热度 ${drama.heat}',
                          if (drama.views.isNotEmpty) '播放 ${drama.views}',
                        ].join(' · '),
                        style: TextStyle(color: colors.onSurfaceVariant),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mobileFollowControl(drama),
          if (drama.tags.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                // Chip 本体不可点（构造没有 onPressed），可点的这一档用
                // ActionChip：同样是紧凑胶囊，自带 Material 水波纹与 tooltip。
                for (final tag in drama.tags.take(12))
                  ActionChip(
                    label: Text(tag),
                    visualDensity: VisualDensity.compact,
                    tooltip: '查看「$tag」相关内容',
                    onPressed: () => _openRelated(tag),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Text(body, style: const TextStyle(height: 1.55)),
          if (widget.detail.warning.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(widget.detail.warning, style: TextStyle(color: colors.error)),
          ],
          RelatedDramaRail(
            repository: widget.repository,
            store: widget.store,
            drama: drama,
            onOpen: _openRelatedDrama,
          ),
        ],
      ),
    );
  }

  /// 点推荐卡：推那部剧自己的简介页。
  Future<void> _openRelatedDrama(Drama next) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: next,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  Widget _mobileFollowControl(Drama drama) {
    final state = widget.store.following(drama.id);
    return PopupMenuButton<String>(
      key: const ValueKey('player-follow-status'),
      tooltip: '追剧与观看状态',
      onSelected: (value) async {
        if (_profileEpoch != widget.store.profileEpoch) return;
        if (value == 'remove') {
          await saveUserChange(
            context,
            () => widget.store.toggleFavorite(drama),
          );
        } else {
          final status = FollowStatus.values.firstWhere(
            (status) => status.name == value,
          );
          await saveUserChange(
            context,
            () => widget.store.setFollowStatus(drama, status),
          );
        }
        if (mounted && !_closed) setState(() {});
      },
      itemBuilder: (_) => [
        for (final status in FollowStatus.values)
          CheckedPopupMenuItem(
            value: status.name,
            checked: state?.status == status,
            child: Text(status.label),
          ),
        if (state != null)
          const PopupMenuItem(value: 'remove', child: Text('取消追剧')),
      ],
      child: Container(
        constraints: const BoxConstraints(minHeight: 36),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: state == null
              ? Theme.of(context).colorScheme.surfaceContainerHighest
              : Theme.of(context).colorScheme.secondaryContainer,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            state == null
                ? AppIcon(AppIcons.bookmarkAdd, size: 18)
                : AppIcon(AppIcons.bookmark, filled: true, size: 18),
            const SizedBox(width: 6),
            Text(state?.label ?? '加入追剧'),
            const SizedBox(width: 2),
            AppIcon(AppIcons.expandMore, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _mobileDownload() {
    final colors = Theme.of(context).colorScheme;
    if (!widget.repository.supportsDownloads || !widget.store.canDownload) {
      return ColoredBox(
        color: colors.surface,
        child: const StatusPanel(
          title: '下载不可用',
          message: '当前用户或当前环境未开放本地下载。',
          icon: AppIcon(AppIcons.download),
        ),
      );
    }
    return DownloadPicker(
      detail: widget.detail,
      preferences: widget.store.downloadPreferences,
      embedded: true,
      onSubmit: _submitDownloadSelection,
    );
  }

  Widget _episodePanel({bool compact = false}) => ColoredBox(
    color: Theme.of(context).colorScheme.surface,
    child: PlayerEpisodeGrid(
      episodes: widget.detail.episodes,
      currentIndex: _index,
      compact: compact,
      title: compact ? '剧集' : '选集',
      // 剧集完结状态：releaseStatus 已知时标题带「已完结 / 连载中」。
      note:
          widget.detail.drama.releaseStatus.isNotEmpty &&
              widget.detail.drama.releaseStatus != 'unknown'
          ? widget.detail.drama.releaseLabel
          : '',
      onSelected: (index) => _play(index),
    ),
  );
}

/// 竖屏全屏的「底部推挤选集」布局：视频收缩到顶部小窗，选集从底部滑入。
///
/// 收起时先播完滑出动画再把面板从树上摘掉：这样退出过程不突兀，
/// 面板也不会在收起后继续占着命中测试。
class _PortraitEpisodePushLayout extends StatefulWidget {
  const _PortraitEpisodePushLayout({
    required this.open,
    required this.video,
    required this.panel,
  });

  /// 面板是否展开。
  final bool open;

  /// 视频层（全屏铺满 → 顶部小窗）。
  final Widget video;

  /// 选集面板内容。
  final Widget panel;

  @override
  State<_PortraitEpisodePushLayout> createState() =>
      _PortraitEpisodePushLayoutState();
}

class _PortraitEpisodePushLayoutState extends State<_PortraitEpisodePushLayout>
    with SingleTickerProviderStateMixin {
  static const Duration _duration = Duration(milliseconds: 280);

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: _duration,
  );

  late final CurvedAnimation _curved = CurvedAnimation(
    parent: _controller,
    curve: Curves.easeOutCubic,
  );

  /// 面板是否还挂在树上：收起动画播完才摘掉。
  bool _panelMounted = false;

  @override
  void initState() {
    super.initState();
    _panelMounted = widget.open;
    _controller.value = widget.open ? 1 : 0;
  }

  @override
  void didUpdateWidget(covariant _PortraitEpisodePushLayout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.open == oldWidget.open) return;
    if (widget.open) {
      setState(() => _panelMounted = true);
      _controller.forward();
    } else {
      _controller.reverse().whenComplete(() {
        if (mounted) setState(() => _panelMounted = false);
      });
    }
  }

  @override
  void dispose() {
    _curved.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final sheetHeight = size.height * .66;
    return Stack(
      fit: StackFit.expand,
      children: [
        // 视频：全屏 ↔ 顶部小窗，与面板同步推挤。
        AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            final t = _curved.value;
            return Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: size.height - sheetHeight * t,
              child: KeyedSubtree(
                key: const ValueKey('player-push-video'),
                child: widget.video,
              ),
            );
          },
        ),
        if (_panelMounted)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: sheetHeight,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 1),
                end: Offset.zero,
              ).animate(_curved),
              child: widget.panel,
            ),
          ),
      ],
    );
  }
}
