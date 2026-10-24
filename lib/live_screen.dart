import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'folme.dart';
import 'glass.dart';
import 'live_models.dart';
import 'live_player_screen.dart';

/// 电视直播页（2026-10-22）：内置双 m3u 列表源一键切换 + 自填源合并展示。
/// 直播不进站源体系，数据全部来自 Go core `live.channels`。
/// UI（2026-10-23）：对齐主页玻璃体系——TopFog 雾面顶栏 + FogPill 胶囊岛 +
/// GlassChip 分组胶囊 + GlassSurface 频道卡 + FolmePress 按压手感。
class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.repository,
    this.liveUrls = const [],
    this.initialListId = '',
    this.onPlayChannel,
  });
  final AppRepository repository;
  final List<String> liveUrls;
  final String initialListId;
  @visibleForTesting
  final ValueChanged<LiveChannel>? onPlayChannel;
  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  bool _loading = true;
  String? _error;
  LivePage? _page;
  String _listId = '';
  String _group = '';

  /// 顶栏胶囊描边亮度（滚动越深越亮，回顶熄灭）——与主页同一驱动方式。
  final ValueNotifier<double> _prox = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _listId = widget.initialListId;
    _load();
  }

  @override
  void dispose() {
    _prox.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = await widget.repository.liveChannels(
        listId: _listId,
        liveUrls: widget.liveUrls,
        force: force,
      );
      if (!mounted) return;
      setState(() {
        _loading = false;
        _page = page;
        _listId = page.listId;
        if (_group.isNotEmpty &&
            !page.groups.any((group) => group.name == _group)) {
          _group = '';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _switchList(String id) {
    if (id == _listId) return;
    setState(() {
      _listId = id;
      _group = '';
    });
    _load();
  }

  List<LiveChannel> get _visibleChannels {
    final page = _page;
    if (page == null) return const [];
    if (_group.isEmpty) {
      return [for (final group in page.groups) ...group.channels];
    }
    for (final group in page.groups) {
      if (group.name == _group) return group.channels;
    }
    return const [];
  }

  void _openChannel(LiveChannel channel) {
    if (!channel.playable) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('「${channel.name}」暂无可用线路')));
      return;
    }
    if (widget.onPlayChannel != null) {
      widget.onPlayChannel!(channel);
      return;
    }
    final channels = _visibleChannels;
    var index = channels.indexWhere((c) => c.name == channel.name);
    if (index < 0) index = 0;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => LivePlayerScreen(
          channels: channels,
          initialIndex: index,
          listId: _listId,
        ),
      ),
    );
  }

  bool _onScroll(ScrollNotification n) {
    if (n.metrics.axis == Axis.vertical) {
      _prox.value = (n.metrics.pixels / 50).clamp(0.0, 1.0);
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return Scaffold(
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const TopFog(),
        titleSpacing: 12,
        title: _pill(
          child: const Padding(
            padding: EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Text(
              '电视直播',
              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600),
            ),
          ),
        ),
        actions: [
          if (page != null && page.lists.length > 1)
            _pill(
              child: PopupMenuButton<String>(
                key: const Key('live-list-switch'),
                tooltip: '切换直播列表',
                initialValue: _listId,
                onSelected: _switchList,
                itemBuilder: (context) => [
                  for (final list in page.lists)
                    PopupMenuItem(
                      value: list.id,
                      child: Row(
                        children: [
                          Expanded(child: Text(list.name)),
                          if (list.id == _listId)
                            const Icon(Icons.check, size: 18),
                        ],
                      ),
                    ),
                ],
                icon: const Icon(Icons.menu_book_outlined, size: 20),
              ),
            ),
          const SizedBox(width: 10),
          _pill(
            child: IconButton(
              key: const Key('live-refresh'),
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 20),
              onPressed: _loading ? null : () => _load(force: true),
            ),
          ),
          const SizedBox(width: 10),
        ],
      ),
      body: NotificationListener<ScrollNotification>(
        onNotification: _onScroll,
        child: _buildBody(context, page),
      ),
    );
  }

  /// 顶栏胶囊岛（主页 _navPill 同款：FogPill + FolmePress）。
  Widget _pill({required Widget child}) {
    return FogPill(prox: _prox, child: FolmePress(child: child));
  }

  Widget _buildBody(BuildContext context, LivePage? page) {
    final scheme = Theme.of(context).colorScheme;
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wifi_off,
              size: 40,
              color: scheme.onSurface.withValues(alpha: 0.38),
            ),
            const SizedBox(height: 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                '直播列表加载失败\n$_error',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: scheme.onSurface.withValues(alpha: 0.54),
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              key: const Key('live-retry'),
              onPressed: () => _load(),
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
            ),
          ],
        ),
      );
    }
    if (page == null || page.isEmpty) {
      return Center(
        child: Text(
          '暂无频道',
          style: TextStyle(color: scheme.onSurface.withValues(alpha: 0.38)),
        ),
      );
    }
    final channels = _visibleChannels;
    return Column(
      children: [
        if (page.warning.isNotEmpty)
          Padding(
            key: const Key('live-warning-bar'),
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
            child: GlassSurface(
              radius: 14,
              tint: GlassTint.pill,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: Colors.amber.shade400),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(page.warning, style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
            ),
          ),
        SizedBox(
          height: 48,
          child: SingleChildScrollView(
            key: const Key('live-group-bar'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
            child: Row(
              children: [
                _groupChip('全部', ''),
                for (final group in page.groups)
                  _groupChip(group.name, group.name),
              ],
            ),
          ),
        ),
        Expanded(
          child: channels.isEmpty
              ? Center(
                  child: Text(
                    '该分组暂无频道',
                    style: TextStyle(
                      color: scheme.onSurface.withValues(alpha: 0.38),
                    ),
                  ),
                )
              : ListView.builder(
                  key: const Key('live-channel-list'),
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
                  itemCount: channels.length,
                  itemBuilder: (context, index) =>
                      _channelRow(context, scheme, channels[index]),
                ),
        ),
      ],
    );
  }

  /// 频道卡：GlassSurface 玻璃行 + FolmePress 按压，替代原 ListTile。
  Widget _channelRow(
    BuildContext context,
    ColorScheme scheme,
    LiveChannel channel,
  ) {
    return Padding(
      key: Key('live-channel-${channel.name}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: FolmePress(
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => _openChannel(channel),
          child: GlassSurface(
            radius: 16,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  _channelAvatar(scheme, channel),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      channel.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (channel.urls.length > 1) ...[
                    const SizedBox(width: 8),
                    Text(
                      '${channel.urls.length} 条线路',
                      style: TextStyle(
                        fontSize: 11.5,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                  const SizedBox(width: 2),
                  Icon(
                    Icons.chevron_right,
                    size: 20,
                    color: scheme.onSurface.withValues(alpha: 0.25),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _channelAvatar(ColorScheme scheme, LiveChannel channel) {
    Widget placeholder() => Text(
          channel.name.isEmpty ? '?' : channel.name.characters.first,
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: 38,
        height: 38,
        color: scheme.onSurface.withValues(alpha: 0.06),
        alignment: Alignment.center,
        child: channel.logo.isEmpty
            ? placeholder()
            : Image(
                image: NetworkImage(channel.logo),
                width: 38,
                height: 38,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => placeholder(),
              ),
      ),
    );
  }

  /// 分组胶囊（主页 CatalogFilters 同款：GlassChip + FolmePress）。
  Widget _groupChip(String label, String group) {
    final selected = _group == group;
    return Padding(
      key: Key('live-group-$group'),
      padding: const EdgeInsets.only(right: 8),
      child: FolmePress(
        child: GlassChip(
          label: label,
          selected: selected,
          fontSize: 14,
          hitTarget: 48,
          proxListenable: _prox,
          onTap: () => setState(() => _group = group),
        ),
      ),
    );
  }
}
