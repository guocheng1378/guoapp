import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'app_build.dart';
import 'core_bridge.dart';
import 'floating_card.dart';
import 'local_store.dart';
import 'models.dart';
import 'sources_screen.dart';

/// 把核心返回的模块列表登记进 SourceSite（站源菜单/管理页/授权自动感知）。
///
/// 与官方站源同名的模块不重复登记（由 SourceSite 内部去重）：模块只是把内置源
/// 的实现换成 JS，界面口径仍以官方表为准。
void applySourceModules(List<Map<String, dynamic>> modules) {
  SourceSite.registerModuleSites([
    for (final module in modules)
      if ((module['id'] as String? ?? '').isNotEmpty)
        if (!(module['requiresAllSources'] as bool? ?? false) ||
            allSourcesEnabled)
          SourceSite(
            module['id'] as String,
            (module['name'] as String?)?.trim().isNotEmpty == true
                ? module['name'] as String
                : module['id'] as String,
            (module['description'] as String?) ?? '',
            categoryOverride: sourceModuleCategoryFor(module),
          ),
  ]);
}

/// 模块的站源分类：adult 标记与成人源 id 优先判成人（manifest 的 category
/// 偶尔缺失或写成 shortDrama，光看 category 会让成人模块混进短剧类并绕过
/// 「关于」解锁隐藏），其余按 manifest 的 category 归类。
SourceCategory sourceModuleCategoryFor(Map<String, dynamic> module) {
  final id = module['id'] as String? ?? '';
  // 上游的 adult 是「受限」标记：黄果系（huangju/yeguo/heitao…）也标 true，
  // 但它们按 id 归黄果类，不能被误判成成人内容——先放过黄果系。
  if (SourceSite.huangguoCategoryIds.contains(id)) {
    return sourceModuleCategory(module['category'] as String?);
  }
  if (module['adult'] == true || SourceSite.adultCategoryIds.contains(id)) {
    return SourceCategory.adult;
  }
  return sourceModuleCategory(module['category'] as String?);
}

SourceCategory sourceModuleCategory(String? raw) {
  switch (raw?.trim().toLowerCase()) {
    case 'video':
      return SourceCategory.video;
    case 'adult':
      return SourceCategory.adult;
    default:
      return SourceCategory.shortDrama;
  }
}

/// 模块 manifest 的能力名 → 中文展示。核心返回的是英文标识（catalog/detail/
/// search 等），未识别的能力原样显示，避免信息丢失。
const _moduleCapabilityLabels = <String, String>{
  'catalog': '目录浏览',
  'detail': '详情解析',
  'search': '搜索',
  'suggestions': '搜索建议',
  'recommendations': '相关推荐',
  'danmaku': '弹幕',
  'cover': '封面',
  'metadata': '补充资料',
  'rankings': '榜单',
  'mediaauth': '播放凭证',
  'catalogstate': '目录状态',
};

String moduleCapabilityLabel(String raw) =>
    _moduleCapabilityLabels[raw.trim().toLowerCase()] ?? raw;

/// 模块的站源分类 key，与 SourceSite.classKey 同口径（短剧/视频/黄果/成人）。
/// 黄果系成员与成人源按 id / adult 标记归入对应分区，而不是只看 manifest 的
/// category——这样才能和首页、站源管理页的分类保持一致。
String moduleClassKey(Map<String, dynamic> module) {
  final id = module['id'] as String? ?? '';
  if (SourceSite.huangguoCategoryIds.contains(id)) return 'huangguo';
  if (module['adult'] == true || SourceSite.adultCategoryIds.contains(id)) {
    return 'adult';
  }
  return sourceModuleCategory(module['category'] as String?) ==
          SourceCategory.video
      ? 'video'
      : 'shortDrama';
}

/// 未解锁时黄果类/成人类整组隐藏（与首页、站源管理页、榜单页同口径）。
bool moduleClassVisible(String key, {required bool unlocked}) {
  if (key == 'huangguo' || key == 'adult') return unlocked;
  return true;
}

