import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'app_layout.dart';

class AppOrientationController {
  AppOrientationController({required bool television})
    : _television = television;

  bool _television;
  bool _disposed = false;
  bool? _nativeTelevision;
  Object? _playbackOwner;
  List<DeviceOrientation> _playbackOrientations = DeviceOrientation.values;
  /// 锁屏期间锁定的方向集合：非 null 时只允许这些方向，
  /// 旋转物理设备画面也不跟随。null = 不锁（跟随系统）。
  List<DeviceOrientation>? _lockedOrientations;
  List<DeviceOrientation>? _appliedOrientations;
  Future<void> _pending = Future<void>.value();

  static List<DeviceOrientation> orientations({
    required bool television,
    bool fullscreen = false,
    double aspectRatio = 1,
    bool forceLandscape = false,
    bool forcePortrait = false,
  }) {
    if (television) {
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    if (!fullscreen) return DeviceOrientation.values;
    // 竖屏全屏优先于比例判定：长剧（aspectRatio ≥ 1）也能竖屏沉浸，
    // 否则一进全屏就被锁成横屏。
    if (forcePortrait) {
      return const [
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ];
    }
    if (forceLandscape || aspectRatio >= 1) {
      return const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ];
    }
    return const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ];
  }

  Future<void> setTelevision(bool television) {
    if (_television != television) {
      _television = television;
      _playbackOwner = null;
      _playbackOrientations = DeviceOrientation.values;
    }
    return _apply();
  }

  Future<void> setPlayback(
    Object owner, {
    required bool fullscreen,
    required double aspectRatio,
    bool forceLandscape = false,
    bool forcePortrait = false,
  }) async {
    final previousOwner = _playbackOwner;
    final previousOrientations = _playbackOrientations;
    if (!_television) {
      _playbackOwner = owner;
      _playbackOrientations = orientations(
        television: false,
        fullscreen: fullscreen,
        aspectRatio: aspectRatio,
        forceLandscape: forceLandscape,
        forcePortrait: forcePortrait,
      );
    }
    final requested = _playbackOrientations;
    try {
      await _apply();
    } catch (_) {
      if (!_disposed &&
          !_television &&
          identical(_playbackOwner, owner) &&
          identical(_playbackOrientations, requested)) {
        _playbackOwner = previousOwner;
        _playbackOrientations = previousOrientations;
      }
      rethrow;
    }
  }

  Future<void> releasePlayback(Object owner) {
    if (_television) return refresh();
    if (!identical(_playbackOwner, owner)) return Future<void>.value();
    _playbackOwner = null;
    _playbackOrientations = DeviceOrientation.values;
    // 播放器交还方向控制权时，锁屏钉住的方向必须一起松开，
    // 否则离开播放页后整个 App 的方向都被锁住。
    _lockedOrientations = null;
    return _apply();
  }

  /// 锁定/解除屏幕方向：传入锁定期间允许的方向集合（null = 恢复跟随）。
  /// 锁定期间 setPlayback 的方向计算被忽略。
  Future<void> lockOrientations(List<DeviceOrientation>? orientations) {
    if (listEquals(_lockedOrientations, orientations)) return _pending;
    _lockedOrientations = orientations;
    return _apply(force: true);
  }

  Future<void> refresh() => _apply(force: true);

  Future<void> _apply({bool force = false}) {
    final next = _pending.catchError((Object _) {}).then((_) async {
      if (_disposed ||
          kIsWeb ||
          (defaultTargetPlatform != TargetPlatform.android &&
              defaultTargetPlatform != TargetPlatform.iOS)) {
        return;
      }
      final television = _television;
      if (defaultTargetPlatform == TargetPlatform.android &&
          (force || _nativeTelevision != television)) {
        try {
          await AppDevice.channel.invokeMethod<void>('setTelevisionMode', {
            'enabled': television,
          });
          _nativeTelevision = television;
        } on MissingPluginException {
          _nativeTelevision = null;
        }
      }
      if (_disposed || television != _television) return;
      final preferred = television
          ? orientations(television: true)
          : (_lockedOrientations ?? _playbackOrientations);
      if (force || !listEquals(preferred, _appliedOrientations)) {
        await SystemChrome.setPreferredOrientations(preferred);
        if (!_disposed) _appliedOrientations = preferred;
      }
    });
    _pending = next;
    return next;
  }

  void dispose() {
    _disposed = true;
  }
}

class AppOrientationScope extends StatefulWidget {
  const AppOrientationScope({
    super.key,
    required this.television,
    required this.child,
  });

  final bool television;
  final Widget child;

  static AppOrientationController? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_OrientationScope>()
      ?.controller;

  @override
  State<AppOrientationScope> createState() => _AppOrientationScopeState();
}

class _AppOrientationScopeState extends State<AppOrientationScope>
    with WidgetsBindingObserver {
  late final _controller = AppOrientationController(
    television: widget.television,
  );

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _apply(_controller.refresh());
  }

  @override
  void didUpdateWidget(covariant AppOrientationScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.television != widget.television) {
      _apply(_controller.setTelevision(widget.television));
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _apply(_controller.refresh());
  }

  void _apply(Future<void> operation) {
    unawaited(
      operation.catchError((Object error, StackTrace stack) {
        FlutterError.reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stack,
            library: 'app orientation',
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      _OrientationScope(controller: _controller, child: widget.child);
}

class _OrientationScope extends InheritedWidget {
  const _OrientationScope({required this.controller, required super.child});

  final AppOrientationController controller;

  @override
  bool updateShouldNotify(_OrientationScope oldWidget) =>
      controller != oldWidget.controller;
}
