import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'live_models.dart';
import 'live_route_memory.dart';

/// 直播播放页（2026-10-22 二轮重构）：对标主流电视直播 App 的交互形态——
/// ①整页全屏播放，点画面唤出/隐藏控制层（3.5 秒自动隐藏）；
/// ②上下滑动换台（上滑下一台、下滑上一台），换台带中央 OSD 提示；
/// ③右侧滑出频道列表浮层（分组 chips + 频道列表，当前台高亮，点选即播）；
/// ④底部操作行：上一台 / 频道列表 / 线路切换 / 下一台。
/// 不进 DramaDetail/PlaybackPlan 解析链，直接用 mpv 播频道 m3u 直链；
/// 同名频道多线路按序自动重试。
/// 2026-10-23 三轮（修「加载时一片黑」）：
/// ①加载态改由 buffering 流驱动出画判定——media_kit 在 MPV_EVENT_START_FILE
///   （拉流前）就发 playing=true+buffering=true，直到 core-idle=0（真正解码
///   出画）才落 buffering=false；只听 playing 会在拉流黑屏期提前撤掉转圈；
/// ②打开阶段的 error 延迟确认再切线（stop→open 竞态窗口内的事件视为旧流
///   噪声丢弃；确认期出画则取消；防打开失败被一票忽略后黑屏+转圈卡死）；
/// ③12s 无画面兜底强制切下一线路（连 error 都不发的死链），加载期显示
///   频道名与线路号。
/// 2026-10-31（修「换线路太快把真连接跳过去」）：加载期切线过于激进——
/// 旧实现只要收到 error 就开固定 1.2s 确认窗，1.2s 内没出画立即切走，
/// 而直播源（尤其跨网 HLS、需要先重定向的分发域名）拉首帧常要 3-6 秒，
/// 于是「明明能播的线路被当成死链跳过」；而且旧实现给线路打的一次性
/// attempted 标记一旦落下就不再回头，被误杀的这条好线路本轮再也回不来。
/// 修法三条：
/// ①每条线路给足最短观察窗 [routeGrace]，此窗内的 error 只算怀疑，
///   确认时刻不早于该窗结束（窗内出画照旧立即取消）；
/// ②播放途中出现的抖动同样走确认窗，窗内恢复即丢弃，不再当场切线；
/// ③全部线路走完一轮后，对「没有明确报错、只是 12s 无画面被兜底切掉」
///   的线路回头再给一次机会（明确报错的不重复等，避免失败反馈变慢）。
/// 2026-10-31 四轮（修「看着看着卡住不动没人管」）：出画后的中途卡流原本
/// 没有任何兜底——12s 无画面兜底与打开确认窗都只在 _loading 期生效，
/// _checkFrame 出画一次就把它们取消，之后直播源卡在 buffering 会永久转圈。
/// 补一条中途卡流 watchdog：出过画后 buffering 持续 _stallTimeout 未恢复
/// 即切下一线路（卡流线路不算「明确报错」，走完一轮后仍能回头重试）。
class LivePlayerScreen extends StatefulWidget {
  const LivePlayerScreen({
    super.key,
    required this.channels,
    this.initialIndex = 0,
    this.listId = '',
    this.playerFactory,
    this.videoBuilder,
  });
  /// 单条线路的最短观察窗：即使收到 error，确认切线的时刻也不早于此窗
  /// 结束（2026-10-31）——直播源拉首帧常要 3-6 秒，短于此窗口=把能看的
  /// 线路误判为死链切走。窗内出画照旧立即取消切线。
  @visibleForTesting
  static const routeGrace = Duration(seconds: 5);

