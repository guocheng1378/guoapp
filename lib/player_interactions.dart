import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';

import 'screen_brightness.dart';
import 'widgets.dart';

enum SwipeAction { none, brightness, volume, seek, episode }

class GestureHudState {
  const GestureHudState({
    this.type = SwipeAction.none,
    this.value = 0.0,
    this.position,
    this.label,
  });
  final SwipeAction type;
  final double value;              // 0.0 ~ 1.0，亮度/音量比例；episode 时存方向(1 下一集/-1 上一集)
  final Duration? position;       // seek 目标位置
  final String? label;            // episode 切换提示文案
}

class PlayerInteractions extends ChangeNotifier {
  PlayerInteractions({
    required this.player,
    required this.available,
    required this.baseSpeed,
    required this.onTogglePlayback,
    this.onFullscreen,
    this.onEpisode,
    this.onSeek,
    this.initialBrightness = 1.0,
    this.initialVolume,
    this.onGestureStart,
  }) {
    _brightness = initialBrightness.clamp(.05, 1.0);
    _volumeMemory = (initialVolume ?? 100).clamp(0.0, 100.0);
    _playing = player.stream.playing.listen((playing) {
      // 滑动快进期间主动暂停画面做冻结预览，不视为外部打断
      if (!playing && !_pausedForSeek) cancel();
    });
  }

  final Player player;
  final bool Function() available;
  final double Function() baseSpeed;
  final VoidCallback onTogglePlayback;
  final VoidCallback? onFullscreen;
  final String Function(int direction)? onEpisode;
  final Future<void> Function(Duration)? onSeek;

  /// 跨剧沿用的手感：遮罩亮度与播放器音量
  final double initialBrightness;
  final double? initialVolume;

  /// 手指按下即通知（连播倒计时等外部状态据此让位）
  final VoidCallback? onGestureStart;
  late final StreamSubscription<bool> _playing;
  Timer? _holdTimer;
  Timer? _hintTimer;
  Timer? _rateEaseTimer;
  Future<void> _rates = Future<void>.value();
  final Set<int> _pointers = {};
  int? _pointer;
  Offset? _origin;
  Offset? _lastPosition;
  Offset? _lastTapOrigin;
  bool _swipeEnabled = false;
  bool _moved = false;
  bool _held = false;
  bool _boosting = false;
  bool _keyboardHold = false;
  bool _cancelUntilRelease = false;
  bool _disposed = false;
  double _unmutedVolume = 100;
  String _feedback = '';
  DateTime _ignoreTapUntil = DateTime(2000);
  SwipeAction _swipeAction = SwipeAction.none;
  GestureHudState _hudState = const GestureHudState();
  double _brightness = 1.0;
  bool _brightnessViaSystem = false;
  bool _pausedForSeek = false;
  bool _wasPlayingBeforeSeek = false;
  double _initialBrightness = 0.5;
  double _initialVolume = 100;
  double _volumeMemory = 100;
  double _originPositionMs = 0;
  double _viewHeight = 0.0;
  double _viewWidth = 0.0;
  bool _episodeFired = false;
  Timer? _hudTimer;

  GestureHudState get hudState => _hudState;
  double get brightness => _brightness;

  /// 当前音量（0~100），供播放页持久化后跨剧沿用
  double get volume => _volumeMemory;
  bool get isBrightnessActive => _hudState.type == SwipeAction.brightness;
  Offset? get lastTapOrigin => _lastTapOrigin;
  double get viewWidth => _viewWidth;

  void setBrightnessDirect(double value) {
    if (_disposed) return;
    _applyBrightness(value);
    _showHud(SwipeAction.brightness, _brightness);
  }

  /// 亮度统一出口：Android 走窗口真实亮度（与系统同一套背光，不突兀），
  /// 平台不支持时退回画面遮罩模拟。
  void _applyBrightness(double value) {
    _brightness = value.clamp(0.01, 1.0);
    if (_brightnessViaSystem) {
      unawaited(ScreenBrightness.apply(_brightness));
    }
  }

