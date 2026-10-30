import 'dart:async';

import 'package:duanju_app/models.dart';
import 'package:media_kit/media_kit.dart';

import 'fixtures.dart';

class ScriptedPlayer extends PlatformPlayer {
  ScriptedPlayer() : super(configuration: const PlayerConfiguration());
  final opened = <Media>[];
  final played = <bool>[];
  bool disposed = false;
  final rates = <double>[];
  int stops = 0;
  int pauses = 0;
  /// 模拟死链：url 含 'dead' 时 open 后只发 START_FILE（playing+buffering），
  /// 之后无任何事件（不缓冲完成、不出画、不报错）——用于 12s watchdog 用例。
  @override
  Future<void> open(Playable playable, {bool play = true}) async {
    final media = playable as Media;
    opened.add(media);
    played.add(play);
    // 模拟 MPV_EVENT_START_FILE：拉流前先发 playing=true + buffering=true，
    // 直到真正解码出画（core-idle=0）才落 buffering=false。
    final hang = media.uri.contains('dead');
    final failed = !hang && media.uri.contains('broken');
    state = state.copyWith(
      position: failed ? Duration.zero : media.start ?? Duration.zero,
      duration: failed ? Duration.zero : const Duration(minutes: 2),
      playing: play,
      completed: false,
      buffering: true,
      width: failed ? 0 : 320,
      height: failed ? 0 : 180,
    );
    positionController.add(state.position);
    durationController.add(state.duration);
    playingController.add(play);
    bufferingController.add(true);
    if (hang) {
      return;
    }
    if (failed) {
      fail();
      return;
    }
    state = state.copyWith(buffering: false);
    bufferingController.add(false);
  }

  void fail() {
    errorController.add('synthetic network failure');
    errorController.add('synthetic decoder failure');
  }

  /// 模拟媒体事件：出画（buffering=false）。包装 protected 流，测试注入用。
  void injectBuffering(bool buffering) {
    state = state.copyWith(buffering: buffering);
    bufferingController.add(buffering);
  }

  @override
  Future<void> stop() async {
    stops++;
    state = state.copyWith(
      position: Duration.zero,
      duration: Duration.zero,
      playing: false,
      buffering: false,
      width: 0,
      height: 0,
    );
    positionController.add(Duration.zero);
    playingController.add(false);
  }

  @override
  Future<void> seek(Duration duration) async {
    state = state.copyWith(position: duration);
    positionController.add(duration);
  }

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
    state = state.copyWith(rate: rate);
    rateController.add(rate);
  }

  @override
  Future<void> setVolume(double volume) async {
    state = state.copyWith(volume: volume);
    volumeController.add(volume);
  }

  void finishEpisode() {
    state = state.copyWith(
      position: state.duration,
      completed: true,
      playing: false,
    );
    positionController.add(state.position);
    completedController.add(true);
    playingController.add(false);
  }

  /// 测试用：把播放位置推到 [position] 并广播事件（包装 protected 的流）。
  void pushPosition(Duration position) {
    state = state.copyWith(position: position);
    positionController.add(position);
  }

  void videoSize(int width, int height) {
    videoParamsController.add(
      VideoParams(w: width, h: height, dw: width, dh: height),
    );
  }

  @override
  Future<void> pause() async {
    pauses++;
    state = state.copyWith(playing: false);
    playingController.add(false);
  }

  @override
  Future<void> play() async {
    state = state.copyWith(playing: true);
    playingController.add(true);
  }

  @override
  Future<void> playOrPause() async {
    state = state.copyWith(playing: !state.playing);
    playingController.add(state.playing);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await super.dispose();
  }
}

class RouteRepository extends FixtureRepository {
  int primaryCalls = 0;
  int fallbackCalls = 0;
  int selectCalls = 0;
  final requestedQualities = <int>[];
  final requestedEpisodes = <int>[];
  final selectedRoutes = <int>[];
  bool broken = false;
  bool deferFallback = false;
  bool deferResolve = false;
  bool deferSelect = false;
  final active = <String>{};
  Completer<PlaybackPlan>? pending;
  Completer<PlaybackPlan>? pendingResolve;

  /// 线路表可由用例覆写：默认两条无官方标记的线路（面板平铺），
  /// 需要验证官方/第三方分组时改成带 routeOfficial 的多线表。
  List<String> routeLabels = const ['无水印资源', '索尼资源'];
  List<bool> routeOfficial = const [];

  /// 初始线路索引（默认 0 = 第一条）：用例可设成 routeCount-1 模拟
  /// 「当前已在最后一条线路」——线路入口必须仍在（旧实现按 hasAlternative
  /// 判定，最后一条时入口整个消失，用户再也切不回来）。
  int initialRouteIndex = 0;

  /// 站点画质档位可由用例覆写：默认带两档；置成 `quality = 0` 且
  /// `qualities = const []` 模拟「站点根本没有画质档位」的源。
  int quality = 1080;
  List<int> qualities = const [1080, 720];

  PlaybackPlan plan(bool alternate, {int route = -1}) {
    final session = 'route-${primaryCalls + fallbackCalls + selectCalls}';
    active.add(session);
    final index = route >= 0 ? route : (alternate ? 1 : initialRouteIndex);
    return PlaybackPlan(
      url: 'https://media.test/${broken ? 'broken' : 'working'}-$session.mp4',
      session: session,
      routeIndex: index,
      routeCount: routeLabels.length,
      routeLabels: routeLabels,
      routeOfficial: routeOfficial,
      quality: quality,
      qualities: qualities,
    );
  }

  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    primaryCalls++;
    requestedQualities.add(quality);
    requestedEpisodes.add(episode.number);
    if (deferResolve) {
      pendingResolve = Completer<PlaybackPlan>();
      return pendingResolve!.future;
    }
    return plan(false);
  }

  /// 放行被 deferResolve 挂起的解析。
  void completePendingPlan() {
    pendingResolve?.complete(plan(false));
  }

  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async {
    fallbackCalls++;
    if (deferFallback) {
      pending = Completer<PlaybackPlan>();
      return pending!.future;
    }
    return plan(true);
  }

  @override
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route) async {
    selectCalls++;
    selectedRoutes.add(route);
    if (deferSelect) {
      pending = Completer<PlaybackPlan>();
      return pending!.future;
    }
    return plan(false, route: route);
  }

  @override
  Future<void> release(String session) async {
    active.remove(session);
  }
}
