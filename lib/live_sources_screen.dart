import 'package:flutter/material.dart';

import 'local_store.dart';

/// 直播源管理页（2026-10-22）：增删自填 m3u/m3u8/txt 订阅 URL（设备级），
/// 打开直播页时与内置双列表合并；每次增删即时保存。
class LiveSourcesScreen extends StatefulWidget {
  const LiveSourcesScreen({super.key, required this.store});
  final LocalStore store;
  @override
  State<LiveSourcesScreen> createState() => _LiveSourcesScreenState();
}

class _LiveSourcesScreenState extends State<LiveSourcesScreen> {
  bool _saving = false;

  List<String> get _urls => widget.store.liveSourceUrls;

  Future<void> _save(List<String> urls) async {
    setState(() => _saving = true);
    try {
      await widget.store.setLiveSourceUrls(urls);
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('已保存 ${urls.length} 个直播源')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(SnackBar(content: Text('保存失败：$e')));
    }
  }

  Future<void> _add() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        key: const Key('live-source-dialog'),
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
      ),
    );
    controller.dispose();
    final trimmed = url?.trim() ?? '';
    if (trimmed.isEmpty) return;
    if (!trimmed.startsWith('http://') && !trimmed.startsWith('https://')) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          const SnackBar(content: Text('直播源需以 http:// 或 https:// 开头')),
        );
      return;
    }
    if (_urls.contains(trimmed)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('该直播源已存在')));
      return;
    }
    await _save([..._urls, trimmed]);
  }

  Future<void> _remove(String url) async {
    await _save([for (final row in _urls) if (row != url) row]);
  }

  @override
  Widget build(BuildContext context) {
    final urls = _urls;
    return Scaffold(
      appBar: AppBar(
        title: const Text('直播源管理'),
        actions: [
          IconButton(
            key: const Key('live-source-add'),
            tooltip: '添加直播源',
            icon: const Icon(Icons.add),
            onPressed: _saving ? null : _add,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Text(
              '自填 m3u / m3u8 / txt 直播订阅链接，与内置直播列表合并显示；'
              '链接失效时自动跳过并提示。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: urls.isEmpty
                ? Center(
                    key: const Key('live-source-empty'),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.live_tv,
                          size: 40,
                          color: Colors.white38,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          '暂无自填直播源',
                          style: TextStyle(color: Colors.white38),
                        ),
                        const SizedBox(height: 16),
                        FilledButton.icon(
                          onPressed: _saving ? null : _add,
                          icon: const Icon(Icons.add),
                          label: const Text('添加直播源'),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    key: const Key('live-source-list'),
                    itemCount: urls.length,
                    itemBuilder: (context, index) {
                      final url = urls[index];
                      return ListTile(
                        key: Key('live-source-item-$index'),
                        leading: const Icon(Icons.link),
                        title: Text(
                          url,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: IconButton(
                          key: Key('live-source-remove-$index'),
                          tooltip: '删除',
                          icon: const Icon(Icons.delete_outline),
                          onPressed: _saving ? null : () => _remove(url),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