  /// 以系统当前亮度为起点，并把后续调节切到「真实亮度」模式。
  Future<void> adoptSystemBrightness(double systemValue) async {
    if (_disposed) return;
    _brightness = systemValue.clamp(0.01, 1.0);
    final ok = await ScreenBrightness.apply(_brightness);
    if (_disposed) return;
    // 通道不可用时保持遮罩模拟，保证亮度依然可调
    _brightnessViaSystem = ok;
    notifyListeners();
  }

  /// 退出播放器：恢复「跟随系统亮度」，别把用户的系统亮度留在被改过的状态。
  Future<void> releaseBrightness() async {
    if (_disposed) return;
    if (_brightnessViaSystem) await ScreenBrightness.followSystem();
  }

  /// 亮度是否已交给系统背光（true 时画面不该再叠黑纱）。
  bool get brightnessViaSystem => _brightnessViaSystem;

  void dismissBrightnessHud() {
    _scheduleDismissHud();
  }

  /// 进入安静期：滑动调进度提交后调用，期间提示不再唤出工具栏。
  void enterQuietPeriod() {
    _quietUntil = DateTime.now().add(const Duration(milliseconds: 1600));
  }

  String get feedback => _feedback;
  bool get boosting => _boosting;

  /// 安静期：滑动调进度刚结束时，提示照弹但不该把工具栏唤出来，
  /// 否则「快进至 xx」的提示会把控制条重新顶到画面上。
  bool get quiet => DateTime.now().isBefore(_quietUntil);
  DateTime _quietUntil = DateTime(2000);
  bool get suppressTap => DateTime.now().isBefore(_ignoreTapUntil);
  Future<void> get pendingRates => _rates;

  void hint(String message, {bool persistent = false}) {
    if (_disposed) return;
    _hintTimer?.cancel();
    if (_feedback != message) {
      _feedback = message;
      notifyListeners();
    }
    if (!persistent && message.isNotEmpty) {
      _hintTimer = Timer(const Duration(milliseconds: 1200), () {
        hint(_boosting ? '2 倍速 · 松开恢复' : '', persistent: true);
      });
    }
  }

  Future<void> applySpeed() => _setRate(baseSpeed());

  Future<void> _setRate(double value) {
    _rates = _rates
        .catchError((Object _) {})
        .then((_) => player.setRate(value));
    unawaited(
      _rates.catchError((Object _) {
        hint('倍速调整失败，请重试');
      }),
    );
    return _rates;
  }

  // 滑动快进步长随片长自适应：滑满 1/3 屏宽 ≈ 片长的 1/6
  // （短剧 90 秒 → 约 15 秒/次；60 秒 → 10 秒；长视频封顶 120 秒防失控）
  double _seekSecondsPerThird() {
    final durationMs = player.state.duration.inMilliseconds;
    if (durationMs <= 0) return 5.0;
    return (durationMs / 6000.0).clamp(5.0, 120.0);
  }

  void _beginHold({bool keyboard = false}) {
    if (!available() || _holdTimer != null || _boosting) return;
    _keyboardHold = keyboard;
    _holdTimer = Timer(const Duration(milliseconds: 350), () {
      _holdTimer = null;
      if (_disposed ||
          !available() ||
          !player.state.playing ||
          player.state.completed) {
        return;
      }
      _boosting = true;
      _held = true;
      _rateEaseTimer?.cancel();
      unawaited(_setRate(2));
      hint('2 倍速 · 松开恢复', persistent: true);
    });
  }

  void _endHold({bool tap = false, bool silent = false}) {
    final wasKeyboard = _keyboardHold;
    final boosted = _boosting;
    _holdTimer?.cancel();
    _holdTimer = null;
    _keyboardHold = false;
    _boosting = false;
    if (boosted) {
      _easeRateBack();
      if (!silent) {
        // 提示照弹，但安静期内不把工具栏顶出来（与滑动 seek 松手同一套
        // 机制），否则松开倍速的瞬间控制条又弹回画面上
        _quietUntil = DateTime.now().add(const Duration(milliseconds: 800));
        hint('恢复 ${baseSpeed()} 倍速');
      }
    } else if (tap && wasKeyboard) {
      seek(5);
    }
  }

