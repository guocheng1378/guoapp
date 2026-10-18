import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'models.dart';
import 'widgets.dart';

/// 首页轮播大卡：剧卡流顶部的横滑推荐位（主题商店跑马灯卡样式）。
/// 自动 5 秒翻页，手动拖动或翻页后重新计时；测试环境（FLUTTER_TEST）
/// 不启动自动翻页，避免 pumpAndSettle 被 pending timer 卡住。
class HomeCarousel extends StatefulWidget {
  const HomeCarousel({
    super.key,
    required this.items,
    required this.repository,
    required this.onOpen,
    this.height = 188,
  });

  /// 轮播最多消费的条目数；首页网格跳过这些条目，避免与轮播重复展示。
  static const int maxItems = 5;

  final List<Drama> items;
  final AppRepository repository;
  final ValueChanged<Drama> onOpen;
  final double height;

  @override
  State<HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends State<HomeCarousel> {
  static const Duration _interval = Duration(seconds: 5);

  late List<Drama> _ids;
  final PageController _controller = PageController(viewportFraction: 0.86);
  Timer? _timer;
  int _page = 0;

  static bool get _autoplay {
    if (kIsWeb) return false;
    try {
      return !Platform.environment.containsKey('FLUTTER_TEST');
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _ids = widget.items.take(HomeCarousel.maxItems).toList(growable: false);
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant HomeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.items
        .take(HomeCarousel.maxItems)
        .toList(growable: false);
    bool same = next.length == _ids.length;
    if (same) {
      for (var i = 0; i < next.length; i++) {
        if (next[i].id != _ids[i].id || next[i].cover != _ids[i].cover) {
          same = false;
          break;
        }
      }
    }
    if (same) return;
    _ids = next;
    _page = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _controller.hasClients) {
        _controller.jumpToPage(0);
      }
    });
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_autoplay || _ids.length < 2) return;
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || !_controller.hasClients || _ids.length < 2) return;
      final next = (_page + 1) % _ids.length;
      _controller.animateToPage(
        next,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    _startTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_ids.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('home-carousel'),
      height: widget.height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: _ids.length,
            // 相邻页允许隐式滚动（拖动时前后页提前布局），横滑更顺。
            allowImplicitScrolling: true,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) =>
                _card(context, _ids[index], index),
          ),
          if (_ids.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _ids.length; i++)
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: i == _page ? 16 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: i == _page ? .92 : .42),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _card(BuildContext context, Drama drama, int index) {
    // 按压缩放状态本地化到单卡（见 _CarouselCard）：早期由父级
    // setState 驱动 _pressedIndex，按一张卡要重建整座轮播。
    return _CarouselCard(
      drama: drama,
      repository: widget.repository,
      onOpen: widget.onOpen,
    );
  }
}

/// 单张轮播卡：按住轻微缩放（主题同款手感），松开/取消复原；
/// 点按轻震动 + 立即进启动页（转场即反馈）。
class _CarouselCard extends StatefulWidget {
  const _CarouselCard({
    required this.drama,
    required this.repository,
    required this.onOpen,
  });

  final Drama drama;
  final AppRepository repository;
  final ValueChanged<Drama> onOpen;

  @override
  State<_CarouselCard> createState() => _CarouselCardState();
}

class _CarouselCardState extends State<_CarouselCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    final colors = Theme.of(context).colorScheme;
    final subtitle = drama.episodes > 0 ? '共 ${drama.episodes} 集' : '';
    return GestureDetector(
      onTapDown: (_) {
        if (_pressed) return;
        setState(() => _pressed = true);
      },
      onTapCancel: () {
        if (!_pressed) return;
        setState(() => _pressed = false);
      },
      onTapUp: (_) {
        if (!_pressed) return;
        setState(() => _pressed = false);
      },
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onOpen(drama);
      },
      child: AnimatedScale(
        scale: _pressed ? 0.965 : 1.0,
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 5),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: colors.surfaceContainerHighest),
              if (drama.id.isNotEmpty)
                CachedCoverImage(
                  key: ValueKey('carousel-${drama.id}\u0000${drama.cover}'),
                  drama: drama,
                  repository: widget.repository,
                  placeholder: const SizedBox.expand(),
                ),
              const Positioned.fill(
                child: IgnorePointer(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black87],
                      ),
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 16,
                right: 60,
                bottom: 14,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      drama.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subtitle.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: .82),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              if (drama.vip)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFF6C86B),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: const Text(
                      'VIP',
                      style: TextStyle(
                        color: Color(0xFF40300D),
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        ),
      ),
    );
  }
}