  final List<LiveChannel> channels;
  final int initialIndex;
  /// 线路记忆的列表键：进台优先用上次手动选中的线路（见 LiveRouteMemory）。
  final String listId;
  @visibleForTesting
  final Player Function()? playerFactory;
  @visibleForTesting
  final Widget Function(Widget controls)? videoBuilder;
  @override
  State<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<LivePlayerScreen> {
  static const _autoHide = Duration(milliseconds: 3500);
  static const _osdDuration = Duration(milliseconds: 1600);
  /// 无画面兜底：连 error 都不发的死链（防火墙拦截/域名失效）超时后强制切线。
  static const _frameTimeout = Duration(seconds: 12);
  /// 打开阶段 error 的延迟确认窗：窗口内出画 = stop→open 竞态旧噪声，丢弃。
  static const _failureConfirm = Duration(milliseconds: 1200);
  /// 中途卡流兜底（2026-10-31）：出过画后 buffering 持续超过此值仍未恢复出画
  /// 即视为这条线路卡死，切下一线路——播放途中卡住同样需要兜底。
  static const _stallTimeout = Duration(seconds: 12);
  /// 每条线路最多尝试次数：第二轮只回头重试「没有明确报错」的线路。
  static const _maxRouteAttempts = 2;

  late final Player _player;
  /// 注入 videoBuilder（测试桩替代整个 Video 面）时不构造真 VideoController。
  late final VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late int _index;
  int _urlIndex = 0;
  bool _loading = true;
  bool _failed = false;
  /// 每条线路已尝试次数（第二轮回头重试依赖它判定的预算）。
  final Map<int, int> _attempts = <int, int>{};
  /// 确认窗内确认失败的线路：这些线路报错明确，不再重复排队等待。
  final Set<int> _errored = <int>{};
  int _generation = 0;
  bool _closed = false;
  Timer? _frameTimer;
  Timer? _failureTimer;
  /// 中途卡流 watchdog：仅在本条线路曾出过画（[_sawFrame]）后 arm。
  Timer? _stallTimer;
  /// 本条线路是否已出过画：中途卡流兜底只对付「看着看着卡住」，
  /// 首帧期仍交给无画面兜底与确认窗，避免两条 watchdog 互相打架。
  bool _sawFrame = false;
  /// 最短观察窗倒计时：每条线路打开即启动，到点前收到的 error 只标记怀疑。
  Timer? _graceTimer;
  bool _graceElapsed = false;
  /// 观察窗内是否收到过 error（含上一条线路 stop→open 竞态带来的旧噪声）。
  bool _suspicious = false;

  bool _controlsVisible = true;
  bool _panelOpen = false;
  String _panelGroup = '';
  String _osd = '';
  Timer? _hideTimer;
  Timer? _osdTimer;
  double _dragAccum = 0;

  @override
  void initState() {
    super.initState();
    _index = widget.channels.isEmpty
        ? 0
        : widget.initialIndex.clamp(0, widget.channels.length - 1);
    _player = widget.playerFactory?.call() ?? Player();
    _controller = widget.videoBuilder == null ? VideoController(_player) : null;
    // 出画判定：playing && !buffering。media_kit 在拉流前就发
    // playing=true+buffering=true（MPV_EVENT_START_FILE），直到真正解码出画
    // （core-idle=0）才落 buffering=false；只听 playing 会在拉流黑屏期
    // 提前撤掉转圈。
    _subscriptions.add(
      _player.stream.playing.listen((playing) {
        if (playing) _checkFrame();
      }),
    );
    _subscriptions.add(
      _player.stream.buffering.listen((buffering) {
        if (_closed || !mounted) return;
        if (buffering) {
          if (!_loading && !_failed) {
            // 出画后中途缓冲：恢复加载提示，避免卡顿期无反馈。
            setState(() => _loading = true);
          }
          // 中途卡流兜底：已出过画的线路卡在缓冲，超时无恢复即切线。
          _armStallWatchdog();
        }
        _checkFrame();
      }),
    );
    _subscriptions.add(
      _player.stream.error.listen((_) => _handleFailure()),
    );
    _openInitial();
    _scheduleHide();
  }

  @override
  void dispose() {
    _closed = true;
    _hideTimer?.cancel();
    _osdTimer?.cancel();
    _frameTimer?.cancel();
    _graceTimer?.cancel();
    _failureTimer?.cancel();
    _stallTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _player.dispose();
    super.dispose();
  }

  List<LiveChannel> get _channels => widget.channels;
  LiveChannel get _channel =>
      _channels.isEmpty ? const LiveChannel(name: '') : _channels[_index];

  /// 进台选线：优先用上次手动选中的线路（按 URL 匹配回当前 urls 数组），
  /// 无记忆或记忆线路已被列表更新挤掉时回落线路 1。
  void _openInitial() {
    var start = 0;
    final remembered = LiveRouteMemory.recall(widget.listId, _channel.name);
    if (remembered != null && remembered.isNotEmpty) {
      final idx = _channel.urls.indexOf(remembered);
      if (idx > 0) start = idx;
    }
    _open(start);
  }

  void _open(int urlIdx) {
    if (_closed) return;
    final urls = _channel.urls;
    if (urlIdx < 0 || urlIdx >= urls.length) {
      _setFailed();
      return;
    }
    _urlIndex = urlIdx;
    _attempts[urlIdx] = (_attempts[urlIdx] ?? 0) + 1;
    final ticket = ++_generation;
    _failureTimer?.cancel();
    _failureTimer = null;
    _frameTimer?.cancel();
    // 换线路即作废上一条的中途卡流 watchdog 与出画标记：新线路首帧期
    // 仍交给无画面兜底与确认窗，不与中途兜底打架。
    _stallTimer?.cancel();
    _stallTimer = null;
    _sawFrame = false;
    // 最短观察窗：此窗内的 error 只标记为怀疑，到点仍在拉流才真正确认
    // 失败——给慢速但可用的直播源留足首帧时间。出画立即取消该倒计时。
    _graceTimer?.cancel();
    _graceElapsed = false;
    _suspicious = false;
    _graceTimer = Timer(LivePlayerScreen.routeGrace, _onGraceElapsed);
    // 12s 无画面兜底：有的死链连 error 都不发，watchdog 强制切线
    //（若此时已有 error 进确认窗则让确认窗处理）。
    _frameTimer = Timer(_frameTimeout, () {
      if (!_closed && mounted && ticket == _generation && _failureTimer == null) {
        _switchOrFail();
      }
    });
    setState(() {
      _loading = true;
      _failed = false;
    });
    _openUrl(urls[urlIdx], ticket);
  }

  Future<void> _openUrl(String url, int ticket) async {
    try {
      await _player.stop();
      await _player.open(Media(url), play: true);
    } catch (_) {
      if (!_closed && ticket == _generation) _handleFailure();
    }
  }

  /// 中途卡流兜底：本条线路已出过画（[_sawFrame]）且当前仍在缓冲时，
  /// 启动 [_stallTimeout] 倒计时；到点仍卡在缓冲即视为线路卡死，切下一线路。
  /// 已出画的线路不再受 12s 无画面兜底保护，缺了这条会永久转圈。
  /// 反复调用是幂等的：已有倒计时在跑就不再重启（只认「首次进入缓冲」）。
  void _armStallWatchdog() {
    if (_closed || !mounted || !_sawFrame) return;
    if (_stallTimer != null) return;
    final ticket = _generation;
    _stallTimer = Timer(_stallTimeout, () {
      _stallTimer = null;
      if (_closed || !mounted || ticket != _generation) return;
      // 期间已恢复出画（_checkFrame 会取消倒计时）或已停播，不动作。
      if (!_player.state.playing || !_player.state.buffering) return;
      _switchOrFail();
    });
  }

  /// 出画判定：正在播放且不在缓冲 = 有画面。
  /// 清掉加载/失败提示，并撤销打开阶段的失败确认与 12s 兜底。
  void _checkFrame() {
    if (_closed || !mounted) return;
    if (!_player.state.playing || _player.state.buffering) return;
    _frameTimer?.cancel();
    // 出画即撤销中途卡流 watchdog：缓冲期已结束，避免残留的倒计时误切。
    _stallTimer?.cancel();
    _stallTimer = null;
    // 本条线路已出过画：此后若卡在缓冲，由中途 watchdog 兜底。
    _sawFrame = true;
    _graceTimer?.cancel();
    _graceTimer = null;
    // 已经出过画的线路视为观察窗已用尽：之后再次报错（播放途中抖动）
    // 回到 1.2s 竞态确认窗，不再白等一个最短观察窗。
    _graceElapsed = true;
    _suspicious = false;
    if (_failureTimer != null) {
      _failureTimer!.cancel();
      _failureTimer = null;
    }
    if (_loading || _failed) {
      setState(() {
        _loading = false;
        _failed = false;
      });
    }
  }

  /// 出错走确认窗再切下一线路；全部线路都试过才落失败态。
  /// 打开阶段（仍在转圈）的 error 进入延迟确认——播放器启动链路里
  /// stop→open 竞态会带来上一条线路的旧 error，立即切线会误杀刚打开的
  /// 正常线路；确认窗内出画则丢弃。确认期内转圈保持，不黑屏。
  /// 观察窗 [routeGrace] 内收到的 error 一律标记怀疑、不立刻排队确认，
  /// 等到 [_onGraceElapsed] 到点仍在拉流才确认真失败——慢速但可用的直播源
  /// 因此不会被提前判死；观察窗已用尽（出过画或窗自然到期）的线路回到
  /// 1.2s 竞态窗，播放途中的瞬时抖动同样不再当场切线。
  void _handleFailure() {
    if (_closed || !mounted) return;
    if (_failureTimer != null) return;
    _suspicious = true;
    // 观察窗未结束：先不动，等 [_onGraceElapsed] 到点再判。若这条线路
    // 只是慢（窗内拉完首帧出画），出画路径会先一步把等待撤销。
    if (!_graceElapsed) return;
    _failureTimer = Timer(_failureConfirm, _confirmFailure);
  }

  /// 最短观察窗到点：这条线路拿到过完整首帧时间窗仍未出画，若期间收到过
  /// error 则确认真失败。
  void _onGraceElapsed() {
    _graceTimer = null;
    _graceElapsed = true;
    if (_closed || !mounted) return;
    if (!_suspicious) return;
    _confirmFailure();
  }

  void _confirmFailure() {
    _failureTimer = null;
    if (_closed || !mounted) return;
    if (_player.state.playing && !_player.state.buffering) return;
    _errored.add(_urlIndex);
    _switchOrFail();
  }

  void _switchOrFail() {
    final urls = _channel.urls;
    for (var i = 0; i < urls.length; i++) {
      if (!_attempts.containsKey(i)) {
        _open(i);
        return;
      }
    }
    // 第二轮：只回头重试「没有明确报错、疑似被 12s 无画面兜底误杀」的
    // 线路。直播源的慢连接最常死在这条路径上，值得再给一次机会；已确认
    // 报错的线路不重复排队，避免把失败反馈拖成两轮全等待。
    for (var i = 0; i < urls.length; i++) {
      if (i != _urlIndex &&
          !_errored.contains(i) &&
          (_attempts[i] ?? 0) < _maxRouteAttempts) {
        _open(i);
        return;
      }
    }
    _setFailed();
  }

  void _setFailed() {
    if (_closed || !mounted) return;
    _frameTimer?.cancel();
    _graceTimer?.cancel();
    _graceTimer = null;
    _failureTimer?.cancel();
    _failureTimer = null;
    _stallTimer?.cancel();
    _stallTimer = null;
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  void _retry() {
    setState(() {
      _attempts.clear();
      _errored.clear();
    });
    _open(_urlIndex);
  }

  void _switchRoute(int index) {
    if (index == _urlIndex || index < 0 || index >= _channel.urls.length) {
      return;
    }
    setState(() {
      _attempts.clear();
      _errored.clear();
    });
    // 手动选线才写记忆：这条线路用户亲测能看，下次进台直接用它。
    unawaited(
      LiveRouteMemory.remember(
        widget.listId,
        _channel.name,
        _channel.urls[index],
      ),
    );
    _showOsd('线路 ${index + 1} · 已记住');
    _open(index);
  }

  /// 换到指定频道：重置线路状态并带 OSD 提示。
  void _playChannel(int index) {
    if (index < 0 || index >= _channels.length || index == _index) {
      return;
    }
    setState(() {
      _index = index;
      _attempts.clear();
      _errored.clear();
      _urlIndex = 0;
    });
    _showOsd('${index + 1}  ${_channel.name}');
    _openInitial();
  }

  void _stepChannel(int delta) {
    if (_channels.isEmpty) return;
    var next = (_index + delta) % _channels.length;
    if (next < 0) next += _channels.length;
    _playChannel(next);
  }

  void _showOsd(String text) {
    setState(() => _osd = text);
    _osdTimer?.cancel();
    _osdTimer = Timer(_osdDuration, () {
      if (mounted) setState(() => _osd = '');
    });
  }

  void _toggleControls() {
    setState(() {
      _controlsVisible = !_controlsVisible;
      if (!_controlsVisible) _panelOpen = false;
    });
    if (_controlsVisible) {
      _scheduleHide();
    } else {
      _hideTimer?.cancel();
    }
  }

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(_autoHide, () {
      if (mounted && _controlsVisible && !_panelOpen) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  void _openPanel() {
    setState(() {
      _panelOpen = true;
      _controlsVisible = true;
      _panelGroup = _groupLabel(_channel);
    });
    _hideTimer?.cancel();
  }

  void _closePanel() {
    setState(() => _panelOpen = false);
    _scheduleHide();
  }

  /// 速度为主、拖动距离兜底：慢速拖出足量距离也应换台
  ///（widget 测试的 move 事件同一时间戳，速度恒为 0，只能走距离判据）。
  void _onVerticalDragUpdate(DragUpdateDetails details) {
    _dragAccum += details.primaryDelta ?? 0;
  }

  void _onVerticalDragEnd(DragEndDetails details) {
    final v = details.primaryVelocity ?? 0;
    const distance = 72.0;
    final up = v < -120 || _dragAccum < -distance; // 上滑 = 下一台
    final down = v > 120 || _dragAccum > distance; // 下滑 = 上一台
    _dragAccum = 0;
    if (up) {
      _stepChannel(1);
    } else if (down) {
      _stepChannel(-1);
    }
  }

  static String _groupLabel(LiveChannel channel) {
    final g = channel.group.trim();
    return g.isEmpty ? '未分组' : g;
  }

  List<String> get _panelGroups {
    final names = <String>{};
    for (final c in _channels) {
      names.add(_groupLabel(c));
    }
    return names.toList();
  }

  List<int> get _panelIndexes {
    final indexes = <int>[];
    for (var i = 0; i < _channels.length; i++) {
      if (_panelGroup.isEmpty || _groupLabel(_channels[i]) == _panelGroup) {
        indexes.add(i);
      }
    }
    return indexes;
  }

  @override
  Widget build(BuildContext context) {
    final controls = _buildControls();
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.videoBuilder != null)
            widget.videoBuilder!(controls)
          else
            Video(
              controller: _controller!,
              fit: BoxFit.contain,
              controls: (_) => controls,
            ),
        ],
      ),
    );
  }

