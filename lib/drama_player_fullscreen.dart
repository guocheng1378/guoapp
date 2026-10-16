// 短剧全屏沉浸式播放器 — 上下滑动切换集数
// 复用 PlaybackLoader / PlaybackPreloader / media_kit Player。
// 与 PlayerScreen 独立：无 AppBar、无选集 Panel、全屏黑色背景、垂直 PageView。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'core_bridge.dart';
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
  bool _controlsVisible = true;
  double _position = 0;
  double _duration = 0;

  Timer? _controlsHideTimer;
  Timer? _saveTimer;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<bool>? _playingSub;
  Object _sessionKey = Object();
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _index = widget.initialIndex;
    _player = Player();
    _video = VideoController(_player);
    _loader = PlaybackLoader(widget.repository);
    _preloader = PlaybackPreloader(widget.repository);

    _playingSub = _player.stream.playing.listen((v) {
      if (!mounted) return;
      setState(() => _playing = v);
    });
    _posSub = _player.stream.position.listen((pos) {
      if (!mounted) return;
      setState(() {
        _position = pos.inMilliseconds / 1000;
        final d = _player.state.duration.inMilliseconds / 1000;
        if (d > 0 && (d - _duration).abs() > 0.5) _duration = d;
      });
      // auto advance on last 2 seconds of current episode
      final total = _player.state.duration.inMilliseconds / 1000;
      if (_playing && _index < widget.detail.episodes.length - 1) {
        if (total > 0 && _position >= total - 2) {
          _goTo(_index + 1, animate: true);
        }
      }
      _preloaderSync();
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
    _saveTimer?.cancel();
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
    if (state == AppLifecycleState.paused) {
      unawaited(_player.pause());
    }
  }

  // ===== 核心：打开某一集 =====
  Future<void> _openEpisode(int index, {double position = 0}) async {
    if (_closed || index < 0 || index >= widget.detail.episodes.length) return;
    final ticket = ++_generation;
    setState(() {
      _index = index;
      _loading = true;
      _error = null;
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

      _sessionKey = Object();
      await _player.open(Media(plan.url), play: position <= 0);
      if (position > 0) {
        await _player.seek(Duration(milliseconds: (position * 1000).round()));
        unawaited(_player.play());
      }

      if (!mounted || _closed) return;
      setState(() {
        _loading = false;
        _playing = true;
        _duration = _player.state.duration.inMilliseconds / 1000;
      });
      _preloaderSync();
      _notifyChanged();
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

  // ===== PageView 切集 =====
  void _goTo(int target, {bool animate = false}) {
    if (target < 0 || target >= widget.detail.episodes.length) return;
    if (animate) {
      _pageController.animateToPage(
        target,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
      );
    } else {
      _pageController.jumpToPage(target);
    }
    // PageView.onPageChanged 会触发 _openEpisode
  }

  // ===== 控制层 =====
  void _toggleControls() {
    setState(() => _controlsVisible = !_controlsVisible);
    if (_controlsVisible) _scheduleHideControls();
  }

  void _scheduleHideControls() {
    _controlsHideTimer?.cancel();
    _controlsHideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _controlsVisible && _playing) {
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

  void _seekBy(int seconds) {
    final pos = _player.state.position.inMilliseconds + seconds * 1000;
    _player.seek(Duration(milliseconds: pos.clamp(0, _player.state.duration.inMilliseconds)));
  }

  Future<void> _retry() async {
    await _openEpisode(_index, position: _position);
  }

  void _back() {
    Navigator.of(context).pop();
  }

  void _notifyChanged() {
    // 通知详情页/列表页更新 watched 状态（可选）
  }

  // ===== Build =====
  @override
  Widget build(BuildContext context) {
    final drama = widget.detail.drama;
    final ep = widget.detail.episodes[_index];
    final total = widget.detail.episodes.length;

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        fit: StackFit.expand,
        children: [
          // ① 垂直 PageView — 处理上下滑动手势
          PageView.builder(
            controller: _pageController,
            scrollDirection: Axis.vertical,
            itemCount: total,
            onPageChanged: _openEpisode,
            itemBuilder: (_, idx) => const SizedBox.expand(),
          ),

          // ② Video 层（固定在 Stack 里，不随 PageView 手势移动）
          Positioned.fill(
            child: Video(
              controller: _video,
              fit: BoxFit.cover,
              controls: (_) => const SizedBox.shrink(),
            ),
          ),

          // ③ 手势层 — 双击暂停/播放，进度条左右拖动
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _toggleControls,
              onDoubleTap: _togglePlay,
              onHorizontalDragUpdate: _onHorizontalDrag,
              child: const SizedBox.expand(),
            ),
          ),

          // ④ 进度条
          if (!_loading && _duration > 0) _buildProgressBar(),

          // ⑤ 顶部控制层
          if (_controlsVisible)
            Positioned(
              top: MediaQuery.paddingOf(context).top,
              left: 0,
              right: 0,
              child: _buildTopBar(drama, ep),
            ),

          // ⑥ 底部集数/操作
          if (_controlsVisible)
            Positioned(
              bottom: MediaQuery.paddingOf(context).bottom,
              left: 0,
              right: 0,
              child: _buildBottomBar(drama, ep),
            ),

          // ⑦ 加载态
          if (_loading)
            const Positioned.fill(
              child: ColoredBox(
                color: Color(0x80000000),
                child: Center(
                  child: CircularProgressIndicator(color: Colors.white),
                ),
              ),
            ),

          // ⑧ 错误态
          if (_error != null && !_loading)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black87,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline, color: Colors.orange, size: 48),
                    const SizedBox(height: 16),
                    Text(_error!, style: const TextStyle(color: Colors.white70)),
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
        ],
      ),
    );
  }

  // ===== 手势：左右拖动 seek =====
  double? _dragStartRatio;
  int? _dragDirection; // 1=forward, -1=backward, 0=ambiguous
  void _onHorizontalDrag(DragUpdateDetails d) {
    // 如果已经识别为 PageView 垂直滑动，让 PageView 接管
    if (d.delta.dy.abs() > d.delta.dx.abs() * 0.7) return;
    if (_dragStartRatio == null) {
      _dragStartRatio = _position / (_duration > 0 ? _duration : 1);
      _dragDirection = d.delta.dx.sign;
    }
    if (_dragDirection != d.delta.dx.sign && (d.delta.dx.abs() < 5)) return;
    final width = MediaQuery.sizeOf(context).width;
    final progress = (_dragStartRatio! + d.delta.dx / width).clamp(0.0, 1.0);
    final target = (progress * _duration * 1000).round();
    _player.seek(Duration(milliseconds: target));
  }

  // ===== UI 构建 =====
  Widget _buildProgressBar() {
    final ratio = (_position / _duration).clamp(0.0, 1.0);
    return Positioned(
      bottom: MediaQuery.paddingOf(context).bottom + 72,
      left: 16,
      right: 16,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: ratio,
          backgroundColor: Colors.white12,
          valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
          minHeight: 2,
        ),
      ),
    );
  }

  Widget _buildTopBar(Drama drama, Episode ep) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
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
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 14),
                ),
                Text(
                  '${ep.title} · ${ep.vip ? "VIP" : "免费"}',
                  style: const TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: Icon(_playing ? Icons.pause : Icons.play_arrow, color: Colors.white),
            onPressed: _togglePlay,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomBar(Drama drama, Episode ep) {
    final total = widget.detail.episodes.length;
    final prevDisabled = _index == 0;
    final nextDisabled = _index == total - 1;

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
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
            icon: const Icon(Icons.skip_previous_rounded, color: Colors.white),
            onPressed: prevDisabled ? null : () => _goTo(_index - 1, animate: true),
          ),
          Expanded(
            child: Text(
              '${_index + 1} / $total',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.skip_next_rounded, color: Colors.white),
            onPressed: nextDisabled ? null : () => _goTo(_index + 1, animate: true),
          ),
        ],
      ),
    );
  }
}
