import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'featured_catalog.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';
import 'motion_tokens.dart';

/// 首页轮播大卡：剧卡流顶部的横滑推荐位（主题商店跑马灯卡样式）。
/// 内容整体由豆瓣选片：直接播豆瓣「近期热门国产剧」榜条目（豆瓣封面 +
/// 蓝色豆瓣徽章 + 评分摘要），不足 [maxItems] 张用当前源条目补位；榜单
/// 拉取失败/为空即纯当前源回退（见 featured_catalog.dart 的
/// loadDoubanPicks）。豆瓣条目无播放链路，点击经 openDoubanReferral 同
/// 名搜索进详情（onOpen 由 home_screen 分流）；黄果类锚点不拉榜、纯回
/// 退。自动 5 秒翻页，手动拖动或翻页后重新计时；
/// 测试环境（FLUTTER_TEST）不启动自动翻页，避免 pumpAndSettle 被
/// pending timer 卡住。
class HomeCarousel extends StatefulWidget {
  const HomeCarousel({
    super.key,
    required this.store,
    required this.repository,
    required this.onOpen,
    required this.fallbackItems,
    required this.anchor,
    this.height = 188,
  });

  /// 轮播最多展示的精选条目数。
  static const int maxItems = 5;

  final LocalStore store;
  final AppRepository repository;
  final ValueChanged<Drama> onOpen;

  /// 精选轮换锚点：通常是当前站源，决定只在同一内容类型的站源里轮换。
  final SourceSite anchor;

  /// 补位/回退条目：豆瓣命中不足 [maxItems] 张（或黄果类锚点、无同类
  /// 可搜源）时，用首页当前源条目补位（home_screen 传入排好序的可见
  /// 条目，轮播自行截取去重）。
  final List<Drama> fallbackItems;
  final double height;

  @override
  State<HomeCarousel> createState() => _HomeCarouselState();
}

class _HomeCarouselState extends State<HomeCarousel> {
  static const Duration _interval = Duration(seconds: 5);

  List<_Entry> _entries = const [];
  final PageController _controller = PageController(viewportFraction: 0.86);
  Timer? _timer;
  int _page = 0;
  int _generation = 0;

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
    _load();
  }

  @override
  void didUpdateWidget(covariant HomeCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final anchorChanged = oldWidget.anchor.id != widget.anchor.id;
    final itemsChanged = !_sameItems(
      oldWidget.fallbackItems,
      widget.fallbackItems,
    );
    // 切源后必须重算选片，否则会一直挂着上一个锚点的内容；条目变化只在
    // 轮播带补位卡时跟随刷新——豆瓣命中已满格时补位不上屏，分页/筛选
    // 不该重拉搜索请求（当天缓存已挡住重复请求，这里只是少一次空转）。
    if (anchorChanged ||
        (itemsChanged &&
            !doubanPicksFill(HomeCarousel.maxItems, widget.anchor))) {
      _load();
    }
  }

  /// 按 id 序列比较条目：避免每次重建都无条件重刷轮播。
  bool _sameItems(List<Drama> a, List<Drama> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id) return false;
    }
    return true;
  }

  Future<void> _load() async {
    final generation = ++_generation;
    // 黄果类锚点不走豆瓣选片：纯回退自家条目，零请求。
    if (widget.anchor.inHuangguoCategory) {
      _applyFallback(generation);
      return;
    }
    try {
      final picks = await loadDoubanPicks(
        widget.repository,
        widget.store,
        widget.anchor,
      );
      if (!mounted || generation != _generation) return;
      // 命中卡在前（带豆瓣徽章），不足 maxItems 张用当前源条目补位；
      // 0 命中即纯回退（与黄果类同款表现）。
      final entries = <_Entry>[
        for (final pick in picks) _Entry(pick.drama, doubanTag: pick.tag),
      ];
      final existing = {for (final entry in entries) entry.drama.id};
      for (final drama in widget.fallbackItems) {
        if (entries.length >= HomeCarousel.maxItems) break;
        if (existing.contains(drama.id)) continue;
        // 与剧卡流的 VIP 隐藏规则保持一致（黄豆源会员内容）。
        if (widget.store.hideVip &&
            drama.vip &&
            drama.source == 'huangdou') {
          continue;
        }
        existing.add(drama.id);
        entries.add(_Entry(drama));
      }
      setState(() => _entries = List.unmodifiable(entries));
      _startTimer();
    } catch (_) {
      // 选片失败静默回退：首页主体是剧卡流，不打扰。
      _applyFallback(generation);
    }
  }

  /// 纯回退：轮播展示首页当前源前几条（黄果类锚点 / 选片异常路径）。
  void _applyFallback(int generation) {
    if (!mounted || generation != _generation) return;
    setState(() {
      _entries = [
        for (final drama
            in widget.fallbackItems.take(HomeCarousel.maxItems))
          _Entry(drama),
      ];
    });
    _startTimer();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = null;
    if (!_autoplay || _entries.length < 2) return;
    _timer = Timer.periodic(_interval, (_) {
      if (!mounted || !_controller.hasClients || _entries.length < 2) return;
      final next = (_page + 1) % _entries.length;
      _controller.animateToPage(
        next,
        duration: MotionDurations.hero,
        curve: MotionCurves.standard,
      );
    });
  }

  void _onPageChanged(int page) {
    setState(() => _page = page);
    _startTimer();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_entries.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      key: const ValueKey('home-carousel'),
      height: widget.height,
      child: Stack(
        children: [
          PageView.builder(
            controller: _controller,
            itemCount: _entries.length,
            // 相邻页允许隐式滚动（拖动时前后页提前布局），横滑更顺。
            allowImplicitScrolling: true,
            onPageChanged: _onPageChanged,
            itemBuilder: (context, index) => _pageCard(context, index),
          ),
          if (_entries.length > 1)
            Positioned(
              left: 0,
              right: 0,
              bottom: 8,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var i = 0; i < _entries.length; i++)
                    AnimatedContainer(
                      duration: MotionDurations.base,
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

  /// 页偏移缩放（MIUI 跑马灯卡同款）：当前页 1.0，离场页随页偏移缩到
  /// 0.94——监听 PageController 逐帧驱动，翻页/拖动全程连续，回中即回
  /// 满。与卡内按压缩放（_CarouselCard）分两层叠加互不干扰。
  Widget _pageCard(BuildContext context, int index) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        var dist = 0.0;
        // itemBuilder 在视口布局中执行，滚动范围未就绪时读 page/max 会
        // 断言炸（Null check），必须以 hasContentDimensions 守卫；未就绪
        // 或单页时 dist 恒 0 = scale 1，自然降级。
        if (_controller.hasClients &&
            _controller.position.hasContentDimensions) {
          final page = _controller.page ?? index.toDouble();
          dist = (page - index).abs().clamp(0.0, 1.0);
        }
        return Transform.scale(scale: 1 - 0.06 * dist, child: child);
      },
      child: _card(context, _entries[index]),
    );
  }

  Widget _card(BuildContext context, _Entry entry) {
    // 按压缩放状态本地化到单卡（见 _CarouselCard）：早期由父级
    // setState 驱动 _pressedIndex，按一张卡要重建整座轮播。
    return _CarouselCard(
      drama: entry.drama,
      doubanTag: entry.doubanTag,
      repository: widget.repository,
      onOpen: widget.onOpen,
    );
  }
}

