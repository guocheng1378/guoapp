import 'package:flutter/material.dart';

import 'app_scaffold.dart';
import 'core_bridge.dart';
import 'floating_card.dart';
import 'live_source_entry.dart';
import 'local_store.dart';
import 'tvbox_import.dart';

/// 自定义直播源管理面板：增删自填 m3u/m3u8/txt 订阅、设置 EPG、TVBox 导入。
///
/// 同时被两处复用：
///  - 独立「直播源管理」页（[LiveSourcesScreen]）；
///  - 「内置站源」页里的「自定义直播源」分区（compact 模式）。
/// 逻辑只有一份，避免两处 UI 行为分叉。
class LiveSourcesPane extends StatefulWidget {
  const LiveSourcesPane({
    super.key,
    required this.store,
    required this.repository,
    this.compact = false,
  });

  final LocalStore store;
  final AppRepository repository;

  /// 嵌入「内置站源」页时隐藏大段说明卡，避免与其它分区重复占空间。
  final bool compact;

  @override
  State<LiveSourcesPane> createState() => _LiveSourcesPaneState();
}

class _LiveSourcesPaneState extends State<LiveSourcesPane> {
  bool _saving = false;

  List<LiveSourceEntry> get _entries => widget.store.liveSourceEntries;

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _save(List<LiveSourceEntry> entries) async {
    setState(() => _saving = true);
    try {
      await widget.store.setLiveSourceEntries(entries);
      if (!mounted) return;
      setState(() => _saving = false);
      _message('已保存 ${entries.length} 个直播源');
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _message('保存失败：$e');
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final url = await showFloatingDialog<String>(
      context: context,
      barrierLabel: '添加直播源',
      width: 320,
      title: const Text('添加直播源'),
      content: TextField(
        key: const Key('live-source-input'),
        controller: controller,
        autofocus: true,
        maxLines: 3,
        minLines: 1,
        decoration: const InputDecoration(
          hintText: 'https://…/live.m3u（m3u / m3u8 / txt 订阅链接）',
        ),
        onSubmitted: (value) => Navigator.of(context).pop(value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('live-source-confirm'),
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('添加'),
        ),
      ],
    );
    controller.dispose();
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      _message('直播源需以 http:// 或 https:// 开头');
      return;
    }
    if (_entries.any((entry) => entry.url == trimmed)) {
      _message('该直播源已存在');
      return;
    }
    await _save([..._entries, LiveSourceEntry(url: trimmed)]);
  }

  /// 给某条订阅设置节目单（EPG）地址；留空即取消关联。
  Future<void> _editEpg(LiveSourceEntry target) async {
    final controller = TextEditingController(text: target.epg);
    final value = await showFloatingDialog<String>(
      context: context,
      barrierLabel: '节目单地址',
      width: 340,
      title: const Text('节目单（EPG）'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'xmltv 格式地址（.xml / .xml.gz），留空表示不使用节目单。',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          TextField(
            key: const Key('live-epg-input'),
            controller: controller,
            autofocus: true,
            maxLines: 2,
            minLines: 1,
            decoration: const InputDecoration(
              hintText: 'https://…/epg.xml',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('live-epg-confirm'),
          onPressed: () => Navigator.of(context).pop(controller.text),
          child: const Text('保存'),
        ),
      ],
    );
    controller.dispose();
    if (value == null) return;
    final epg = LiveSourceEntry.sanitizeEpgUrl(value);
    if (value.trim().isNotEmpty && epg.isEmpty) {
      _message('节目单地址需以 http:// 或 https:// 开头');
      return;
    }
    await _save([
      for (final entry in _entries)
        entry.url == target.url ? entry.copyWith(epg: epg) : entry,
    ]);
  }

  Future<void> _remove(LiveSourceEntry target) async {
    await _save([
      for (final entry in _entries)
        if (entry.url != target.url) entry,
    ]);
  }

  /// 粘贴 TVBox 配置：直播订阅合并进本面板，CMS 站源同时下发 Go 核心。
  Future<void> _importTvbox() async {
    final plan = await showTvboxImportDialog(context);
    if (plan == null || !mounted) return;
    final outcome = await applyTvboxImport(
      store: widget.store,
      publish: (sources) => widget.repository.setCustomSources(sources),
      plan: plan,
    );
    if (!mounted) return;
    setState(() {});
    _message(
      outcome.errors.isEmpty
          ? outcome.summary
          : '${outcome.summary}\n${outcome.errors.first}',
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!widget.compact)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: SoftGlassCard(
              padding: const EdgeInsets.all(14),
              child: Text(
                '自填 m3u / m3u8 / txt 直播订阅链接，与内置直播列表合并显示；'
                '链接失效时自动跳过并提示。点日历图标可为每条订阅填 xmltv '
                '节目单地址，直播页会显示「正在播」并可长按看当日节目单。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.store.profile.admin)
                IconButton(
                  key: const Key('live-source-import-tvbox'),
                  tooltip: '导入 TVBox 配置（站源 + 直播源）',
                  icon: const Icon(Icons.file_download_outlined),
                  onPressed: _saving ? null : _importTvbox,
                ),
              IconButton(
                key: const Key('live-source-add'),
                tooltip: '添加直播源',
                icon: const Icon(Icons.add),
                onPressed: _saving ? null : _add,
              ),
            ],
          ),
        ),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              key: const Key('live-source-empty'),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.live_tv, size: 40, color: Colors.white38),
                  const SizedBox(height: 12),
                  const Text(
                    '暂无自填直播源',
                    style: TextStyle(color: Colors.white38),
                  ),
                ],
              ),
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: SoftGlassCard(
              padding: EdgeInsets.zero,
              child: ListView.builder(
                key: const Key('live-source-list'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  final entry = entries[index];
                  final flags = <String>[
                    if (entry.isInline) '内嵌频道',
                    if (entry.hasCustomHttp) '自定义请求头',
                    if (entry.hasEpg) 'EPG',
                  ];
                  return ListTile(
                    key: Key('live-source-item-$index'),
                    leading: const Icon(Icons.link),
                    title: Text(
                      entry.displayLabel,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    subtitle: flags.isEmpty ? null : Text(flags.join(' · ')),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          key: Key('live-source-epg-$index'),
                          tooltip: '设置节目单（EPG）',
                          icon: Icon(
                            entry.hasEpg
                                ? Icons.event_available
                                : Icons.event_outlined,
                          ),
                          onPressed: _saving ? null : () => _editEpg(entry),
                        ),
                        IconButton(
                          key: Key('live-source-remove-$index'),
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _saving ? null : () => _remove(entry),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
      ],
    );
  }
}