const _moduleClassOrder = <String>['shortDrama', 'video', 'huangguo', 'adult'];
const _moduleClassIcons = <String, IconData>{
  'shortDrama': Icons.smart_display,
  'video': Icons.movie,
  'huangguo': Icons.hub,
  'adult': Icons.lock,
};

/// 按原站源分类把已装模块分组，过滤掉未解锁的黄果类/成人类。
List<({String key, String title, IconData icon, List<Map<String, dynamic>> items})>
    groupInstalledModules(
  List<Map<String, dynamic>> modules, {
  required bool unlocked,
}) {
  final buckets = <String, List<Map<String, dynamic>>>{};
  for (final module in modules) {
    final key = moduleClassKey(module);
    if (!moduleClassVisible(key, unlocked: unlocked)) continue;
    buckets.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(module);
  }
  return [
    for (final key in _moduleClassOrder)
      if (buckets[key]?.isNotEmpty == true)
        (
          key: key,
          title: SourceSite.classLabel(key),
          icon: _moduleClassIcons[key] ?? Icons.extension_outlined,
          items: buckets[key]!,
        ),
  ];
}

/// 在线仓库同样过滤未解锁的黄果类/成人类条目。
List<Map<String, dynamic>> visibleStoreModules(
  List<Map<String, dynamic>> entries, {
  required bool unlocked,
}) => [
  for (final entry in entries)
    if (moduleClassVisible(moduleClassKey(entry), unlocked: unlocked)) entry,
];

/// 拉取已安装模块并登记，返回列表（失败返回空）。
Future<List<Map<String, dynamic>>> loadSourceModules(
  AppRepository repository,
) async {
  final native = repository is NativeRepository ? repository : null;
  if (native == null) return const [];
  try {
    final modules = await native.jsModules();
    applySourceModules(modules);
    return modules;
  } on Object {
    return const [];
  }
}

/// 站源模块管理：已装模块、在线仓库安装、本地 zip 安装。
class JsModuleScreen extends StatefulWidget {
  const JsModuleScreen({
    super.key,
    required this.repository,
    this.store,
  });

  final AppRepository repository;

  /// 传入后页内提供「内置站源」入口（原有站源开关/检测页）。
  final LocalStore? store;

  NativeRepository? get native =>
      repository is NativeRepository ? repository as NativeRepository : null;

  @override
  State<JsModuleScreen> createState() => _JsModuleScreenState();
}