  // 松开长按加速后先回 1.5 倍再回正常倍速，避免速率瞬间跳变
  void _easeRateBack() {
    _rateEaseTimer?.cancel();
    final base = baseSpeed();
    if (base >= 1.5) {
      unawaited(_setRate(base));
      return;
    }
    unawaited(_setRate(1.5));
    _rateEaseTimer = Timer(const Duration(milliseconds: 160), () {
      if (!_disposed) unawaited(_setRate(baseSpeed()));
    });
  }

  // 滑动快进时冻结画面：暂停播放让画面停在当前帧，预览更直观
  void _pauseForSeekPreview() {
    if (_pausedForSeek || !player.state.playing) return;
    _pausedForSeek = true;
    _wasPlayingBeforeSeek = true;
    unawaited(player.pause());
  }

  void _resumeAfterSeek() {
    if (!_pausedForSeek) return;
    _pausedForSeek = false;
    if (_wasPlayingBeforeSeek && !_disposed) unawaited(player.play());
  }

  void cancel() {
    if (_disposed) return;
    if (_pointers.isNotEmpty) {
      _cancelUntilRelease = true;
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _lastPosition = null;
    _hudTimer?.cancel();
    if (_hudState.type != SwipeAction.none) {
      _hudState = const GestureHudState();
      notifyListeners();
    }
    _endHold(silent: true);
    _resumeAfterSeek();
    hint('');
  }

  void pointerDown(
    PointerDownEvent event, {
    required bool swipeEnabled,
    double width = 0.0,
    required double height,
  }) {
    _pointers.add(event.pointer);
    if (_pointers.length != 1 || _cancelUntilRelease) {
      cancel();
      return;
    }
    if (!available() || event.buttons != kPrimaryButton) return;
    onGestureStart?.call();
    _pointer = event.pointer;
    _origin = _lastPosition = _lastTapOrigin = event.localPosition;
    _viewHeight = height;
    _viewWidth = width;
    // 左右边缘留出系统返回手势禁区，避免与滑动快进/快退冲突
    _swipeEnabled = swipeEnabled &&
        event.kind == PointerDeviceKind.touch &&
        (width <= 0 ||
            (event.localPosition.dx > 24 &&
                event.localPosition.dx < width - 24));
    _moved = _held = false;
    _swipeAction = SwipeAction.none;
    _episodeFired = false;

    if (_swipeEnabled && width > 0) {
      // 记录起始值，后续在 pointerMove 里根据方向选择分支
      _initialBrightness = _brightness;
      // 音量以记忆值为起点（换源后播放器音量会被重置），并同步回记忆
      final currentVolume = player.state.volume;
      if (currentVolume > 0) _volumeMemory = currentVolume;
      _initialVolume = _volumeMemory;
      final pos = player.state.position.inMilliseconds;
      _originPositionMs = pos.isFinite ? pos.toDouble() : 0.0;
    }
    _beginHold();
  }

  void pointerMove(PointerMoveEvent event) {
    if (_pointer != event.pointer || _origin == null) return;
    _lastPosition = event.localPosition;
    final diff = event.localPosition - _origin!;
    if (diff.distance > 12) {
      _moved = true;
      _endHold();
    }
    if (!_swipeEnabled || !_moved || _viewHeight <= 0 || _viewWidth <= 0) return;

    // 首次进入时根据位移方向锁定分支
    if (_swipeAction == SwipeAction.none) {
      final absDx = diff.dx.abs();
      final absDy = diff.dy.abs();
      // 水平位移显著大于垂直 → seek。
      if (absDx > absDy * 1.2 && absDx > 15) {
        _swipeAction = SwipeAction.seek;
        _pauseForSeekPreview();
      } else if (absDy > absDx * 1.2 && absDy > 15) {
        // 垂直位移：左 25% 亮度 / 右 25% 音量，中间竖滑切上/下集
        final x = event.localPosition.dx;
        if (x < _viewWidth * 0.25) {
          _swipeAction = SwipeAction.brightness;
          _initialBrightness = _brightness;
        } else if (x > _viewWidth * 0.75) {
          _swipeAction = SwipeAction.volume;
        } else if (onEpisode != null) {
          _swipeAction = SwipeAction.episode;
        }
      }
    }
    if (_swipeAction == SwipeAction.none) return;

    if (_swipeAction == SwipeAction.brightness) {
      final dy = _origin!.dy - event.localPosition.dy; // 向上滑动 = 变亮
      final deltaRatio = dy / (_viewHeight * 0.35);
      // 亮度：Android 直接改窗口真实亮度，其他平台退回遮罩模拟
      _applyBrightness(_initialBrightness + deltaRatio);
      _showHud(SwipeAction.brightness, _brightness);
    } else if (_swipeAction == SwipeAction.volume) {
      final dy = _origin!.dy - event.localPosition.dy; // 向上滑动 = 加音量
      final deltaRatio = dy / (_viewHeight * 0.35);
      final newVol = (_initialVolume + deltaRatio * 100).clamp(0.0, 100.0);
      unawaited(player.setVolume(newVol));
      if (newVol > 0) {
        _unmutedVolume = newVol;
        _volumeMemory = newVol;
      }
      _showHud(SwipeAction.volume, newVol / 100.0);
    } else if (_swipeAction == SwipeAction.seek) {
      // 水平滑动：向右 = 快进，向左 = 后退；步长随片长自适应
      final dx = event.localPosition.dx - _origin!.dx;
      final secondsDelta = (dx / (_viewWidth * 0.33)) * _seekSecondsPerThird();
      final durationMs = player.state.duration.inMilliseconds;
      var target = (_originPositionMs + secondsDelta * 1000).round();
      if (durationMs > 0) target = target.clamp(0, durationMs);
      target = target.clamp(0, const Duration(hours: 10).inMilliseconds);
      final targetDur = Duration(milliseconds: target);
      final progress = durationMs > 0 ? target / durationMs : 0.0;
      // 滑动过程只刷新 HUD 预览（数值由手指位移直接算出，天然跟手），
      // 不做真实 seek——逐帧 seek 会让解码器反复缓冲、画面追不上手；
      // 最终位置在 pointerUp 一次性提交。
      _showHud(SwipeAction.seek, progress, position: targetDur);
    } else if (_swipeAction == SwipeAction.episode) {
      // 中间竖滑：上滑下一集、下滑上一集；达到阈值立即切一次，
      // 本次手势内锁定，避免连滑连续跳集。阈值 20% 屏高——12% 太容易
      // 在「想滚动一下」时误切集；跨阈值补一次中等震动告诉用户已触发。
      if (_episodeFired || onEpisode == null) return;
      final dy = _origin!.dy - event.localPosition.dy;
      if (dy.abs() < _viewHeight * 0.20) return;
      _episodeFired = true;
      final forward = dy > 0;
      unawaited(HapticFeedback.mediumImpact());
      final label = onEpisode!(forward ? 1 : -1);
      _showHud(SwipeAction.episode, forward ? 1 : -1, label: label);
    }
  }

  void pointerUp(PointerUpEvent event) {
    _pointers.remove(event.pointer);
    if (_cancelUntilRelease) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
      if (_pointers.isEmpty) _cancelUntilRelease = false;
      return;
    }
    if (_pointer != event.pointer || _origin == null) return;
    final delta = (_lastPosition ?? event.localPosition) - _origin!;

    if (_swipeAction == SwipeAction.seek) {
      // 提交最终的 seek 位置（与滑动预览同一套自适应步长，保证所见即所得）
      final dx = delta.dx;
      final secondsDelta = (dx / (_viewWidth * 0.33)) * _seekSecondsPerThird();
      final durationMs = player.state.duration.inMilliseconds;
      var target = (_originPositionMs + secondsDelta * 1000).round();
      if (durationMs > 0) target = target.clamp(0, durationMs);
      target = target.clamp(0, const Duration(hours: 10).inMilliseconds);
      if ((target - _originPositionMs).abs() > 100) {
        unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
      }
      _resumeAfterSeek();
      _scheduleDismissHud();
      enterQuietPeriod();
    } else if (_swipeAction == SwipeAction.brightness ||
               _swipeAction == SwipeAction.volume ||
               _swipeAction == SwipeAction.episode) {
      _scheduleDismissHud();
    }

    if (_moved || _held) {
      _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    }
    _pointer = null;
    _origin = null;
    _endHold();
  }

