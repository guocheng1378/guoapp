import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'core_bridge.dart';
import 'drama_actions.dart';
import 'home_feed_models.dart';
import 'local_store.dart';
import 'models.dart';
import 'widgets.dart';

/// 打开剧目的回调形态（download=直达下载面板）。
typedef DramaOpenCallback = void Function(Drama drama, {bool download});

/// 「本周追剧」条：站点追剧周表（/v1/watch-calendar）给出的本周更新清单，
/// 挂在「我的追剧」页顶部。
///
/// 一周里同一部剧天天都会出现，这里只展示**最新一天**的那条（集数标签
/// 最新）；拉不到就整条不渲染——周表是锦上添花，不该在追剧页报错。
class WatchCalendarStrip extends StatefulWidget {
  const WatchCalendarStrip({
    super.key,
    required this.repository,
    required this.store,
    required this.source,
    required this.onOpen,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 站源 id：目前站点端只有 dongpiandi 给周表，其余源整条不渲染。
  final String source;
  final DramaOpenCallback onOpen;

  /// 支持周表的站源（与核心 action homeCalendar 对齐）。
  static const supportedSources = <String>{'dongpiandi'};

  @override
  State<WatchCalendarStrip> createState() => _WatchCalendarStripState();
}

class _WatchCalendarStripState extends State<WatchCalendarStrip> {
  WatchCalendar _calendar = const WatchCalendar();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant WatchCalendarStrip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      _calendar = const WatchCalendar();
      _loaded = false;
      _load();
    }
  }

  Future<void> _load({bool force = false}) async {
    if (!WatchCalendarStrip.supportedSources.contains(widget.source)) return;
    try {
      final calendar = await widget.repository.watchCalendar(
        widget.source,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _calendar = calendar;
        _loaded = true;
      });
    } catch (_) {
      // 周表拉不到就当没有：追剧页主体是用户自己的追剧，不受影响。
      if (mounted) setState(() => _loaded = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!WatchCalendarStrip.supportedSources.contains(widget.source)) {
      return const SizedBox.shrink();
    }
    final items = _calendar.latest;
    if (!_loaded || items.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final height = DramaTile.extentFor(context, _tileWidth);
    return Padding(
      // 追剧页首屏要留给剧卡：周表整体压低（封面宽 92 + 紧凑标题行）。
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 2, 8, 6),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '本周追剧',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.titleSmall?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_calendar.days.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _rangeLabel,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '刷新本周追剧',
                  icon: AppIcon(AppIcons.refresh),
                  onPressed: () => _load(force: true),
                ),
              ],
            ),
          ),
          SizedBox(
            height: height,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: items.length,
              separatorBuilder: (_, _) => const SizedBox(width: 10),
              itemBuilder: (context, index) {
                final drama = items[index];
                final following = widget.store.following(drama.id);
                return SizedBox(
                  width: _tileWidth,
                  child: DramaTile(
                    key: ValueKey('weekly-${drama.id}'),
                    drama: drama,
                    repository: widget.repository,
                    onTap: () => widget.onOpen(drama),
                    badge: following == null
                        ? null
                        : '${following.status.label}${following.hasUpdates ? ' · ${following.updateLabel}' : ''}',
                    actions: DramaActionButton(
                      drama: drama,
                      store: widget.store,
                      onDownload: widget.repository.supportsDownloads &&
                              widget.store.canDownload
                          ? () => widget.onOpen(drama, download: true)
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  static const double _tileWidth = 92;

  /// 副标题：周表覆盖的日期范围（站点给几天就写几天）。
  String get _rangeLabel {
    final days = _calendar.days.where((day) => !day.isEmpty).toList();
    if (days.isEmpty) return '';
    final first = days.first;
    final last = days.last;
    final range = first.date == last.date
        ? first.date
        : '${first.date} → ${last.date}';
    return '共 ${_calendar.latest.length} 部在更新 · $range';
  }
}
