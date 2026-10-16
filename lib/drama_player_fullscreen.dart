// 短剧全屏沉浸式播放器 — 垂直 PageView 切集 + 底部控制层
// 修复点：GestureDetector 移入 PageView page item 内部，垂直拖拽和水平 seek 通过手势 arena 正确共存；
// 进度条可拖动 + 左右 seek 显示时间 overlay；底部加选集/倍速；VIP 集后端只给 preview 时显示友好提示。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'playback_loader.dart';
import 'playback_preloader.dart';

class DramaPlayerFullscreen extends StatefulWidget {
  const DramaPlayerFullscreen({
    super.key,
    required this.detail,
    required this.initialIndex,
    required this.repository,
    required this.store,
    this.initialPosition = 0,
  });

  final DramaDetail detail;
  final int initialIndex;
  final AppRepository repository;
  final LocalStore store;
  final double initialPosition;

  @override
  State<DramaPlayerFullscreen> createState() => _DramaPlayerFullscreenState();
}

class _DramaPlayerFullscreenState extends State<DramaPlayerFullscreen>
    with WidgetsBindingObserver {
  late final Player _player;
  late final VideoController _video;
  late final PlaybackLoader _loader;
  late final PlaybackPreloader _preloader;
  final PageController _pageController = PageController();

  int _index = 0;
  int _generation = 0;
  bool _loading = true;
  bool _playing = false;
  String? _error;
  String? _warning;
  bool _controlsVisible = true;
  double _position = 0;
  double _duration = 0;
  double _speed = 1.0;

  // seek overlay 状态
  bool _seekActive = false;
  double _seekTarget = 0;

  Timer? _controlsHideTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  bool _closed = false;

  // 水平拖动状态
  double? _hDragStartX;
  double? _hDragStartPos;
  bool _hDragSeeking = false;

  static const _speeds = [0.75, 1.0, 1.25, 1.5, 2.0];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _player = Player(
      configuration: const PlayerConfiguration(
        bufferSize: 16 * 1024 * 1024,
        logLevel: MPVLogLevel.error,
      ),
    );
    _video = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: !Platform.isIOS,
      ),
    );
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);

    _playingSub = _player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
      if (_playing) _scheduleHideControls();
    });
    _posSub = _player.stream.position.listen((pos) {
      if (!mounted) return;
      setState(() {
        _position = pos.inMilliseconds / 1000;
        final d = _player.state.duration.inMilliseconds / 1000;
        if (d > 0 && (d - _duration).abs() > 0.5) _duration = d;
      });
      if (_playing &&
          !_loading &&
          _index < widget.detail.episodes.length - 1 &&
          _duration > 0 &&
          _position >= _duration - 3) {
        _goTo(_index + 1, animate: true);
      }
    });

    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (Platform.isAndroid || Platform.isIOS) {
        SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
      }
      _openEpisode(_index, position: widget.initialPosition);
      _scheduleHideControls();
    });
  }

  @override
  void dispose() {
    _closed = true;
    WidgetsBinding.instance.removeObserver(this);
    _controlsHideTimer?.cancel();
    _posSub?.cancel();
    _playingSub?.cancel();
    _pageController.dispose();
    _preloader.dispose();
    _loader.close();
    _player.dispose();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) unawaited(_player.pause());
  }

  Future<void> _openEpisode(int index, {double position = 0}) async {
    if (_closed || index < 0 || index >= widget.detail.episodes.length) return;
    final ticket = ++_generation;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
      _warning = null;
      _position = position;
    });

    final ep = widget.detail.episodes[index];
    final warmed = _preloader.take(widget.detail.drama, ep);
    _preloader.clear();

    try {
      final plan = warmed != null
          ? await _loader.use(warmed)
          : await _loader.load(widget.detail.drama, ep);
      if (_closed || ticket != _generation || plan == null) return;

      await _player.open(Media(plan.url), play: position <= 0);
      await _player.setRate(_speed);
      if (position > 0) {
        await _player.seek(Duration(milliseconds: (position * 1000).round()));
        unawaited(_player.play());
      }

      if (!mounted || _closed) return;
      setState(() {
        _loading = false;
        _playing = true;
        _duration = _player.state.duration.inMilliseconds / 1000;
        if (ep.vip) _warning = '本集为 VIP 内容，服务器仅返回试看片段';
      });
      _preloaderSync();
    } catch (e) {
      if (_closed || ticket != _generation) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _preloaderSync() {
    if (_index + 1 < widget.detail.episodes.length && !_loading) {
      _preloader.prepare(
        widget.detail.drama,
        widget.detail.episodes[_index + 1],
      );
    }
  }

  void _goTo(int target, {bool animate = false}) {
    if (target < 0 || target >= widget.detail.episodes.length) return;
    setState(() => _warning = null);
    if (animate) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(target);
    }
  }

  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _controlsVisible && _playing && !_seekActive) {
        setState(() => _controlsVisible = false);
      }
    });
  }

  Future<void> _togglePlay() async {
    if (_player.state.playing) {
      await _player.pause();
    } else {
      await _player.play();
    }
  }

  Future<void> _retry() async {
    await _openEpisode(_index, position: _position);
  }

  void _back() => Navigator.of(context).pop();

  void _openEpisodesPicker() {
    final total = widget.detail.episodes.length;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.list, color: Colors.white),
                      SizedBox(width: 8),
                      Text('选集', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
                Flexible(
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const ClampingScrollPhysics(),
                    gridDelegate:
                        const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 6,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1,
                    ),
                    itemCount: total,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                    itemBuilder: (_, idx) {
                      final ep = widget.detail.episodes[idx];
                      final selected = idx == _index;
                      final title = ep.number > 0
                          ? '第${ep.number}集'
                          : ep.title.isNotEmpty
                              ? ep.title
                              : '${idx + 1}';
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          if (!selected) _goTo(idx, animate: true);
                        },
                        child: Container(
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            color: selected
                                ? Colors.white
                                : Colors.white.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            title,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: selected ? Colors.black : Colors.white70,
                              fontSize: 12,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  void _openSpeedPicker() {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Text('倍速',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600)),
                ),
                Padding(
                  padding:
                      const EdgeInsets.fromLTRB(16, 4, 16, 16),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final s in _speeds)
                        GestureDetector(
                          onTap: () {
                            Navigator.pop(context);
                            setState(() => _speed = s);
                            _player.setRate(s);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 16, vertical: 10),
                            decoration: BoxDecoration(
                              color: _speed == s
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${s}x',
                              style: TextStyle(
                                color: _speed == s
                                    ? Colors.black
                                    : Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ===== 水平拖动 seek =====
  void _onHorizontalDragStart(DragStartDetails d) {
    _hDragStartX = d.globalPosition.dx;
    _hDragStartPos = _player.state.position.inMilliseconds / 1000;
    _hDragSeeking = false;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails d) {
    if (_hDragStartX == null || _hDragStartPos == null) return;
    final total = _player.state.duration.inMilliseconds / 1000;
    if (total <= 0) return;

    // 先判断手势方向：水平位移明显大于垂直位移才算水平 seek
    final dx = d.globalPosition.dx - (_hDragStartX ?? d.globalPosition.dx);
    if (dx.abs() < 8) return;

    _hDragSeeking = true;
    final width = MediaQuery.sizeOf(context).width;
    final ratio = dx / width;
    final target = (_hDragStartPos! + ratio * total).clamp(0.0, total);
    setState(() {
      _seekActive = true;
      _seekTarget = target;
    });
  }

  void _onHorizontalDragEnd(DragEndDetails d) {
    if (_hDragSeeking && _seekTarget > 0) {
      unawaited(_player.seek(
          Duration(milliseconds: (_seekTarget * 1000).round())));
    }
    _hDragStartX = null;
    _hDragStartPos = null;
    _hDragSeeking = false;
    setState(() => _seekActive = false);
    _scheduleHideControls();
  }

  // ===== 构建 =====
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ① 视频层（固定，最底层）
          Positioned.fill(
            child: Video(
              controller: _video,
              fit: BoxFit.cover,
              controls: (_) => const SizedBox.shrink(),
            ),
          ),

          // ② 垂直 PageView — 每个 page item 内部处理点击/双击/水平 seek
          //    PageView 自身处理垂直上下滑动切集
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: widget.detail.episodes.length,
            onPageChanged: (i) {
              _openEpisode(i, position: 0);
            },
            itemBuilder: (_, idx) {
              return GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: _toggleControls,
                onDoubleTap: _togglePlay,
                onHorizontalDragStart: _onHorizontalDragStart,
                onHorizontalDragUpdate: _onHorizontalDragUpdate,
                onHorizontalDragEnd: _onHorizontalDragEnd,
                child: const SizedBox.expand(),
              );
            },
          ),

          // ③ VIP/试用警告条（播放中始终可见，避免误导用户）
          if (_warning != null && !_loading)
            Positioned(
              top: MediaQuery.paddingOf(context).top + 4,
              left: 16,
              right: 16,
              child: _VIPWarningBar(text: _warning!),
            ),

          // ④ 加载态
          if (_loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x80000000),
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),

          // ⑤ 错误态
          if (_error != null && !_loading)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black87,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.orange, size: 48),
                    const SizedBox(height: 16),
                    Text(_error!,
                        style: const TextStyle(color: Colors.white70)),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: _retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),

          // ⑥ 顶部栏（返回 + 标题）
          if (_controlsVisible)
            Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 0,
              right: 0,
              child: _buildTopBar(),
            ),

          // ⑦ 底部控制层 + 可拖动进度条
          if (!_loading && !_errorPresent)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_controlsVisible || _seekActive) _buildProgressBar(),
                  if (_controlsVisible) _buildBottomBar(),
                ],
              ),
            ),

          // ⑧ seek 时间 overlay（拖动时居中显示目标时间）
          if (_seekActive) _buildSeekOverlay(),
        ],
      ),
    );
  }

  bool get _errorPresent => _error != null && !_loading;

  // ===== Top Bar =====
  Widget _buildTopBar() {
    final drama = widget.detail.drama;
    final ep = widget.detail.episodes[_index];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            onPressed: _back,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  drama.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                      fontSize: 14),
                ),
                Text(
                  '${ep.number > 0 ? "第${ep.number}集" : ep.title}${ep.vip ? " · VIP" : ""}',
                  style: const TextStyle(
                      color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow,
                color: Colors.white),
            onPressed: _togglePlay,
          ),
        ],
      ),
    );
  }

  // ===== Progress Bar（可拖动）=====
  Widget _buildProgressBar() {
    final total = _duration > 0 ? _duration : 1.0;
    final pos = _seekActive ? _seekTarget : _position;
    final ratio = (pos / total).clamp(0.0, 1.0);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          Text(
            _formatTime(pos),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _DraggableProgressBar(
              ratio: ratio,
              loading: _loading,
              active: _seekActive,
              onSeekStart: () {
                if (_duration <= 0) return;
                setState(() => _seekActive = true);
              },
              onSeekUpdate: (r) {
                if (_duration <= 0) return;
                setState(() {
                  _seekActive = true;
                  _seekTarget = r * _duration;
                });
              },
              onSeekEnd: (r) {
                if (_duration <= 0) return;
                final target = r * _duration;
                unawaited(_player.seek(
                    Duration(milliseconds: (target * 1000).round())));
                setState(() {
                  _seekActive = false;
                  _position = target;
                });
                _scheduleHideControls();
              },
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _formatTime(_duration),
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  // ===== Bottom Bar =====
  Widget _buildBottomBar() {
    final total = widget.detail.episodes.length;
    final prevDisabled = _index == 0;
    final nextDisabled = _index == total - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black54, Colors.transparent],
        ),
      ),
      child: Row(
        children: [
          IconButton(
            tooltip: '上一集',
            icon: const Icon(Icons.skip_previous_rounded,
                color: Colors.white, size: 28),
            onPressed: prevDisabled
                ? null
                : () => _goTo(_index - 1, animate: true),
          ),
          IconButton(
            tooltip: '下一集',
            icon: const Icon(Icons.skip_next_rounded,
                color: Colors.white, size: 28),
            onPressed: nextDisabled
                ? null
                : () => _goTo(_index + 1, animate: true),
          ),
          const Spacer(),
          Text(
            '${_index + 1} / $total',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const Spacer(),
          IconButton(
            tooltip: '选集',
            icon: const Icon(Icons.format_list_bulleted_rounded,
                color: Colors.white, size: 26),
            onPressed: _openEpisodesPicker,
          ),
          IconButton(
            tooltip: '倍速 ${_speed}x',
            icon: const Icon(Icons.speed,
                color: Colors.white, size: 26),
            onPressed: _openSpeedPicker,
          ),
        ],
      ),
    );
  }

  // ===== Seek Overlay =====
  Widget _buildSeekOverlay() {
    return Positioned(
      top: MediaQuery.sizeOf(context).height * 0.4,
      left: MediaQuery.sizeOf(context).width * 0.5 - 70,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.7),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          '${_formatTime(_seekTarget)} / ${_formatTime(_duration)}',
          style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  static String _formatTime(double seconds) {
    if (!seconds.isFinite || seconds < 0) return '00:00';
    final total = seconds.round();
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }
}