  void pointerCancel(PointerCancelEvent event) {
    _pointers.remove(event.pointer);
    cancel();
    _ignoreTapUntil = DateTime.now().add(const Duration(milliseconds: 600));
    if (_pointers.isEmpty) _cancelUntilRelease = false;
  }

  void _showHud(
    SwipeAction action,
    double value, {
    Duration? position,
    String? label,
  }) {
    if (_disposed) return;
    _hudTimer?.cancel();
    _hudState = GestureHudState(
      type: action,
      value: value,
      position: position,
      label: label,
    );
    notifyListeners();
  }

  void _scheduleDismissHud() {
    _hudTimer?.cancel();
    _hudTimer = Timer(const Duration(milliseconds: 1000), () {
      if (_disposed) return;
      _hudState = const GestureHudState();
      notifyListeners();
    });
  }

  void seek(int seconds) {
    if (!available() || player.state.duration <= Duration.zero) return;
    _endHold();
    final target = (player.state.position.inMilliseconds + seconds * 1000)
        .clamp(0, player.state.duration.inMilliseconds);
    unawaited((onSeek ?? player.seek)(Duration(milliseconds: target)));
    hint('${seconds > 0 ? '快进至' : '后退至'} ${formatPosition(target / 1000)}');
  }

  void changeVolume(double delta) {
    if (!available()) return;
    final volume = (player.state.volume + delta).clamp(0.0, 100.0);
    unawaited(player.setVolume(volume));
    if (volume > 0) {
      _unmutedVolume = volume;
      _volumeMemory = volume;
    }
    hint(volume == 0 ? '已静音' : '音量 ${volume.round()}%');
  }

