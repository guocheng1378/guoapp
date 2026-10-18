import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'source_status.dart';

String sourceTimestamp(DateTime? value) {
  if (value == null) return '尚无记录';
  final local = value.toLocal();
  String two(int number) => number.toString().padLeft(2, '0');
  return '${local.month}/${local.day} ${two(local.hour)}:${two(local.minute)}';
}

class SourcesScreen extends StatefulWidget {
  const SourcesScreen({
    super.key,
    required this.repository,
    required this.store,
    this.initialSource,
    this.drama,
  });

  final AppRepository repository;
  final LocalStore store;
  final String? initialSource;
  final Drama? drama;

  @override
  State<SourcesScreen> createState() => _SourcesScreenState();
}

class _SourcesScreenState extends State<SourcesScreen> {
  final _statuses = <String, SourceStatus>{};
  final _errors = <String, String>{};
  final _pending = <String>{};
  final _revisions = <String, int>{};
  final _expandedHealth = <String>{};
  Timer? _timer;
  bool _polling = false;
  bool _bulk = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    unawaited(_refresh());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      _ticks++;
      if (_statuses.values.any((status) => status.retryAt != null)) {
        setState(() {});
      }
      if (_ticks % 2 == 0 &&
          (_statuses.values.any((status) => status.running) ||
              _ticks % 10 == 0)) {
        unawaited(_refresh());
      }
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    final epoch = widget.store.profileEpoch;
    try {
      await Future.wait([
        for (final source in widget.store.permittedSources)
          (() async {
            final revision = _revisions[source.id] ?? 0;
            try {
              final status = await widget.repository.sourceStatus(source.id);
              if (!mounted ||
                  epoch != widget.store.profileEpoch ||
                  revision != (_revisions[source.id] ?? 0)) {
                return;
              }
              setState(() {
                _statuses[source.id] = status;
                _errors.remove(source.id);
              });
            } catch (error) {
              if (mounted &&
                  epoch == widget.store.profileEpoch &&
                  revision == (_revisions[source.id] ?? 0)) {
                setState(() => _errors[source.id] = error.toString());
              }
            }
          })(),
      ]);
    } finally {
      _polling = false;
    }
  }

  Future<void> _run(SourceSite source, String operation) async {
    if (_pending.contains(source.id)) return;
    final epoch = widget.store.profileEpoch;
    setState(() {
      _pending.add(source.id);
      _errors.remove(source.id);
      _revisions[source.id] = (_revisions[source.id] ?? 0) + 1;
      if (operation == 'check' || operation == 'checkCatalog') {
        _expandedHealth.add(source.id);
      }
    });
    try {
      final status = operation == 'cancel'
          ? await widget.repository.cancelSourceJob(source.id)
          : await widget.repository.startSourceJob(
              source.id,
              operation,
              drama: source.id == widget.drama?.source ? widget.drama : null,
            );
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _statuses[source.id] = status);
      }
    } catch (error) {
      if (mounted && epoch == widget.store.profileEpoch) {
        setState(() => _errors[source.id] = error.toString());
      }
    } finally {
      if (mounted) setState(() => _pending.remove(source.id));
    }
  }

  /// 弹出一次管理员密码验证。ok 为 false 表示用户取消，error 非空表示验证失败。
  Future<({bool ok, String? error})> _askAdminPin(String title) async {
    final pinController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => GlassDialogShell(
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: pinController,
            obscureText: true,
            autofocus: true,
            decoration: const InputDecoration(labelText: '管理员密码'),
            onSubmitted: (_) => Navigator.pop(ctx, true),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('确认'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) {
      pinController.dispose();
      return (ok: false, error: null);
    }
    final error = await widget.store.verifyAdminPin(pinController.text);
    pinController.dispose();
    if (!mounted) return (ok: false, error: null);
    return (ok: true, error: error);
  }

  void _showMessage(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _toggle(SourceSite source, bool enabled) async {
    setState(() => _errors.remove(source.id));
    if (enabled && SourceSite.isRestricted(source.id)) {
      final result = await _askAdminPin('开启 ${source.name} 需要密码');
      if (!result.ok) return;
      if (result.error != null) {
        setState(() => _errors[source.id] = result.error!);
        return;
      }
    }
    try {
      await widget.store.setSourceEnabled(source.id, enabled);
      if (enabled) unawaited(_refresh());
    } catch (error) {
      if (mounted) setState(() => _errors[source.id] = error.toString());
    }
  }

  /// 一键开启/关闭当前用户可见的全部站源：一次验证密码、一次提交。
  Future<void> _setAll(bool enabled) async {
    if (_bulk) return;
    final sources = widget.store.permittedSources;
    if (sources.isEmpty) return;
    setState(() {
      _bulk = true;
      _errors.clear();
    });
    try {
      if (enabled &&
          sources.any((source) => SourceSite.isRestricted(source.id))) {
        final result = await _askAdminPin('开启全部站源需要密码');
        if (!result.ok || !mounted) return;
        if (result.error != null) {
          _showMessage(result.error!);
          return;
        }
      }
      await widget.store.setSourceSwitches({
        for (final source in sources) source.id: enabled,
      });
      if (enabled) unawaited(_refresh());
    } catch (error) {
      _showMessage(error.toString());
    } finally {
      if (mounted) setState(() => _bulk = false);
    }
  }

  Future<void> _copy(SourceSite source, SourceStatus status) async {
    final text = StringBuffer('${source.name}\n');
    text.writeln(
      '缓存 ${status.count} 部，更新 ${sourceTimestamp(status.updatedAt)}',
    );
    final health = status.health;
    if (health != null) {
      text.writeln('${health.label} · ${sourceTimestamp(health.checkedAt)}');
      if (health.sample.isNotEmpty) text.writeln('检测剧集：${health.sample}');
      for (final step in health.steps) {
        text.writeln('${step.name}：${step.message}');
        text.writeln(
          '${step.host} HTTP ${step.httpStatus} · ${step.elapsedMs} ms',
        );
        if (step.cfRay.isNotEmpty) text.writeln('CF Ray: ${step.cfRay}');
      }
    }
    if (status.error.isNotEmpty) text.writeln(status.error);
    if (status.storageError.isNotEmpty) text.writeln(status.storageError);
    await Clipboard.setData(ClipboardData(text: text.toString()));
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('诊断信息已复制')));
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) {
      final sources = widget.store.permittedSources
        ..sort((a, b) {
          final aFirst = a.id == widget.initialSource ? 0 : 1;
          final bFirst = b.id == widget.initialSource ? 0 : 1;
          return aFirst.compareTo(bFirst);
        });
      final viewPaddingBottom = MediaQuery.viewPaddingOf(context).bottom;
      final paddingBottom = MediaQuery.paddingOf(context).bottom;
      final bottomInset = viewPaddingBottom > paddingBottom
          ? viewPaddingBottom
          : paddingBottom;
      return Scaffold(
        appBar: AppBar(
          flexibleSpace: const TopFog(),
          title: const Text('站源管理'),
          actions: [
            if (widget.store.profile.admin && sources.isNotEmpty) ...[
              IconButton(
                key: const ValueKey('sources-enable-all'),
                tooltip: '一键开启全部（受限站源需要管理员密码）',
                onPressed: _bulk ? null : () => _setAll(true),
                icon: const Icon(Icons.done_all_rounded),
              ),
              IconButton(
                key: const ValueKey('sources-disable-all'),
                tooltip: '一键关闭全部',
                onPressed: _bulk ? null : () => _setAll(false),
                icon: const Icon(Icons.remove_done_rounded),
              ),
            ],
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: RefreshIndicator(
              onRefresh: () {
                HapticFeedback.mediumImpact();
                return _refresh();
              },
              child: ListView(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + bottomInset),
                children: [
                  const Padding(
                    padding: EdgeInsets.only(bottom: 16),
                    child: Text(
                      '各站源可分别更新和检测。更新会查找新剧、继续加载一页历史内容，并分批补齐资料；离开此页后任务继续。',
                    ),
                  ),
                  if (sources.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(24),
                      child: Text('当前用户没有可用站源'),
                    ),
                  ..._categorizedSources(sources),
                ],
              ),
            ),
          ),
        ),
      );
    },
  );

  List<Widget> _categorizedSources(List<SourceSite> sources) {
    // 三分类：短剧类 / 视频类 / 黄果类。黄果类成员（黄果系入口 + 黄豆/野果/
    // 剧果）抽出独立成区，受限名单即黄果类；黄果系各入口平铺独立卡片。
    final huangguo = sources
        .where((site) => site.inHuangguoCategory)
        .toList();
    final rest = sources
        .where((site) => !site.inHuangguoCategory)
        .toList();
    final shortDrama = rest.where((site) => site.isShortDrama).toList();
    final video = rest.where((site) => site.isVideoSource).toList();
    return [
      if (shortDrama.isNotEmpty) ...[
        _categoryHeader(
          '短剧类',
          shortDrama.length,
          Icons.smart_display_outlined,
          '竖屏短剧',
        ),
        ..._sourceGroupsOf(shortDrama),
      ],
      if (video.isNotEmpty) ...[
        _categoryHeader(
          '视频类',
          video.length,
          Icons.movie_outlined,
          '横版播放 · 多线路与清晰度',
        ),
        ..._sourceGroupsOf(video),
      ],
      if (huangguo.isNotEmpty) ...[
        _categoryHeader(
          '黄果类',
          huangguo.length,
          Icons.hub_outlined,
          '黄果系入口 · 精选与热门短剧',
        ),
        ..._sourceGroupsOf(huangguo),
      ],
    ];
  }

  Widget _categoryHeader(
    String title,
    int count,
    IconData icon,
    String subtitle,
  ) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 12),
    child: Row(
      children: [
        Icon(icon, size: 20),
        const SizedBox(width: 8),
        Text(title, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(width: 8),
        Text('$count 个'),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    ),
  );

  List<Widget> _sourceGroupsOf(List<SourceSite> sources) {
    // 黄果系各入口（AI/旧版等）与其它类一致：groupId 已按源拆分，
    // 全部平铺成独立卡片，仅靠黄果类区头归拢。
    return [
      for (final group in SourceGroup.fromSources(sources))
        for (final source in group.sources) _sourceCard(source),
    ];
  }

  Widget _sourceCard(SourceSite source) {
    final status = _statuses[source.id];
    final pending = _pending.contains(source.id);
    final busy = pending || status?.running == true;
    final seconds = status?.retrySeconds ?? 0;
    final enabled =
        !busy && seconds == 0 && widget.repository.supportsSourceManagement;
    final error = _errors[source.id] ?? status?.error ?? '';
    final health = status?.health;
    final healthExpanded = _expandedHealth.contains(source.id);
    final colors = Theme.of(context).colorScheme;
    final switchedOn = widget.store.sourceEnabled(source.id);
    final admin = widget.store.profile.admin;
    final header = Row(
      children: [
        const Icon(Icons.dns_outlined),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            source.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (switchedOn) Text('${status?.count ?? 0} 部'),
        const SizedBox(width: 8),
        Switch(
          key: ValueKey('switch-${source.id}'),
          value: switchedOn,
          onChanged: admin ? (value) => _toggle(source, value) : null,
        ),
      ],
    );
    if (!switchedOn) {
      final closedError = _errors[source.id] ?? '';
      return Card(
        key: ValueKey('source-${source.id}'),
        margin: const EdgeInsets.only(bottom: 16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              header,
              const SizedBox(height: 8),
              Text(admin ? '已关闭，开启后在首页、搜索和记录中显示' : '已关闭，仅管理员可以开启'),
              if (closedError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    closedError,
                    style: TextStyle(color: colors.error),
                  ),
                ),
            ],
          ),
        ),
      );
    }
    return Card(
      key: ValueKey('source-${source.id}'),
      margin: const EdgeInsets.only(bottom: 16),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            header,
            const SizedBox(height: 8),
            Text('最近更新：${sourceTimestamp(status?.updatedAt)}'),
            if (status != null && status.count > 0)
              Text(
                '已加载至第 ${status.page} 页${status.hasMore ? ' · 可继续加载' : ' · 当前分页已加载完'}',
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                FilledButton.icon(
                  key: ValueKey('update-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'update') : null,
                  icon: const Icon(Icons.sync_rounded),
                  label: const Text('更新'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('check-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'check') : null,
                  icon: const Icon(Icons.network_check),
                  label: const Text('检测连接与播放'),
                ),
                if (status?.running == true)
                  TextButton(
                    onPressed: pending ? null : () => _run(source, 'cancel'),
                    child: const Text('停止'),
                  ),
                PopupMenuButton<String>(
                  tooltip: '${source.name}更多操作',
                  enabled: enabled,
                  onSelected: (operation) => _run(source, operation),
                  itemBuilder: (_) => [
                    PopupMenuItem(
                      value: 'more',
                      enabled: status?.hasMore ?? true,
                      child: const Text('继续加载一页'),
                    ),
                    const PopupMenuItem(value: 'metadata', child: Text('补齐资料')),
                    if (source.id == 'huangdou')
                      PopupMenuItem(
                        value: 'vipMetadata',
                        enabled: (status?.unknownVip ?? 0) > 0,
                        child: Text('补齐 VIP 资料（${status?.unknownVip ?? 0} 部）'),
                      ),
                    const PopupMenuItem(
                      value: 'checkCatalog',
                      child: Text('仅检测目录'),
                    ),
                  ],
                ),
              ],
            ),
            if (busy) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: status != null && status.total > 0
                    ? (status.completed / status.total).clamp(0, 1)
                    : null,
              ),
              const SizedBox(height: 8),
              Text(
                '${status?.stage ?? '准备中'}${(status?.total ?? 0) > 0 ? ' · ${status!.completed}/${status.total}' : ''}',
              ),
            ] else if (status != null && status.stage.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text(
                '${status.stage}${status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
              ),
            ],
            if (seconds > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '请在 $seconds 秒后重试',
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (error.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: SelectableText(
                  error,
                  style: TextStyle(color: colors.error),
                ),
              ),
            if (status != null && status.storageError.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      status.storageError,
                      style: TextStyle(color: colors.error),
                    ),
                    TextButton.icon(
                      key: ValueKey('save-${source.id}'),
                      onPressed:
                          !busy && widget.repository.supportsSourceManagement
                          ? () => _run(source, 'retrySave')
                          : null,
                      icon: const Icon(Icons.save_outlined),
                      label: const Text('重试保存'),
                    ),
                  ],
                ),
              ),
            if (health != null) ...[
              const Divider(height: 28),
              Row(
                children: [
                  Expanded(
                    child: Semantics(
                      expanded: healthExpanded,
                      child: Tooltip(
                        message: healthExpanded ? '收起检测详情' : '展开检测详情',
                        child: TextButton(
                          key: ValueKey('health-toggle-${source.id}'),
                          onPressed: () => setState(() {
                            if (healthExpanded) {
                              _expandedHealth.remove(source.id);
                            } else {
                              _expandedHealth.add(source.id);
                            }
                          }),
                          style: TextButton.styleFrom(
                            foregroundColor: colors.onSurface,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 8,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(health.label),
                                    Text(
                                      sourceTimestamp(health.checkedAt),
                                      style: Theme.of(
                                        context,
                                      ).textTheme.bodySmall,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                healthExpanded
                                    ? Icons.expand_less_rounded
                                    : Icons.expand_more_rounded,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制诊断信息',
                    onPressed: () => _copy(source, status!),
                    icon: const Icon(Icons.copy_rounded),
                  ),
                ],
              ),
              if (healthExpanded) ...[
                if (health.sample.isNotEmpty) Text('检测剧集：${health.sample}'),
                for (final step in health.steps)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          step.state == 'ok'
                              ? Icons.check_circle_outline
                              : Icons.error_outline,
                          size: 20,
                          color: step.state == 'ok'
                              ? colors.primary
                              : colors.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('${step.name}：${step.message}'),
                              if (step.host.isNotEmpty || step.httpStatus > 0)
                                Text(
                                  '${step.host}${step.httpStatus > 0 ? ' · HTTP ${step.httpStatus}' : ''} · ${step.elapsedMs} ms',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ] else ...[
              const SizedBox(height: 12),
              const Text('尚未检测连接'),
            ],
          ],
        ),
      ),
    );
  }
}

class SourceDiagnosticsButton extends StatelessWidget {
  const SourceDiagnosticsButton({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
  });
  final AppRepository repository;
  final LocalStore store;
  final Drama drama;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: repository,
          store: store,
          initialSource: drama.source,
          drama: drama,
        ),
      ),
    ),
    icon: const Icon(Icons.network_check),
    label: const Text('站源诊断'),
  );
}