class _VIPWarningBar extends StatelessWidget {
  const _VIPWarningBar({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(Icons.info_outline, color: Colors.white, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}

class _DraggableProgressBar extends StatefulWidget {
  const _DraggableProgressBar({
    required this.ratio,
    required this.loading,
    required this.active,
    required this.onSeekStart,
    required this.onSeekUpdate,
    required this.onSeekEnd,
  });

  final double ratio;
  final bool loading;
  final bool active;
  final VoidCallback onSeekStart;
  final ValueChanged<double> onSeekUpdate;
  final ValueChanged<double> onSeekEnd;

  @override
  State<_DraggableProgressBar> createState() => _DraggableProgressBarState();
}

class _DraggableProgressBarState extends State<_DraggableProgressBar> {
  bool _dragging = false;

  void _fromPosition(Offset local, Size size) {
    final r = local.dx.clamp(0.0, size.width) / size.width;
    widget.onSeekUpdate(r);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (_, constraints) {
        final w = constraints.maxWidth;
        final thumbX = (widget.ratio * w).clamp(0.0, w);
        return GestureDetector(
          onHorizontalDragStart: (_) {
            setState(() => _dragging = true);
            widget.onSeekStart();
          },
          onHorizontalDragUpdate: (d) {
            _fromPosition(d.localPosition, constraints.biggest);
          },
          onHorizontalDragEnd: (d) {
            setState(() => _dragging = false);
            widget.onSeekEnd(widget.ratio);
          },
          child: SizedBox(
            height: 28,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 3,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Container(
                  height: 3,
                  width: (thumbX).clamp(0, w),
                  decoration: BoxDecoration(
                    color: widget.active || _dragging
                        ? Colors.white
                        : Colors.white.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Positioned(
                  left: thumbX - 7,
                  child: Container(
                    width: 14,
                    height: 14,
                    decoration: const BoxDecoration(
                      color: Colors.white,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black45,
                            blurRadius: 4,
                            offset: Offset(0, 1)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
