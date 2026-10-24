// 反馈 Bug 入口：设置页（手机/电视）进入的轻量玻璃卡。
//
// 用户描述问题后，一键生成附带版本 / 系统 / 时间信息的反馈文本：
// - 提交到 GitHub：用系统浏览器打开仓库 issues/new 并预填标题与正文；
// - 复制反馈内容：GitHub 打不开时的兜底，可粘贴给开发者
//   （联系方式复用激活页的卖家 QQ）。
//
// 无网络依赖（打开浏览器交给系统）、无弹窗内定时器，测试可确定性覆盖。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'activation/activation_screen.dart' show kSellerContact;
import 'app_icons.dart';
import 'app_layout.dart';
import 'folme.dart';
import 'glass.dart';
import 'remote_notice.dart' show openRemoteNoticeLink;

/// 仓库 Issue 新建页（支持 title/body 查询参数预填）。
const String kBugIssueNewUrl =
    'https://github.com/guocheng1378/guoapp/issues/new';

/// 由描述与运行环境组装完整反馈文本（提交与复制共用同一份）。
String buildBugReport({
  required String version,
  required String description,
  required bool television,
  DateTime? now,
}) {
  final device = Platform.isAndroid
      ? (television ? '电视' : '手机')
      : Platform.isWindows
          ? '电脑'
          : Platform.operatingSystem;
  final stamp = (now ?? DateTime.now()).toLocal().toString();
  return <String>[
    '问题描述：',
    description.trim(),
    '',
    '----',
    '版本：$version',
    '系统：${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
    '界面：$device',
    '时间：${stamp.substring(0, stamp.length >= 19 ? 19 : stamp.length)}',
  ].join('\n');
}

/// Issue 标题：取描述首行，超长截断；空描述回退默认标题。
String bugReportTitle(String description) {
  final firstLine = description.trim().split('\n').first.trim();
  if (firstLine.isEmpty) return 'Bug 反馈';
  const max = 40;
  return firstLine.length <= max
      ? firstLine
      : '${firstLine.substring(0, max)}…';
}

/// 组装预填 title/body 的 issues/new 地址。
Uri buildBugIssueUri({required String title, required String body}) {
  final base = Uri.parse(kBugIssueNewUrl);
  return base.replace(queryParameters: <String, String>{
    'title': title,
    'body': body,
  });
}

/// 反馈 Bug 玻璃卡：与公告卡/关于卡同材质（信息卡实档）。
///
/// [version] / [television] 缺省时从 [AppLayout] 继承（设置页所在
/// 路由都在 AppLayout 之下）；测试可显式注入固定值。
Future<void> showBugReportCard(
  BuildContext context, {
  String? version,
  bool? television,
}) {
  final resolvedVersion = version ?? AppLayout.versionOf(context);
  final resolvedTelevision = television ?? AppLayout.isTelevision(context);
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '反馈Bug',
    barrierColor: Colors.black.withValues(alpha: 0.32),
    transitionDuration: const Duration(milliseconds: 200),
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          scale: Tween<double>(begin: 0.94, end: 1).animate(curved),
          child: child,
        ),
      );
    },
    pageBuilder: (_, _, _) => _BugReportCard(
      version: resolvedVersion,
      television: resolvedTelevision,
    ),
  );
}

class _BugReportCard extends StatefulWidget {
  const _BugReportCard({required this.version, required this.television});

  final String version;
  final bool television;

  @override
  State<_BugReportCard> createState() => _BugReportCardState();
}

class _BugReportCardState extends State<_BugReportCard> {
  final TextEditingController _controller = TextEditingController();
  String? _status;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  String get _report => buildBugReport(
    version: widget.version,
    description: _controller.text,
    television: widget.television,
  );

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _report));
    if (!mounted) return;
    setState(() {
      _status = '已复制反馈内容，可粘贴到 GitHub，或通过 $kSellerContact 发给开发者';
    });
  }

  Future<void> _submit() async {
    final uri = buildBugIssueUri(
      title: bugReportTitle(_controller.text),
      body: _report,
    );
    if (await openRemoteNoticeLink(uri.toString())) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    // 无浏览器 / 被拦截：降级为复制，交给用户走 QQ。
    await _copy();
    if (!mounted) return;
    setState(() {
      _status = '无法打开浏览器，反馈内容已复制，可通过 $kSellerContact 发给开发者';
    });
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final textTheme = Theme.of(context).textTheme;
    final canSubmit = _controller.text.trim().isNotEmpty;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: GlassSurface(
          radius: 20,
          topHighlight: true,
          // 连续文字信息面（同关于卡/公告卡）：底色取实档防海报透字。
          tint: GlassTint.card,
          child: Material(
            type: MaterialType.transparency,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppIcon(AppIcons.edit, size: 22, color: scheme.primary),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          '反馈 Bug',
                          style: textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey('bug-report-field'),
                    controller: _controller,
                    minLines: 3,
                    maxLines: 5,
                    autofocus: !widget.television,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                      hintText: '简单描述问题：做了什么、期望什么、实际发生了什么…',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '提交时自动附带版本、系统与时间信息。',
                    style: textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  if (_status != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      _status!,
                      key: const ValueKey('bug-report-status'),
                      style: textTheme.bodySmall?.copyWith(
                        color: scheme.primary,
                      ),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      TextButton(
                        key: const ValueKey('bug-report-copy'),
                        onPressed: _copy,
                        child: const Text('复制反馈内容'),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FolmePress(
                          child: FilledButton(
                            key: const ValueKey('bug-report-submit'),
                            onPressed: canSubmit ? _submit : null,
                            child: const Text('提交到 GitHub'),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
