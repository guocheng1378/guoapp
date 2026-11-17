import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'error_text.dart';
import 'folme.dart';
import 'glass.dart';
import 'live_epg_sheet.dart';
import 'live_models.dart';
import 'live_player_screen.dart';
import 'live_source_entry.dart';

/// 电视直播页（2026-10-22）：内置双 m3u 列表源一键切换 + 自填源合并展示。
/// 直播不进站源体系，数据全部来自 Go core `live.channels`。
/// UI（2026-10-23）：对齐主页玻璃体系——TopFog 雾面顶栏 + FogPill 胶囊岛 +
/// GlassChip 分组胶囊 + GlassSurface 频道卡 + FolmePress 按压手感。
class LiveScreen extends StatefulWidget {
  const LiveScreen({
    super.key,
    required this.repository,
    this.liveUrls = const [],
    this.liveSources = const [],
    this.initialListId = '',
    this.onPlayChannel,
  });
  final AppRepository repository;
  final List<String> liveUrls;
  final List<LiveSourceEntry> liveSources;
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

  /// 当前分组的节目单：没有配置 EPG 源时恒为 [LiveEpg.empty]，所有 UI 自动降级。
  LiveEpg _epg = LiveEpg.empty;

  /// EPG 请求代号：切分组/刷新时丢弃过期响应，避免旧组的节目串到新组上。
  int _epgSerial = 0;

  /// 单次 EPG 请求的频道上限（与 Go 侧 liveEpgMaxRefs 对齐）。
  static const int _epgChannelLimit = 200;

  /// 频道列表请求代号：加载中连点「切换列表」会并发两个请求，后者必须赢，
  /// 否则旧响应会把 _page/_listId 覆盖回去（显示错误列表且下次进页仍错）。
  int _loadSerial = 0;

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
    final serial = ++_loadSerial;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final page = widget.liveSources.isEmpty
          ? await widget.repository.liveChannels(
              listId: _listId,
              liveUrls: widget.liveUrls,
              force: force,
            )
          : await widget.repository.liveChannelsWithSources(
              listId: _listId,
              liveSources: widget.liveSources,
              force: force,
            );
      // 切列表时旧请求可能后到：不校验代次就会把 A 的频道盖到 B 上，
      // 界面打勾的是 B、内容是 A，且要再点一次才能纠正。
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _page = page;
        _listId = page.listId;
        if (_group.isNotEmpty &&
            !page.groups.any((group) => group.name == _group)) {
          _group = '';
        }
      });
      // 频道到手后再补节目单：EPG 是增强信息，晚到不影响列表可用。
      _loadEpg();
    } catch (e) {
      if (!mounted || serial != _loadSerial) return;
      setState(() {
        _loading = false;
        _error = friendlyError(e);
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

  /// 为当前可见频道拉取节目单。
  ///
  /// 只请求当前分组的前 200 个频道：整份列表可达 3000 个，全部请求会让 xmltv
  /// 匹配与回传体积翻十几倍，而屏幕外的节目单没有意义。
  Future<void> _loadEpg() async {
    final sources = [
      for (final entry in widget.liveSources)
        if (entry.hasEpg) entry,
    ];
    if (sources.isEmpty) {
      if (mounted && !_epg.isEmpty) setState(() => _epg = LiveEpg.empty);
      return;
    }
    final channels = _visibleChannels.take(_epgChannelLimit).toList();
    if (channels.isEmpty) return;
    final serial = ++_epgSerial;
    try {
      final epg = await widget.repository.liveEpg(
        epgSources: sources,
        channels: channels,
      );
      if (!mounted || serial != _epgSerial) return;
      setState(() => _epg = epg);
    } catch (_) {
      // 节目单失败静默：频道列表照常可用，不弹错误。
    }
  }

  LiveEpgChannel? _epgChannelFor(LiveChannel channel) =>
      _epg.find(channel.name, tvgId: channel.tvgId);

  /// 长按频道卡看当日节目单（与主页剧卡长按同一手势习惯）。
  void _openEpgSheet(LiveChannel channel) {
    final epgChannel = _epgChannelFor(channel);
    if (epgChannel == null || epgChannel.programs.isEmpty) {
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              widget.liveSources.any((entry) => entry.hasEpg)
                  ? '「${channel.name}」暂无节目单数据'
                  : '未配置节目单（EPG）地址，可在直播源管理里填写',
            ),
          ),
        );
      return;
    }
    showLiveEpgSheet(context, channel: epgChannel);
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
          epg: _epg,
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
        // 顶栏雾面（渐变模糊 + 官方三层混色）。
        flexibleSpace: const TopFog(),
        // 分组条挂进 AppBar：flexibleSpace 的雾面会连同状态栏、顶栏、分组条
        // 均匀盖成一整块，与主页「顶栏 + 吸顶分类条」同形态（此前分组条在
        // body 里，只有顶栏那条有雾，下面是一截纯色背景带）。
        bottom: page == null || page.groups.isEmpty
            ? null
            : PreferredSize(
                preferredSize: const Size.fromHeight(48),
                child: _groupBar(page),
              ),
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

  /// 频道分组胶囊条（挂在 AppBar.bottom，随顶栏一起被雾面覆盖）。
  Widget _groupBar(LivePage page) => SingleChildScrollView(
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
  );

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
              // 形态：方形圆角矩形（宽扁提示条不做药丸）。
              borderRadius: BorderRadius.circular(14),
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
  /// 不可播频道（playable=false）整卡置灰并标注「暂无线路」——
  /// 仍可点击（给「暂无可用线路」反馈），但视觉上与可播频道区分开，
  /// 不再是「长得一样、点了才知道不能看」。
  Widget _channelRow(
    BuildContext context,
    ColorScheme scheme,
    LiveChannel channel,
  ) {
    final playable = channel.playable;
    final banner = liveEpgBanner(_epgChannelFor(channel), DateTime.now());
    return Opacity(
      opacity: playable ? 1 : .45,
      child: Padding(
        key: Key('live-channel-${channel.name}'),
        padding: const EdgeInsets.only(bottom: 8),
        child: FolmePress(
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: () => _openChannel(channel),
            // 长按看节目单：只在有 EPG 数据时提供，避免手势做了没反馈。
            onLongPress: () => _openEpgSheet(channel),
            child: GlassSurface(
              radius: 16,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
                child: Row(
                  children: [
                    _channelAvatar(scheme, channel),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            channel.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          if (banner != null)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                banner,
                                key: Key('live-now-${channel.name}'),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (!playable) ...[
                      const SizedBox(width: 8),
                      Text(
                        '暂无线路',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ] else if (channel.urls.length > 1) ...[
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
                // 台标显示 38px，按 2× 解码即可；源站台标常是几百 px 大图，
                // 上千频道逐张全尺寸解码会明显吃内存/掉帧。
                image: ResizeImage(NetworkImage(channel.logo), width: 76),
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
          onTap: () {
            setState(() => _group = group);
            _loadEpg();
          },
        ),
      ),
    );
  }
}
