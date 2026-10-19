import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app_build.dart';
import 'license.dart';
import 'license_codec.dart';
import 'qq_launch.dart';

/// 卖家联系方式：显示在激活页，供买家购买授权码 / 续费 / 换机时联系。
/// 点卡片拉起 QQ 加好友（识别文本中的 QQ 号），拉不起来自动复制；
/// 右侧复制按钮直接复制。留空字符串则整块不显示。
const String kSellerContact = 'QQ：963484350';
const String kSellerContactHint = '购买授权码 / 续费 / 换机，点此加 QQ 联系卖家';

/// 激活页：未激活时输入授权码；已激活时展示授权信息。
class ActivationScreen extends StatefulWidget {
  const ActivationScreen({
    super.key,
    required this.deviceCode,
    this.onActivated,
    this.record,
    this.verifier,
    this.sellerContact = kSellerContact,
  });

  /// 本机设备码（10 位）。
  final String deviceCode;

  /// 激活成功回调（门禁模式下传入以切换到主界面；设置页入口可不传）。
  final ValueChanged<ActivationRecord>? onActivated;

  /// 已激活记录（设置页入口展示用；门禁模式下由 Gate 维护）。
  final ActivationRecord? record;

  /// 验签器（仅测试注入；null 走正式公钥）。
  final LicenseVerifier? verifier;

  /// 卖家联系方式（默认取 [kSellerContact]；测试可注入覆盖）。
  final String sellerContact;

  @override
  State<ActivationScreen> createState() => _ActivationScreenState();
}

class _ActivationScreenState extends State<ActivationScreen> {
  final _codeController = TextEditingController();
  final _focusNode = FocusNode();
  bool _busy = false;
  String? _error;

  /// 本页激活成功后的记录：切到已激活卡片，
  /// 否则 _busy 永真停在转圈（门禁之外的入口没有换页逻辑）。
  ActivationRecord? _activatedRecord;

  @override
  void dispose() {
    _codeController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _activate() async {
    if (_busy) return;
    final input = LicenseCodec.normalizeCode(_codeController.text);
    if (input.isEmpty) {
      setState(() => _error = '请先粘贴或输入授权码');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final attempt = await _runVerification(input);
    if (!mounted) return;
    if (attempt.record == null) {
      setState(() {
        _busy = false;
        _error = attempt.error ?? '授权码无效，请核对后重试';
      });
      return;
    }
    widget.onActivated?.call(attempt.record!);
    if (mounted) {
      setState(() {
        _busy = false;
        _activatedRecord = attempt.record;
      });
    }
  }

  /// 校验流程（供测试覆写注入）。
  Future<ActivationAttempt> _runVerification(String normalizedCode) {
    return activateWithCode(
      code: normalizedCode,
      currentDevice: widget.deviceCode,
      now: DateTime.now(),
      verifier: widget.verifier,
    );
  }

  void _copyDeviceCode() {
    Clipboard.setData(
      ClipboardData(text: LicenseCodec.formatDevice(widget.deviceCode)),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('设备码已复制，发给卖家换取授权码')),
    );
  }

  void _copyContact({bool fallback = false}) {
    if (widget.sellerContact.isEmpty) return;
    Clipboard.setData(ClipboardData(text: widget.sellerContact));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          fallback ? '未检测到 QQ，已复制联系方式' : '联系方式已复制',
        ),
      ),
    );
  }

  /// 点卡片：能拉起 QQ 就跳 QQ 加好友，否则退化为复制。
  Future<void> _openOrCopyContact() async {
    final contact = widget.sellerContact;
    if (contact.isEmpty) return;
    final qq = qqNumberFrom(contact);
    if (qq != null && await tryOpenQQ(qq)) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('正在打开 QQ...')),
      );
      return;
    }
    _copyContact(fallback: true);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final record = widget.record ?? _activatedRecord;
    return Scaffold(
      appBar: AppBar(title: Text('激活 $appName')),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (record != null)
                    _buildActivatedCard(theme, record)
                  else ...[
                    _buildDeviceCard(theme),
                    const SizedBox(height: 20),
                    _buildInputCard(theme),
                  ],
                  ...[
                    const SizedBox(height: 16),
                    _buildContactCard(theme),
                  ],
                  const SizedBox(height: 16),
                  Text(
                    '一码一机：授权码与设备码绑定，换设备需联系卖家重新授权。',
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 卖家联系方式卡片（[kSellerContact] 为空时不占位）。
  Widget _buildContactCard(ThemeData theme) {
    if (widget.sellerContact.isEmpty) return const SizedBox.shrink();
    return Card(
      child: ListTile(
        onTap: _openOrCopyContact,
        leading: Icon(
          Icons.support_agent_outlined,
          color: theme.colorScheme.primary,
        ),
        title: Text(
          widget.sellerContact,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Text(
          kSellerContactHint,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        trailing: IconButton(
          tooltip: '复制联系方式',
          onPressed: _copyContact,
          icon: const Icon(Icons.copy, size: 18),
        ),
      ),
    );
  }

  Widget _buildDeviceCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('本机设备码', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: SelectableText(
                    LicenseCodec.formatDevice(widget.deviceCode),
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontFamily: 'monospace',
                      fontWeight: FontWeight.bold,
                      letterSpacing: 2,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '复制设备码',
                  onPressed: _copyDeviceCode,
                  icon: const Icon(Icons.copy),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '把设备码发给卖家，换取授权码填入下方。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputCard(ThemeData theme) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('输入授权码', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _codeController,
              focusNode: _focusNode,
              enabled: !_busy,
              maxLines: 3,
              textCapitalization: TextCapitalization.characters,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 14),
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                hintText: '粘贴卖家发来的授权码',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.error, fontSize: 13),
              ),
            ],
            const SizedBox(height: 12),
            FilledButton(
              onPressed: _busy ? null : _activate,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('激活'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildActivatedCard(ThemeData theme, ActivationRecord record) {
    final now = DateTime.now();
    final remaining = record.remainingDays(now);
    final expiringSoon = remaining != null && remaining <= 7;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  Icons.verified,
                  color: theme.colorScheme.primary,
                ),
                const SizedBox(width: 8),
                Text('已激活', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            _infoRow(
              theme,
              '授权类型',
              record.isPermanent
                  ? '永久卡'
                  : '${record.durationDays} 天卡',
            ),
            if (!record.isPermanent) ...[
              _infoRow(
                theme,
                '到期日期',
                DateTime.fromMillisecondsSinceEpoch(record.expiresAtMs)
                    .toLocal()
                    .toString()
                    .split(' ')
                    .first,
              ),
              _infoRow(theme, '剩余天数', '$remaining 天'),
            ],
            if (expiringSoon)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '授权即将到期，续费请把设备码发给卖家。',
                  style: TextStyle(
                    color: theme.colorScheme.error,
                    fontSize: 13,
                  ),
                ),
              ),
            const Divider(height: 24),
            _infoRow(
              theme,
              '设备码',
              LicenseCodec.formatDevice(widget.deviceCode),
            ),
            const SizedBox(height: 8),
            Text(
              '续费/换机：把设备码发给卖家即可，无需卸载重装。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _copyDeviceCode,
                icon: const Icon(Icons.copy, size: 16),
                label: const Text('复制设备码'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(ThemeData theme, String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: theme.textTheme.bodyMedium
                  ?.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}