/// 轮播条目：[doubanTag] 非空 = 豆瓣选片卡（榜单剧名搜同类站源命中），
/// 渲染蓝色豆瓣徽章 + 评分摘要；空 = 当前源补位/回退卡。
class _Entry {
  const _Entry(this.drama, {this.doubanTag = ''});
  final Drama drama;
  final String doubanTag;
}

/// 单张轮播卡：按住轻微缩放（主题同款手感），松开/取消复原；
/// 点按轻震动 + 立即进启动页（转场即反馈）。
class _CarouselCard extends StatefulWidget {
  const _CarouselCard({
    required this.drama,
    required this.repository,
    required this.onOpen,
    this.doubanTag = '',
  });

  final Drama drama;
  final AppRepository repository;
  final ValueChanged<Drama> onOpen;

  /// 非空 = 豆瓣搜片卡：左上替换 VIP 位渲染蓝色豆瓣徽章 + 评分摘要。
  final String doubanTag;

  @override
  State<_CarouselCard> createState() => _CarouselCardState();
}

class _CarouselCardState extends State<_CarouselCard> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final drama = widget.drama;
    final colors = Theme.of(context).colorScheme;
    // 豆瓣卡源名与左上「豆瓣」徽章重复，只显示集数等有效信息。
    final showSourceName = drama.source != SourceSite.douban.id;
    final sourceName = SourceSite.byId(drama.source)?.name;
    final subtitle = [
      if (showSourceName && sourceName != null && sourceName.isNotEmpty)
        sourceName,
      if (drama.episodes > 0) '共 ${drama.episodes} 集',
    ].join(' · ');
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
        duration: MotionDurations.micro,
        curve: MotionCurves.press,
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
              if (widget.doubanTag.isNotEmpty)
                Positioned(
                  left: 12,
                  top: 12,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _carouselBadge(
                        '豆瓣',
                        background: const Color(0xFF2E7BF0),
                        foreground: Colors.white,
                      ),
                      const SizedBox(width: 6),
                      _carouselBadge(
                        widget.doubanTag,
                        background: Colors.black.withValues(alpha: .45),
                        foreground: Colors.white,
                      ),
                    ],
                  ),
                )
              else if (drama.vip)
                Positioned(
                  left: 12,
                  top: 12,
                  child: _carouselBadge(
                    'VIP',
                    background: const Color(0xFFF6C86B),
                    foreground: const Color(0xFF40300D),
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

/// 轮播卡左上角徽章（豆瓣 / 评分摘要 / VIP 同一形状，颜色不同）。
Widget _carouselBadge(
  String text, {
  required Color background,
  required Color foreground,
}) {
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: background,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: foreground,
        fontSize: 11,
        fontWeight: FontWeight.w800,
      ),
    ),
  );
}