  void toggleMute() {
    if (!available()) return;
    final current = player.state.volume;
    if (current > 0) {
      _unmutedVolume = current;
      _volumeMemory = current;
    }
    final target = current > 0 ? 0.0 : _unmutedVolume;
    unawaited(player.setVolume(target));
    hint(target == 0 ? '已静音' : '音量 ${target.round()}%');
  }

  KeyEventResult key(KeyEvent event) {
    final key = event.logicalKey;
    if (event is KeyUpEvent) {
      if (key == LogicalKeyboardKey.arrowRight && _keyboardHold) {
        _endHold(tap: available());
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    final hardware = HardwareKeyboard.instance;
    if (hardware.isAltPressed ||
        hardware.isMetaPressed ||
        hardware.isShiftPressed) {
      cancel();
      return KeyEventResult.ignored;
    }
    if (key == LogicalKeyboardKey.f11 || key == LogicalKeyboardKey.keyF) {
      if (event is KeyDownEvent && onFullscreen != null) {
        cancel();
        onFullscreen!();
      }
      return KeyEventResult.handled;
    }
    if (hardware.isControlPressed || !available()) {
      return KeyEventResult.ignored;
    }
    if (key != LogicalKeyboardKey.arrowRight) _endHold();
    if (key == LogicalKeyboardKey.arrowRight) {
      if (event is KeyDownEvent) _beginHold(keyboard: true);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      seek(-5);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      changeVolume(5);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      changeVolume(-5);
    } else if (key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      if (event is KeyDownEvent) onTogglePlayback();
    } else if (key == LogicalKeyboardKey.keyM) {
      if (event is KeyDownEvent) toggleMute();
    } else if (key == LogicalKeyboardKey.mediaTrackNext ||
        key == LogicalKeyboardKey.mediaTrackPrevious ||
        key == LogicalKeyboardKey.keyN ||
        key == LogicalKeyboardKey.keyP ||
        key == LogicalKeyboardKey.pageDown ||
        key == LogicalKeyboardKey.pageUp) {
      if (event is KeyDownEvent && onEpisode != null) {
        final next = key == LogicalKeyboardKey.mediaTrackNext ||
            key == LogicalKeyboardKey.keyN ||
            key == LogicalKeyboardKey.pageDown;
        hint(onEpisode!(next ? 1 : -1));
      }
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  void dispose() {
    _disposed = true;
    _holdTimer?.cancel();
    _hintTimer?.cancel();
    _hudTimer?.cancel();
    _rateEaseTimer?.cancel();
    if (_boosting) unawaited(_setRate(baseSpeed()));
    _boosting = false;
    _playing.cancel();
    _pointers.clear();
    super.dispose();
  }
}
