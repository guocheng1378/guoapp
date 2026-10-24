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
class LivePlayerScreen extends StatefulWidget {
  const LivePlayerScreen({
    super.key,
    required this.channels,
    this.initialIndex = 0,
    this.listId = '',
    this.playerFactory,
    this.videoBuilder,
  });
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

  late final Player _player;
  /// 注入 videoBuilder（测试桩替代整个 Video 面）时不构造真 VideoController。
  late final VideoController? _controller;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  late int _index;
  int _urlIndex = 0;
  bool _loading = true;
  bool _failed = false;
  final Set<int> _attempted = {};
  int _generation = 0;
  bool _closed = false;
  Timer? _frameTimer;
  Timer? _failureTimer;

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
        if (buffering && !_loading && !_failed) {
          // 出画后中途缓冲：恢复加载提示，避免卡顿期无反馈。
          setState(() => _loading = true);
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
    _failureTimer?.cancel();
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
    _attempted.add(urlIdx);
    final ticket = ++_generation;
    _failureTimer?.cancel();
    _failureTimer = null;
    _frameTimer?.cancel();
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

  /// 出画判定：正在播放且不在缓冲 = 有画面。
  /// 清掉加载/失败提示，并撤销打开阶段的失败确认与 12s 兜底。
  void _checkFrame() {
    if (_closed || !mounted) return;
    if (!_player.state.playing || _player.state.buffering) return;
    _frameTimer?.cancel();
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

  /// 出错自动切下一线路；全部线路都试过才落失败态。
  /// 打开阶段（仍在转圈）的 error 进入 1.2s 延迟确认——播放器启动链路里
  /// stop→open 竞态会带来上一条线路的旧 error，立即切线会误杀刚打开的
  /// 正常线路；确认窗内出画则丢弃。确认期内转圈保持，不黑屏。
  void _handleFailure() {
    if (_closed || !mounted) return;
    if (_failureTimer != null) return;
    if (_loading) {
      _failureTimer = Timer(_failureConfirm, _confirmFailure);
      return;
    }
    _switchOrFail();
  }

  void _confirmFailure() {
    _failureTimer = null;
    if (_closed || !mounted) return;
    if (_player.state.playing && !_player.state.buffering) return;
    _switchOrFail();
  }

  void _switchOrFail() {
    final urls = _channel.urls;
    for (var i = 0; i < urls.length; i++) {
      if (!_attempted.contains(i)) {
        _open(i);
        return;
      }
    }
    _setFailed();
  }

  void _setFailed() {
    if (_closed || !mounted) return;
    _frameTimer?.cancel();
    _failureTimer?.cancel();
    _failureTimer = null;
    setState(() {
      _loading = false;
      _failed = true;
    });
  }

  void _retry() {
    setState(() => _attempted.clear());
    _open(_urlIndex);
  }

  void _switchRoute(int index) {
    if (index == _urlIndex || index < 0 || index >= _channel.urls.length) {
      return;
    }
    setState(() => _attempted.clear());
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
      _attempted.clear();
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
                                  '线路 ${i + 1}' +
                                      (LiveRouteMemory.recall(
                                                      widget.listId,
                                                      _channel.name) ==
                                                  _channel.urls[i] &&
                                              i != _urlIndex
                                          ? ' · 已记住'
                                          : ''),
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
