import 'dart:async';

import 'package:flutter/material.dart';

import 'app_icons.dart';
import 'cloud_backup.dart';
import 'core_bridge.dart';
import 'error_text.dart';
import 'glass.dart';
import 'local_store.dart';
import 'remote_widgets.dart';

String _sizeLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
}

String _timeLabel(DateTime? time) {
  if (time == null) return '从未';
  final local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

enum _RestoreAction { merge, replace }

/// WebDAV 云备份页：配置服务器与加密密码、手动备份/恢复、开关自动备份。
class CloudBackupScreen extends StatefulWidget {
  const CloudBackupScreen({
    super.key,
    required this.repository,
    required this.store,
  });

  final AppRepository repository;
  final LocalStore store;

  @override
  State<CloudBackupScreen> createState() => _CloudBackupScreenState();
}

class _CloudBackupScreenState extends State<CloudBackupScreen> {
  late final CloudBackup _service;
  final _url = TextEditingController();
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _backupPassword = TextEditingController();
  bool _autoBackup = false;
  bool _busy = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    ensureTelevisionFocus(context);
    _service = CloudBackup(widget.store.preferences, widget.repository);
    final config = _service.load();
    _url.text = config.url;
    _username.text = config.username;
    _password.text = config.password;
    _backupPassword.text = config.backupPassword;
    _autoBackup = config.autoBackup;
  }

  @override
  void dispose() {
    _url.dispose();
    _username.dispose();
    _password.dispose();
    _backupPassword.dispose();
    super.dispose();
  }

  /// 把表单落盘，保留已有的备份进度（上次时间与内容指纹）。
  Future<CloudBackupConfig> _persist() async {
    final previous = _service.load();
    final config = CloudBackupConfig(
      url: _url.text.trim(),
      username: _username.text.trim(),
      password: _password.text.trim(),
      backupPassword: _backupPassword.text.trim(),
      autoBackup: _autoBackup,
      lastBackupAt: previous.lastBackupAt,
      lastBackupHash: previous.lastBackupHash,
    );
    await _service.save(config);
    return config;
  }

  Future<void> _perform(Future<String?> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final message = await action();
      if (mounted && message != null) setState(() => _message = message);
    } catch (error) {
      if (mounted) setState(() => _message = friendlyError(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _requireReady(CloudBackupConfig config) {
    if (!config.ready) throw AppFailure('请先填写服务器地址、账号与两组密码');
  }

  Future<void> _test() => _perform(() async {
    final config = await _persist();
    _requireReady(config);
    final result = await _service.test(config);
    final exists = result['exists'] == true;
    if (!exists) return '连接成功，云端还没有备份';
    final size = result['size'] is int ? result['size'] as int : 0;
    return '连接成功，云端已有备份（${_sizeLabel(size)}）';
  });

  Future<void> _backupNow() => _perform(() async {
    final config = await _persist();
    _requireReady(config);
    final built = await _service.backupNow(widget.store, config: config);
    return '备份完成：${built.profiles} 个用户 · ${_sizeLabel(built.size)}';
  });

  Future<void> _restore() => _perform(() async {
    final config = await _persist();
    _requireReady(config);
    final remote = await _service.fetch(config, widget.store);
    if (!mounted) return null;
    if (remote == null) return '云端还没有备份，先在另一台设备上传一次';
    final action = await _confirmRestore(remote);
    if (action == null || !mounted) return null;
    if (action == _RestoreAction.merge) {
      final count = await _service.restoreMergeFollow(widget.store, remote);
      return '合并完成：${count.label}';
    }
    await _service.restoreReplace(widget.store, remote);
    return '已恢复云端备份，本机数据被整体覆盖';
  });

  Future<_RestoreAction?> _confirmRestore(CloudBackupRemote remote) {
    final meta = remote.meta;
    final from = meta.platform.isEmpty ? '未知设备' : meta.platform;
    final version = meta.version.isEmpty ? '' : ' · ${meta.version}';
    return showDialog<_RestoreAction>(
      context: context,
      builder: (context) => GlassDialogShell(
        child: AlertDialog(
          title: const Text('恢复云端备份'),
          content: Text(
            '云端备份：${_timeLabel(meta.exportedAt)}\n'
            '来自：$from$version\n'
            '大小：${_sizeLabel(remote.size)}\n\n'
            '「合并追剧」只把云端记录并入当前用户，不影响本机其他数据；'
            '「覆盖恢复」会用云端备份替换本机全部用户、追剧、历史与设置。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context, _RestoreAction.replace),
              child: const Text('覆盖恢复'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, _RestoreAction.merge),
              child: const Text('合并追剧'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('云备份'), flexibleSpace: const TopFog()),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              '通过 WebDAV 把全部用户、追剧、历史与设置备份到自己的网盘；'
              '上传前会用备份密码加密，服务器上只存密文。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _url,
              keyboardType: TextInputType.url,
              autofillHints: const [AutofillHints.url],
              decoration: const InputDecoration(
                labelText: '服务器地址',
                hintText: cloudBackupDefaultUrl,
                helperText: '坚果云等 WebDAV 网盘，路径需包含 /dav/',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _username,
              autofillHints: const [AutofillHints.username],
              decoration: const InputDecoration(
                labelText: '账号',
                helperText: '坚果云填登录邮箱',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(
                labelText: '应用密码',
                helperText: '坚果云在「账户信息 → 安全选项」生成，不是登录密码',
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _backupPassword,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: '备份加密密码',
                helperText: '自拟，恢复时必须一致；丢失将无法解密云端备份',
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _autoBackup,
              title: const Text('切到后台时自动备份'),
              subtitle: const Text(
                '内容有变化且距上次备份超过 12 小时才会上传；失败静默不打扰。',
              ),
              onChanged: (value) {
                setState(() => _autoBackup = value);
                unawaited(_persist());
              },
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: _busy ? null : _test,
                  icon: AppIcon(AppIcons.sync),
                  label: const Text('测试连接'),
                ),
                FilledButton.icon(
                  onPressed: _busy ? null : _backupNow,
                  icon: AppIcon(AppIcons.backup),
                  label: const Text('立即备份'),
                ),
                OutlinedButton.icon(
                  onPressed: _busy ? null : _restore,
                  icon: AppIcon(AppIcons.restore),
                  label: const Text('恢复备份'),
                ),
              ],
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: LinearProgressIndicator(),
              ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: SelectableText(_message!),
              ),
            const SizedBox(height: 24),
            Text(
              '上次备份：${_timeLabel(_service.load().lastBackupAt)}'
              '${_autoBackup ? ' · 自动备份已开启' : ''}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    ),
  );
}