class _JsModuleScreenState extends State<JsModuleScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this);

  List<Map<String, dynamic>> _modules = const [];
  List<Map<String, dynamic>> _infos = const [];
  List<Map<String, dynamic>> _store = const [];
  final _collapsedClasses = <String>{};
  // 在线仓库的分组默认全部合上，用户点开后记住；「加载本组」完成后自动打开。
  final _collapsedStoreClasses = <String>{
    'js-module-store-class-shortDrama',
    'js-module-store-class-video',
    'js-module-store-class-huangguo',
    'js-module-store-class-adult',
  };
  bool _busy = false;
  bool _loading = true;
  bool _storeLoading = false;
  bool _storeLoaded = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onTabChanged);
    _reload();
  }

  @override
  void dispose() {
    _tabs.removeListener(_onTabChanged);
    _tabs.dispose();
    super.dispose();
  }

  /// 切到「在线仓库」时按需拉一次索引（不每次开页都联网）。
  void _onTabChanged() {
    if (_tabs.index == 1 && !_storeLoaded) {
      _storeLoaded = true;
      _loadStore();
    }
  }

  Future<void> _reload() async {
    final modules = await loadSourceModules(widget.repository);
    // 模块详情（加载失败原因/是否内置/已装版本）单独取：列表里要能看到坏模块。
    List<Map<String, dynamic>> infos = const [];
    final native = widget.native;
    if (native != null) {
      try {
        infos = await native.jsModuleInfos();
      } on Object {
        infos = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _modules = modules;
      _infos = infos;
      _loading = false;
    });
  }

  /// 索引拉取失败的原因（核心在联网失败时仍返回内置条目，warning 说明原因）。
  String? get _storeWarning => NativeRepository.lastModuleStoreWarning;

  /// 未传 store（纯模块管理场景）时按未解锁处理：黄果类/成人类默认隐藏。
  bool get _unlocked => widget.store?.restrictedUnlocked ?? false;

  Future<void> _loadStore() async {
    final native = widget.native;
    if (native == null) {
      setState(() => _message = '当前核心不支持站源模块');
      return;
    }
    setState(() => _storeLoading = true);
    try {
      final items = await native.jsModuleStore();
      if (!mounted) return;
      setState(() {
        _store = items;
        _storeLoading = false;
        // 索引拉取失败时核心仍返回内置条目，warning 说明原因；别让用户
        // 以为「没有第三方模块」。
        final warning = (items.isEmpty) ? null : _storeWarning;
        _message = warning;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _storeLoading = false;
        _message = '读取在线仓库失败：$error';
      });
    }
  }

  Future<void> _installOnline(String id) async {
    final native = widget.native;
    if (native == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final installed = await native.installJsModuleOnline(id);
      await _reload();
      await _enableSources([installed, id]);
      if (!mounted) return;
      setState(() => _message = '已安装模块：$installed');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '安装失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键加载某个分类下的全部模块：逐个安装、失败的计数上报；
  /// 完成后自动展开该分组，用户能立刻看到刚装好的条目。
  Future<void> _installGroup(
    ({
      String key,
      String title,
      IconData icon,
      List<Map<String, dynamic>> items,
    }) group,
  ) async {
    final native = widget.native;
    if (native == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    var ok = 0;
    var failed = 0;
    final installedIds = <String>[];
    for (final entry in group.items) {
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      try {
        await native.installJsModuleOnline(id);
        ok++;
        installedIds.add(id);
      } on Object {
        failed++;
      }
    }
    await _reload();
    await _enableSources(installedIds);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _collapsedStoreClasses.remove('js-module-store-class-${group.key}');
      _message = failed == 0
          ? '已加载${group.title} $ok 个模块'
          : '${group.title}：成功 $ok 个，失败 $failed 个';
    });
  }

  /// 模块装好即启用：用户不必再回「站源管理」手动打开一次。
  Future<void> _enableSources(Iterable<String> ids) async {
    final store = widget.store;
    if (store == null) return;
    for (final id in ids) {
      if (id.isEmpty) continue;
      try {
        await store.setSourceEnabled(id, true);
      } on Object {
        // 未注册/暂不可用的源写入失败不影响模块本身已安装。
      }
    }
  }

  /// 已装模块分组的「模糊封面」总开关：组内全部源都糊时才显示为开。
  Widget? _blurGroupSwitch(
    ({
      String key,
      String title,
      IconData icon,
      List<Map<String, dynamic>> items,
    }) group,
  ) {
    final store = widget.store;
    if (store == null) return null;
    final ids = <String>[
      for (final module in group.items)
        if ((module['id'] as String? ?? '').isNotEmpty) module['id'] as String,
    ];
    if (ids.isEmpty) return null;
    final allBlurred = ids.every(store.blurCoversFor);
    return IconButton(
      key: ValueKey('blur-group-${group.key}'),
      tooltip: allBlurred ? '显示封面' : '模糊封面',
      onPressed: _busy ? null : () => _setGroupBlur(ids, !allBlurred),
      icon: Icon(
        allBlurred ? Icons.visibility_off_outlined : Icons.visibility_outlined,
        size: 22,
      ),
    );
  }

  /// 把某个分类下所有源的模糊封面状态一次写成同一个值。
  Future<void> _setGroupBlur(List<String> ids, bool value) async {
    final store = widget.store;
    if (store == null) return;
    for (final id in ids) {
      await store.setBlurCoversFor(id, value);
    }
    if (mounted) setState(() {});
  }

  Future<void> _uninstall(String id) async {
    final native = widget.native;
    if (native == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await native.uninstallJsModule(id);
      await _reload();
      if (!mounted) return;
      setState(() => _message = '已卸载模块：$id');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '卸载失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _install() async {
    final native = widget.native;
    if (native == null) {
      setState(() => _message = '当前核心不支持站源模块');
      return;
    }
    // 与全 App 统一的玻璃浮卡（TV 端自动装进玻璃壳 AlertDialog），
    // 不再用裸 Material SimpleDialog（白底直角，和界面风格割裂）。
    final source = await showFloatingDialog<String>(
      context: context,
      barrierLabel: '安装站源模块',
      width: 320,
      title: const Text('安装站源模块'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FloatingOptionRow(
            key: const ValueKey('js-module-install-file'),
            label: '从本地 zip 安装',
            subtitle: '选择手机里的模块包（.zip，上限 8MB）',
            leading: const Icon(Icons.folder_zip_outlined, size: 20),
            onTap: () => Navigator.pop(context, 'file'),
          ),
          FloatingOptionRow(
            key: const ValueKey('js-module-install-address'),
            label: '从地址安装',
            subtitle: '模块直链（https://…/module.zip）',
            leading: const Icon(Icons.link, size: 20),
            onTap: () => Navigator.pop(context, 'address'),
          ),
        ],
      ),
    );
    if (source == null) return;
    if (source == 'address') {
      await _installFromAddress();
      return;
    }
    final picked = await FilePicker.pickFile(
      dialogTitle: '选择站源模块包（.zip）',
      type: FileType.custom,
      allowedExtensions: const ['zip'],
    );
    if (picked == null) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final bytes = await picked.readAsBytes();
      if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
        throw const FormatException('模块包为空或超过 8MB');
      }
      final directory = await getTemporaryDirectory();
      final target = File(
        '${directory.path}/jsmodule-${DateTime.now().millisecondsSinceEpoch}.zip',
      );
      await target.writeAsBytes(bytes, flush: true);
      final confirmed = await _confirmModule(
        () => native.prepareJsModule(zipPath: target.path),
      );
      try {
        await target.delete();
      } on Object {
        // 临时文件删不掉不影响安装结果。
      }
      if (confirmed == null || !mounted) return;
      final id = await native.installJsModuleToken(confirmed);
      await _reload();
      await _enableSources([id]);
      if (!mounted) return;
      setState(() => _message = id.isEmpty ? '已安装' : '已安装模块：$id');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '安装失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 安装前确认卡：把域名、功能、限制级、是否覆盖已装版本摆给用户看，
  /// 用户确认后返回安装令牌（取消返回 null）。
  Future<String?> _confirmModule(
    Future<Map<String, dynamic>> Function() prepare,
  ) async {
    final theme = Theme.of(context);
    Map<String, dynamic> info;
    try {
      info = await prepare();
    } on Object catch (error) {
      if (!mounted) return null;
      setState(() => _message = '模块预检失败：$error');
      return null;
    }
    if (!mounted) return null;
    final hosts = (info['hosts'] as List?)?.cast<String>() ?? const [];
    final capabilities =
        (info['capabilities'] as List?)?.cast<String>() ?? const [];
    final rankings = (info['rankings'] as List?)
            ?.map((item) => (item is Map ? item['name'] : null)?.toString())
            .whereType<String>()
            .toList() ??
        const <String>[];
    final adult = info['adult'] == true;
    final installed = info['installed'] == true;
    final previous = info['previous'] as String?;
    final version = info['version'] as String? ?? '';
    final error = info['error'] as String?;
    if (error != null && error.isNotEmpty) {
      setState(() => _message = '模块预检失败：$error');
      return null;
    }
    return showFloatingDialog<String>(
      context: context,
      barrierLabel: '安装确认',
      width: 340,
      title: Text((info['name'] as String?) ?? '站源模块'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if ((info['description'] as String?)?.isNotEmpty == true)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(info['description'] as String),
            ),
          Text('版本 $version', style: theme.textTheme.bodySmall),
          if (adult)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Row(
                children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 18, color: theme.colorScheme.error),
                  const SizedBox(width: 6),
                  const Text('限制级模块'),
                ],
              ),
            ),
          if (installed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '已安装${previous == null ? '' : ' $previous'}，将覆盖为 $version',
                style: theme.textTheme.bodySmall,
              ),
            ),
          const SizedBox(height: 12),
          Text('可访问域名', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            hosts.isEmpty ? '（未声明）' : hosts.join('\n'),
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: 12),
          Text('提供功能', style: theme.textTheme.labelLarge),
          const SizedBox(height: 4),
          Text(
            capabilities.isEmpty
                ? '（未声明）'
                : capabilities.map(moduleCapabilityLabel).join('、'),
            style: theme.textTheme.bodySmall,
          ),
          if (rankings.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('提供榜单', style: theme.textTheme.labelLarge),
            const SizedBox(height: 4),
            Text(
              rankings.join('、'),
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const ValueKey('js-module-confirm-cancel'),
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('js-module-confirm-install'),
          onPressed: () => Navigator.pop(context, info['token'] as String?),
          child: Text(installed ? '覆盖安装' : '安装'),
        ),
      ],
    );
  }

  /// 从地址安装：模块作者给一个 zip 直链即可分发，不必上架索引。
  Future<void> _installFromAddress() async {
    final native = widget.native;
    if (native == null) return;
    final controller = TextEditingController();
    final address = await showFloatingDialog<String>(
      context: context,
      barrierLabel: '从地址安装',
      width: 320,
      title: const Text('从地址安装'),
      content: TextField(
        controller: controller,
        autofocus: true,
        keyboardType: TextInputType.url,
        decoration: const InputDecoration(
          hintText: 'https://…/module.zip',
          helperText: '只支持 http/https 直链，上限 8MB',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        TextButton(
          key: const ValueKey('js-module-address-confirm'),
          onPressed: () => Navigator.pop(context, controller.text.trim()),
          child: const Text('预检'),
        ),
      ],
    );
    controller.dispose();
    if (address == null || address.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final token = await _confirmModule(
        () => native.prepareJsModule(address: address),
      );
      if (token == null || !mounted) return;
      final id = await native.installJsModuleToken(token);
      await _reload();
      await _enableSources([id]);
      if (!mounted) return;
      setState(() => _message = id.isEmpty ? '已安装' : '已安装模块：$id');
    } on Object catch (error) {
      if (!mounted) return;
      setState(() => _message = '安装失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 一键更新全部可更新模块（逐个装，失败的记在消息里）。
  Future<void> _updateAll() async {
    final native = widget.native;
    if (native == null) return;
    final updates = _updatableEntries();
    if (updates.isEmpty) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    final failures = <String>[];
    var done = 0;
    for (final entry in updates) {
      try {
        await native.installJsModuleOnline(entry['id'] as String? ?? '');
        done++;
      } on Object {
        failures.add((entry['name'] as String?) ?? (entry['id'] as String? ?? ''));
      }
    }
    await _reload();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = failures.isEmpty
          ? '已更新 $done 个模块'
          : '已更新 $done 个，失败：${failures.join('、')}';
    });
  }

  /// 可更新条目：已安装且版本与仓库不一致。
  List<Map<String, dynamic>> _updatableEntries() {
    final out = <Map<String, dynamic>>[];
    for (final entry in visibleStoreModules(_store, unlocked: _unlocked)) {
      final id = entry['id'] as String? ?? '';
      if (id.isEmpty) continue;
      final installed = _modules
          .where((module) => module['id'] == id)
          .cast<Map<String, dynamic>?>()
          .firstWhere((_) => true, orElse: () => null);
      if (installed == null) continue;
      final from = installed['version'] as String?;
      final to = entry['version'] as String?;
      if (from != null && to != null && to != from) out.add(entry);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    // 监听 store：关于浮卡连点解锁黄果/成人后，两页即时按新口径显示。
    final store = widget.store;
    Widget page(BuildContext context) {
      final theme = Theme.of(context);
      return Scaffold(
        appBar: AppBar(
          title: const Text('站源模块'),
          bottom: TabBar(
            controller: _tabs,
            tabs: const [
              Tab(text: '已装模块'),
              Tab(text: '在线仓库'),
            ],
          ),
        ),
        floatingActionButton: FloatingActionButton.extended(
          key: const ValueKey('js-module-install'),
          onPressed: _busy ? null : _install,
          icon: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.add),
          label: const Text('安装模块'),
        ),
        body: TabBarView(
          controller: _tabs,
          children: [
            _installedTab(theme),
            _storeTab(theme),
          ],
        ),
      );
    }

    return store == null
        ? page(context)
        : AnimatedBuilder(
            animation: store,
            builder: (context, _) => page(context),
          );
  }

  /// 已装模块的一行：坏模块显式报错（不再静默跳过）。
  Widget _installedTile(Map<String, dynamic> module, ThemeData theme) {
    final id = module['id'] as String? ?? '';
    final info = _infos
        .where((item) => item['id'] == id)
        .cast<Map<String, dynamic>?>()
        .firstWhere((_) => true, orElse: () => null);
    final error = info?['error'] as String?;
    final hosts = (module['hosts'] as List?)?.cast<String>() ?? const [];
    final capabilities =
        (module['capabilities'] as List?)?.cast<String>() ?? const [];
    return ListTile(
      key: ValueKey('js-module-$id'),
      leading: Icon(
        error == null ? Icons.extension_outlined : Icons.error_outline,
        color: error == null ? null : theme.colorScheme.error,
      ),
      title: Text(
        (module['name'] as String?)?.isNotEmpty == true
            ? module['name'] as String
            : id,
      ),
      subtitle: Text(
        [
          ?error,
          if (error == null) (module['description'] as String?) ?? '',
          if (error == null &&
              (module['version'] as String?)?.isNotEmpty == true)
            'v${module['version']}',
          if (error == null && capabilities.isNotEmpty)
            '能力：${capabilities.map(moduleCapabilityLabel).join('、')}',
          if (error == null && hosts.isNotEmpty) hosts.join(' · '),
        ].where((part) => part.isNotEmpty).join('\n'),
      ),
      isThreeLine: true,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (module['adult'] == true)
            const Chip(
              label: Text('限制级'),
              visualDensity: VisualDensity.compact,
            ),
          IconButton(
            key: ValueKey('js-module-uninstall-$id'),
            tooltip: '卸载',
            onPressed: _busy || id.isEmpty ? null : () => _uninstall(id),
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
    );
  }

  Widget _installedTab(ThemeData theme) {
    if (_loading) return const Center(child: CircularProgressIndicator());
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Text(
            '在线或本地模块即装即用，改源不必重新发版。',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        if (widget.store != null) ...[
          ListTile(
            key: const ValueKey('js-module-builtin-sources'),
            leading: const Icon(Icons.dns_outlined),
            title: const Text('站源管理'),
            subtitle: const Text('模块源、自定义源与直播/TVBox 导入都在这'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => SourcesScreen(
                  repository: widget.repository,
                  store: widget.store!,
                  mode: SourcesScreenMode.all,
                ),
              ),
            ),
          ),
          const Divider(height: 1),
        ],
        if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _message!.startsWith('安装失败')
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ),
        if (_modules.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              '还没有安装模块',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          for (final group in groupInstalledModules(_modules, unlocked: _unlocked))
            _moduleClassSection(
              group,
              theme,
              // 每个分类分组一个「模糊封面」总开关：开启后该组所有源的封面糊。
              trailing: _blurGroupSwitch(group),
            ),
      ],
    );
  }

  /// 分类分组区头（与站源管理页口径一致）。默认展开，点区头折叠。
  /// 已装模块与在线仓库共用这一套分组，[tile] 决定每条用哪种渲染，
  /// [keyPrefix] 区分两个页签，避免同 key 冲突。
  Widget _moduleClassSection(
    ({
      String key,
      String title,
      IconData icon,
      List<Map<String, dynamic>> items,
    }) group,
    ThemeData theme, {
    Widget Function(Map<String, dynamic>, ThemeData)? tile,
    String keyPrefix = 'js-module-class',
    Set<String>? collapsedSet,
    Widget? trailing,
  }) {
    final build = tile ?? _installedTile;
    final collapsed = collapsedSet ?? _collapsedClasses;
    final sectionKey = '$keyPrefix-${group.key}';
    final expanded = !collapsed.contains(sectionKey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          key: ValueKey(sectionKey),
          onTap: () => setState(() {
            if (expanded) {
              collapsed.add(sectionKey);
            } else {
              collapsed.remove(sectionKey);
            }
          }),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 8),
            child: Row(
              children: [
                Icon(group.icon, size: 20),
                const SizedBox(width: 8),
                Text(
                  group.title,
                  style: theme.textTheme.titleMedium,
                ),
                const SizedBox(width: 8),
                Text('${group.items.length} 个'),
                const Spacer(),
                if (trailing != null) trailing,
                expanded
                    ? const Icon(Icons.expand_less)
                    : const Icon(Icons.expand_more),
              ],
            ),
          ),
        ),
        if (expanded) for (final module in group.items) build(module, theme),
      ],
    );
  }

  Widget _storeTab(ThemeData theme) {
    final storeItems = visibleStoreModules(_store, unlocked: _unlocked);
    final updates = _updatableEntries();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '在线仓库来自官方模块索引，安装前逐文件校验。',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              if (updates.isNotEmpty)
                TextButton.icon(
                  key: const ValueKey('js-module-update-all'),
                  onPressed: _busy ? null : _updateAll,
                  icon: const Icon(Icons.system_update_alt, size: 18),
                  label: Text('可更新 ${updates.length}'),
                ),
              IconButton(
                key: const ValueKey('js-module-store-refresh'),
                tooltip: '刷新',
                onPressed: _storeLoading ? null : _loadStore,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        if (_storeLoading)
          const LinearProgressIndicator()
        else if (_message != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              _message!,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: _message!.contains('失败')
                    ? theme.colorScheme.error
                    : theme.colorScheme.primary,
              ),
            ),
          ),
        if (!_storeLoading && storeItems.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              _store.isEmpty ? '未读取到在线模块' : '暂无可显示的在线模块',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          )
        else
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(bottom: 96),
              children: [
                // 与已装模块同口径分组：短剧类/视频类/黄果类/成人类，
                // 未解锁时黄果类与成人类整组隐藏（visibleStoreModules 已过滤）。
                // 默认全部合上；每组右侧可一键加载本组，加载后自动展开。
                for (final group
                    in groupInstalledModules(storeItems, unlocked: _unlocked))
                  _moduleClassSection(
                    group,
                    theme,
                    tile: _storeTile,
                    keyPrefix: 'js-module-store-class',
                    collapsedSet: _collapsedStoreClasses,
                    trailing: TextButton(
                      key: ValueKey('js-module-store-load-${group.key}'),
                      onPressed: _busy ? null : () => _installGroup(group),
                      child: const Text('加载本组'),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _storeTile(Map<String, dynamic> entry, ThemeData theme) {
    final id = entry['id'] as String? ?? '';
    final installed = _modules
        .where((module) => module['id'] == id)
        .cast<Map<String, dynamic>?>()
        .firstWhere((_) => true, orElse: () => null);
    final installedVersion = installed?['version'] as String?;
    final storeVersion = entry['version'] as String?;
    final updatable = installed != null &&
        installedVersion != null &&
        storeVersion != null &&
        storeVersion != installedVersion;
    final bundled = entry['bundled'] == true;
    return ListTile(
      key: ValueKey('js-module-store-$id'),
      leading: Icon(bundled ? Icons.inventory_2_outlined : Icons.cloud_download_outlined),
      title: Text(
        (entry['name'] as String?)?.isNotEmpty == true
            ? entry['name'] as String
            : id,
      ),
      subtitle: Text(
        [
          (entry['description'] as String?) ?? '',
          if (storeVersion != null && storeVersion.isNotEmpty) 'v$storeVersion',
          if (installed != null) '已安装${updatable ? ' · 可更新' : ''}',
        ].where((part) => part.isNotEmpty).join('\n'),
      ),
      isThreeLine: true,
      trailing: installed != null && !updatable && !bundled
          ? const Icon(Icons.check_circle_outline)
          : TextButton(
              key: ValueKey('js-module-store-action-$id'),
              onPressed: _busy || id.isEmpty ? null : () => _installOnline(id),
              child: Text(
                installed == null
                    ? '安装'
                    : (updatable ? '更新' : '重新安装'),
              ),
            ),
    );
  }
}