  Widget _buildControls() {
    return Stack(
      children: [
        // 底层手势层：点画面切换控制层，上下滑换台。
        Positioned.fill(
          child: GestureDetector(
            key: const Key('live-player-gesture'),
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onVerticalDragUpdate: _onVerticalDragUpdate,
            onVerticalDragEnd: _onVerticalDragEnd,
          ),
        ),
        // 换台 OSD。
        IgnorePointer(
          child: Center(
            child: AnimatedOpacity(
              opacity: _osd.isEmpty ? 0 : 1,
              duration: const Duration(milliseconds: 180),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 22,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.62),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  _osd,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ),
        ),
        // 中央状态（loading / failed）。
        Center(
          child: _failed
              ? _failureCard()
              : _loading
              ? _loadingCard()
              : const SizedBox.shrink(),
        ),
        // 控制层。
        if (_controlsVisible) ..._chromeBars(),
        // 右侧频道列表浮层。
        _channelPanel(),
      ],
    );
  }

  /// 加载卡片：转圈 + 频道名与线路号，拉流黑屏期有明确反馈。
  Widget _loadingCard() {
    final urls = _channel.urls;
    final route = urls.length > 1 ? ' · 线路 ${_urlIndex + 1}' : '';
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const CircularProgressIndicator(),
        const SizedBox(height: 14),
        Text(
          '正在加载「${_channel.name}」$route',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }

  Widget _failureCard() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.live_tv, color: Colors.white54, size: 44),
        const SizedBox(height: 12),
        Text(
          '「${_channel.name}」播放失败',
          style: const TextStyle(color: Colors.white70),
        ),
        const SizedBox(height: 4),
        if (_channel.urls.length > 1)
          Text(
            '已尝试全部 ${_channel.urls.length} 条线路',
            style: const TextStyle(color: Colors.white38, fontSize: 12),
          ),
        const SizedBox(height: 16),
        FilledButton.icon(
          key: const Key('live-player-retry'),
          onPressed: _retry,
          icon: const Icon(Icons.refresh),
          label: const Text('重试'),
        ),
      ],
    );
  }

  List<Widget> _chromeBars() {
    return [
      // 顶部：返回 + 台标 + 频道名 + 分组。
      Positioned(
        top: 0,
        left: 0,
        right: 0,
        child: GestureDetector(
          onTap: () {}, // 吃掉点击，避免透传到手势层误隐藏。
          child: DecoratedBox(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.black87, Colors.transparent],
              ),
            ),
            child: SafeArea(
              bottom: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Row(
                  children: [
                    IconButton(
                      key: const Key('live-player-back'),
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).maybePop(),
                      tooltip: '返回',
                    ),
                    Expanded(
                      child: Text(
                        _channel.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (_channel.group.trim().isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Text(
                          _groupLabel(_channel),
                          style: const TextStyle(
                            color: Colors.white54,
                            fontSize: 12,
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
        // 底部操作行：上一台 / 频道列表 / 线路 / 下一台。
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: GestureDetector(
            onTap: () {},
            child: DecoratedBox(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 24, 8, 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _barButton(
                        key: const Key('live-player-prev'),
                        icon: Icons.skip_previous,
                        label: '上一台',
                        onTap: () => _stepChannel(-1),
                      ),
                      _barButton(
                        key: const Key('live-player-channels'),
                        icon: Icons.grid_view_rounded,
                        label: '频道列表',
                        onTap: _openPanel,
                      ),
                      if (_channel.urls.length > 1)
                        PopupMenuButton<int>(
                          key: const Key('live-player-routes'),
                          tooltip: '切换线路',
                          initialValue: _urlIndex,
                          color: const Color(0xEE1C1C1E),
                          onSelected: _switchRoute,
                          itemBuilder: (context) => [
                            for (var i = 0; i < _channel.urls.length; i++)
                              PopupMenuItem(
                                value: i,
                                child: Text(
                                  '线路 ${i + 1}${LiveRouteMemory.recall(
                                            widget.listId,
                                            _channel.name,
                                          ) ==
                                              _channel.urls[i] &&
                                          i != _urlIndex
                                      ? ' · 已记住'
                                      : ''}',
                                  style: TextStyle(
                                    color: i == _urlIndex
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ),
                          ],
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.14),
                              borderRadius: BorderRadius.circular(18),
                            ),
                            child: Text(
                              '线路 ${_urlIndex + 1}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      _barButton(
                        key: const Key('live-player-next'),
                        icon: Icons.skip_next,
                        label: '下一台',
                        onTap: () => _stepChannel(1),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ];
  }

  Widget _barButton({
    required Key key,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      key: key,
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white, size: 24),
            const SizedBox(height: 2),
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  Widget _channelPanel() {
    final width = _panelOpen
        ? math.min(320.0, MediaQuery.sizeOf(context).width * 0.78)
        : 0.0;
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: IgnorePointer(
        ignoring: !_panelOpen,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          width: width,
          onEnd: () {
            // 收合完成后如面板已关且控制层还亮着，恢复自动隐藏节奏。
            if (!_panelOpen && _controlsVisible) _scheduleHide();
          },
          // 底色放在 Material 上：带背景色的 DecoratedBox 包 ListTile 会触发
          // debug 断言（水波纹不可见）并中断面板渲染。
          child: Material(
            color: const Color(0xF2101013),
            child: _panelOpen ? _panelBody() : const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }

  Widget _panelBody() {
    final groups = _panelGroups;
    final indexes = _panelIndexes;
    return SafeArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 8, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '频道列表 · ${_channels.length}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('live-panel-close'),
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: _closePanel,
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          SizedBox(
            height: 44,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              children: [
                for (final g in groups)
                  Padding(
                    key: Key('live-panel-group-$g'),
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(g),
                      selected: _panelGroup == g,
                      labelStyle: TextStyle(
                        fontSize: 12,
                        color: _panelGroup == g
                            ? Colors.white
                            : Colors.white70,
                      ),
                      selectedColor: const Color(0xFF4C6FFF),
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      showCheckmark: false,
                      onSelected: (_) => setState(() => _panelGroup = g),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: indexes.isEmpty
                ? const Center(
                    child: Text(
                      '该分组暂无频道',
                      style: TextStyle(color: Colors.white38, fontSize: 13),
                    ),
                  )
                : ListView.builder(
                    key: const Key('live-panel-list'),
                    padding: const EdgeInsets.only(bottom: 12),
                    itemCount: indexes.length,
                    itemBuilder: (context, row) {
                      final i = indexes[row];
                      final channel = _channels[i];
                      final current = i == _index;
                      return ListTile(
                        key: Key('live-panel-item-$i'),
                        dense: true,
                        selected: current,
                        selectedTileColor: const Color(0x334C6FFF),
                        leading: channel.logo.isNotEmpty
                            ? Image.network(
                                channel.logo,
                                width: 34,
                                height: 22,
                                fit: BoxFit.contain,
                                errorBuilder: (_, _, _) =>
                                    const SizedBox(width: 34),
                              )
                            : Container(
                                width: 34,
                                alignment: Alignment.center,
                                child: Text(
                                  channel.name.characters.isEmpty
                                      ? '?'
                                      : channel.name.characters.first,
                                  style: TextStyle(
                                    color: current
                                        ? const Color(0xFF8FA8FF)
                                        : Colors.white38,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                        title: Text(
                          channel.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: current
                                ? const Color(0xFF8FA8FF)
                                : Colors.white,
                            fontSize: 14,
                            fontWeight: current
                                ? FontWeight.w700
                                : FontWeight.w400,
                          ),
                        ),
                        subtitle: channel.urls.length > 1
                            ? Text(
                                '${channel.urls.length} 条线路',
                                style: const TextStyle(
                                  color: Colors.white38,
                                  fontSize: 11,
                                ),
                              )
                            : null,
                        onTap: () {
                          _playChannel(i);
                          _closePanel();
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
