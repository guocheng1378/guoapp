import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core_bridge.dart';
import 'custom_sources.dart';
import 'error_text.dart';
import 'folme.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'source_status.dart';
import 'app_icons.dart';

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
  final _expandedCategories = <String>{};
  Timer? _timer;
  bool _polling = false;
  bool _bulk = false;
  int _ticks = 0;

  @override
  void initState() {
    super.initState();
    // 从剧卡「站源诊断」进入时自动展开目标站源所在分类，其余分类默认收起。
    final initial = widget.initialSource;
    if (initial != null) {
      final site = SourceSite.byId(initial);
      if (site != null) _expandedCategories.add(_categoryIdOf(site));
    }
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
        for (final source in widget.store.permittedSources.where(
          (source) =>
              widget.store.restrictedUnlocked ||
              !(source.inHuangguoCategory || source.isAdultSource),
        ))
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
    final sources = widget.store.permittedSources
        .where(
          (source) =>
              widget.store.restrictedUnlocked ||
              !(source.inHuangguoCategory || source.isAdultSource),
        )
        .toList();
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

  /// 弹出添加自定义站源表单；成功后注册进站源菜单并全量下发 Go 核心。
  Future<void> _showAddCustomDialog() async {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    final typeIdController = TextEditingController();
    var category = 'shortDrama';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => GlassDialogShell(
          child: AlertDialog(
            title: const Text('添加自定义站源'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  key: const ValueKey('custom-source-name'),
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: '站源名称',
                    hintText: '例如：我的影视站',
                  ),
                ),
                TextField(
                  key: const ValueKey('custom-source-url'),
                  controller: urlController,
                  decoration: const InputDecoration(
                    labelText: '接口地址（http/https）',
                    hintText: 'https://example.com/api.php/provide/vod',
                  ),
                ),
                const SizedBox(height: 12),
                SegmentedButton<String>(
                  segments: [
                    for (final item in CustomSourceSpec.categories)
                      ButtonSegment(
                        value: item,
                        label: Text(CustomSourceSpec.categoryLabel(item)),
                      ),
                  ],
                  selected: {category},
                  onSelectionChanged: (value) =>
                      setDialogState(() => category = value.first),
                ),
                TextField(
                  key: const ValueKey('custom-source-type-id'),
                  controller: typeIdController,
                  decoration: const InputDecoration(
                    labelText: '分类 ID（可选，源站 type_id）',
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                key: const ValueKey('custom-source-submit'),
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('添加'),
              ),
            ],
          ),
        ),
      ),
    );
    final name = nameController.text;
    final url = urlController.text;
    final typeId = typeIdController.text;
    nameController.dispose();
    urlController.dispose();
    typeIdController.dispose();
    if (confirmed != true || !mounted) return;
    try {
      await widget.store.addCustomSource(
        name: name,
        url: url,
        category: category,
        typeId: typeId,
      );
    } catch (error) {
      _showMessage(friendlyError(error));
      return;
    }
    // store 已注册进 SourceSite（站源菜单即时可见），这里全量下发 Go 核心。
    await widget.repository.setCustomSources(widget.store.customSources);
    _showMessage('自定义站源已添加');
  }

  /// 删除自定义站源：本地落盘 + 全量下发 Go 核心 + 清理本页轮询状态。
  Future<void> _removeCustom(SourceSite source) async {
    try {
      await widget.store.removeCustomSource(source.id);
    } catch (error) {
      _showMessage(friendlyError(error));
      return;
    }
    await widget.repository.setCustomSources(widget.store.customSources);
    if (mounted) {
      setState(() {
        _statuses.remove(source.id);
        _errors.remove(source.id);
        _revisions.remove(source.id);
      });
    }
    _showMessage('已删除自定义站源');
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
      final unlocked = widget.store.restrictedUnlocked;
      final sources = widget.store.permittedSources
        .where(
          (source) =>
              unlocked ||
              !(source.inHuangguoCategory || source.isAdultSource),
        )
        .toList()
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
            if (widget.store.profile.admin)
              IconButton(
                key: const ValueKey('sources-add-custom'),
                tooltip: '添加自定义站源',
                onPressed: _showAddCustomDialog,
                icon: AppIcon(AppIcons.add),
              ),
            if (widget.store.profile.admin && sources.isNotEmpty) ...[
              IconButton(
                key: const ValueKey('sources-enable-all'),
                tooltip: '一键开启全部（受限站源需要管理员密码）',
                onPressed: _bulk ? null : () => _setAll(true),
                icon: AppIcon(AppIcons.doneAll),
              ),
              IconButton(
                key: const ValueKey('sources-disable-all'),
                tooltip: '一键关闭全部',
                onPressed: _bulk ? null : () => _setAll(false),
                icon: AppIcon(AppIcons.removeDone),
              ),
            ],
          ],
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: FogRefresh(
              onRefresh: () {
                HapticFeedback.mediumImpact();
                return _refresh();
              },
              // 胶囊停在视口顶 6px（视口顶已在顶栏之下）。
              displacement: 6,
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

  /// 站源归属的分类 id（与 _categorizedSources 的分区一致）。
  String _categoryIdOf(SourceSite site) {
    if (site.inHuangguoCategory) return 'huangguo';
    if (site.isAdultSource) return 'adult';
    if (site.isShortDrama) return 'short';
    return 'video';
  }

  List<Widget> _categorizedSources(List<SourceSite> sources) {
    // 四分类：短剧类 / 视频类 / 黄果类 / 成人类。每组默认收起，点区头展开，
    // 避免几十个源卡把页面拉得过长；黄果类成员（黄果系入口 + 黄豆/野果/剧果）
    // 抽出独立成区；成人类源默认关闭、开启需管理员密码。
    // 黄果类与成人类整组隐藏，仅在「关于」浮卡连点 5 次解锁后显示
    // （调用方已按 restrictedUnlocked 过滤入参）。
    final huangguo = sources
        .where((site) => site.inHuangguoCategory)
        .toList();
    final rest = sources
        .where((site) => !site.inHuangguoCategory)
        .toList();
    final shortDrama = rest.where((site) => site.isShortDrama).toList();
    final video = rest.where((site) => site.isVideoSource).toList();
    final adult = rest.where((site) => site.isAdultSource).toList();
    return [
      if (shortDrama.isNotEmpty)
        _categorySection(
          id: 'short',
          title: '短剧类',
          count: shortDrama.length,
          icon: AppIcon(AppIcons.smartDisplay, size: 20),
          subtitle: '竖屏短剧',
          sources: shortDrama,
        ),
      if (video.isNotEmpty)
        _categorySection(
          id: 'video',
          title: '视频类',
          count: video.length,
          icon: AppIcon(AppIcons.movie, size: 20),
          subtitle: '横版播放 · 多线路与清晰度',
          sources: video,
        ),
      if (huangguo.isNotEmpty)
        _categorySection(
          id: 'huangguo',
          title: '黄果类',
          count: huangguo.length,
          icon: AppIcon(AppIcons.hub, size: 20),
          subtitle: '黄果系入口 · 精选与热门短剧',
          sources: huangguo,
        ),
      if (adult.isNotEmpty)
        _categorySection(
          id: 'adult',
          title: '成人类',
          count: adult.length,
          icon: AppIcon(AppIcons.lock, size: 20),
          subtitle: '默认关闭 · 开启需管理员密码',
          sources: adult,
        ),
    ];
  }

  Widget _categorySection({
    required String id,
    required String title,
    required int count,
    required Widget icon,
    required String subtitle,
    required List<SourceSite> sources,
  }) {
    final expanded = _expandedCategories.contains(id);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey('category-toggle-$id'),
          onTap: () => setState(() {
            if (expanded) {
              _expandedCategories.remove(id);
            } else {
              _expandedCategories.add(id);
            }
          }),
          borderRadius: BorderRadius.circular(8),
          child: _categoryHeader(
            title,
            count,
            icon,
            subtitle,
            expanded: expanded,
          ),
        ),
        if (expanded) ..._sourceGroupsOf(sources),
      ],
    );
  }

  Widget _categoryHeader(
    String title,
    int count,
    Widget icon,
    String subtitle, {
    required bool expanded,
  }) => Padding(
    padding: const EdgeInsets.only(top: 4, bottom: 12),
    child: Row(
      children: [
        icon,
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
        const SizedBox(width: 8),
        expanded
            ? AppIcon(AppIcons.expandLess)
            : AppIcon(AppIcons.expandMore),
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
        AppIcon(AppIcons.dns),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            source.name,
            style: Theme.of(context).textTheme.titleLarge,
          ),
        ),
        if (switchedOn) Text('${status?.count ?? 0} 部'),
        // 自定义站源专属：删除入口（设备级配置，管理员即可，无需密码）。
        if (admin && source.id.startsWith('custom-'))
          IconButton(
            key: ValueKey('delete-${source.id}'),
            tooltip: '删除自定义站源',
            onPressed: () => _removeCustom(source),
            icon: AppIcon(AppIcons.delete),
          ),
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
              Text(
                source.loginRequired
                    ? '站点已要求登录才能播放（App 内无法使用），默认关闭；站点恢复匿名可播后可再开启'
                    : admin
                    ? '已关闭，开启后在首页、搜索和记录中显示'
                    : '已关闭，仅管理员可以开启',
              ),
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
            if (source.loginRequired)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '站点要求登录后才能播放：目录可浏览，播放会失败',
                  style: TextStyle(color: colors.error),
                ),
              ),
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
                  icon: AppIcon(AppIcons.sync),
                  label: const Text('更新'),
                ),
                OutlinedButton.icon(
                  key: ValueKey('check-${source.id}'),
                  onPressed: enabled ? () => _run(source, 'check') : null,
                  icon: AppIcon(AppIcons.networkCheck),
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
                      icon: AppIcon(AppIcons.save),
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
                              healthExpanded
                                  ? AppIcon(AppIcons.expandLess)
                                  : AppIcon(AppIcons.expandMore),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '复制诊断信息',
                    onPressed: () => _copy(source, status!),
                    icon: AppIcon(AppIcons.copy),
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
                        step.state == 'ok'
                            ? AppIcon(AppIcons.checkCircle,
                                size: 20, color: colors.primary)
                            : AppIcon(AppIcons.error,
                                size: 20, color: colors.error),
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
    icon: AppIcon(AppIcons.networkCheck),
    label: const Text('站源诊断'),
  );
}
