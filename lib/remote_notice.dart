// 启动远程公告 / 版本更新提示。
//
// 配置文件即公开仓库 main 分支根目录的 `app_config.json`——在 GitHub
// 网页编辑提交后，对全部装机下次启动生效，无需自有服务器、无需发版：
//
// - 拉取按 remoteNoticeUrls 顺序回退：raw 优先（改文件即时生效），
//   jsdelivr 为国内可达性兜底（分支引用可能有最长约 12h 缓存延迟）。
// - 全链路静默容错：任何网络/解析失败都不弹、不报错、不卡启动。
// - 会话内只尝试一次（顶层守卫），profile 切换不会重复弹。
// - FLUTTER_TEST 环境默认直通不拉网（与 activation_flow 同款守卫），
//   测试经 RemoteNoticeTrigger.debugConfig / debugFetcher 注入。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'app_build.dart';
import 'app_icons.dart';
import 'core_bridge.dart';
import 'folme.dart';
import 'glass.dart';

/// 回退拉取地址：raw.githubusercontent 改文件即时生效，优先；
/// jsdelivr 双域名仅在国内 raw 不可达时兜底。
const List<String> remoteNoticeUrls = <String>[
  'https://raw.githubusercontent.com/guocheng1378/guoapp/main/app_config.json',
  'https://fastly.jsdelivr.net/gh/guocheng1378/guoapp@main/app_config.json',
  'https://cdn.jsdelivr.net/gh/guocheng1378/guoapp@main/app_config.json',
];

/// 配置未提供 update.url 时的默认下载页。
const String defaultReleasesUrl =
    'https://github.com/guocheng1378/guoapp/releases/latest';

/// 公告段（announcement），字段见仓库 app_config.json 的 `_说明`。
class RemoteNoticeAnnouncement {
  const RemoteNoticeAnnouncement({
    required this.title,
    required this.message,
    required this.button,
    this.link = '',
    this.image = '',
  });

  final String title;
  final String message;
  final String button;
  final String link;

  /// 可选配图 URL（仅 http/https）；空串或非法值 = 不显示。
  final String image;
}

/// 更新段（update）：仅当 [build] 大于本机安装包构建号时展示。
class RemoteNoticeUpdate {
  const RemoteNoticeUpdate({
    required this.version,
    required this.build,
    required this.notes,
    required this.url,
  });

  final String version;
  final int build;
  final String notes;
  final String url;
}

/// 远程配置模型：防御性解析，任何结构性错误只丢弃对应段而非整体失败。
class RemoteNoticeConfig {
  const RemoteNoticeConfig({
    this.announcement,
    this.update,
    this.sourceConfig,
  });

  final RemoteNoticeAnnouncement? announcement;
  final RemoteNoticeUpdate? update;

  /// 站源配置段（sourceConfig）：原样转发核心热更（黄果AI 镜像表 / 真果·鉴
  /// 根地址）。字段级校验（scheme、去重、上限）由核心 config.source 权威执行，
  /// 非法段会被整体拒绝并保持当前生效值；此处仅做结构防御。
  final Map<String, dynamic>? sourceConfig;

  /// 解析失败（坏 JSON / 根不是对象）返回 null；未知键（如 `_说明`）忽略。
  static RemoteNoticeConfig? tryParse(String body) {
    final Object? decoded;
    try {
      decoded = jsonDecode(body);
    } on Object {
      return null;
    }
    if (decoded is! Map) return null;
    return RemoteNoticeConfig(
      announcement: _parseAnnouncement(decoded['announcement']),
      update: _parseUpdate(decoded['update']),
      sourceConfig: _parseSourceConfig(decoded['sourceConfig']),
    );
  }

  static RemoteNoticeAnnouncement? _parseAnnouncement(Object? raw) {
    if (raw is! Map) return null;
    if (raw['enabled'] != true) return null;
    final title = raw['title']?.toString() ?? '';
    final message = raw['message']?.toString() ?? '';
    final image = _sanitizeImageUrl(raw['image']?.toString() ?? '');
    // 纯图公告（无标题无正文但配了图）同样有效。
    if (title.isEmpty && message.isEmpty && image.isEmpty) return null;
    final button = raw['button']?.toString() ?? '';
    return RemoteNoticeAnnouncement(
      title: title,
      message: message,
      button: button.trim().isEmpty ? '我知道了' : button,
      link: raw['link']?.toString() ?? '',
      image: image,
    );
  }

  /// 配图 URL 防御清洗：仅接受 http/https，其余（空值/乱写/内嵌 scheme）
  /// 一律静默置空，与整条链路的容错哲学一致。
  static String _sanitizeImageUrl(String raw) {
    final url = raw.trim();
    if (url.isEmpty) return '';
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return '';
    }
    return url;
  }

  static RemoteNoticeUpdate? _parseUpdate(Object? raw) {
    if (raw is! Map) return null;
    if (raw['enabled'] != true) return null;
    final rawBuild = raw['build'];
    final build =
        rawBuild is int ? rawBuild : int.tryParse('${rawBuild ?? ''}');
    if (build == null || build <= 0) return null;
    return RemoteNoticeUpdate(
      version: raw['version']?.toString() ?? '',
      build: build,
      notes: raw['notes']?.toString() ?? '',
      url: raw['url']?.toString() ?? '',
    );
  }

  /// sourceConfig 段防御解析：仅要求是 Map 且非空，原样透传（值保持
  /// jsonDecode 出来的原生类型）。字段级合法性由核心侧权威校验，此处不重复
  /// 规则，避免两端规则漂移。
  static Map<String, dynamic>? _parseSourceConfig(Object? raw) {
    if (raw is! Map || raw.isEmpty) return null;
    return Map<String, dynamic>.from(raw);
  }
}

/// 从版本串（`0.2.96+2129`）解析构建号；无 `+N` 段时返回 null。
int? parseBuildNumber(String version) {
  final match = RegExp(r'\+\s*(\d+)\s*$').firstMatch(version.trim());
  if (match == null) return null;
  return int.tryParse(match.group(1)!);
}

/// 测试注入口：返回配置原文（null=拉取失败）。
typedef RemoteConfigFetcher = Future<String?> Function();

/// 逐个尝试 [remoteNoticeUrls]，全部失败返回 null（静默）。
///
/// 200 但内容不以 `{` 开头（CDN 防爬挑战页/HTML）同样视为失败，
/// 交由下一地址兜底。
Future<String?> fetchRemoteNoticeConfig() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    for (final url in remoteNoticeUrls) {
      try {
        final request = await client
            .getUrl(Uri.parse(url))
            .timeout(const Duration(seconds: 3));
        final response = await request
            .close()
            .timeout(const Duration(seconds: 5));
        if (response.statusCode != 200) continue;
        final body = await response
            .transform(utf8.decoder)
            .join()
            .timeout(const Duration(seconds: 5));
        if (!body.trimLeft().startsWith('{')) continue;
        return body;
      } on Object {
        continue;
      }
    }
    return null;
  } on Object {
    return null;
  } finally {
    client.close(force: true);
  }
}

bool _noticeAttempted = false;

/// 清除「每次会话只尝试一次」守卫（仅测试用）。
void resetRemoteNoticeSessionForTest() => _noticeAttempted = false;

/// 启动弹窗入口：拉取配置并按内容弹一次玻璃卡（更新段优先级与公告段
/// 同卡展示）；配置不可用 / 无可弹内容时静默返回。
///
/// [debugConfig] / [debugFetcher] / [debugApplySourceConfig] 仅测试注入用；
/// 注入前两者时跳过 FLUTTER_TEST 直通守卫，注入 [debugApplySourceConfig]
/// 时以桩替代核心桥转发（避免测试真调 FFI）。
Future<void> maybeShowRemoteNotice(
  BuildContext context, {
  required String currentVersion,
  RemoteNoticeConfig? debugConfig,
  RemoteConfigFetcher? debugFetcher,
  Future<void> Function(Map<String, dynamic> config)? debugApplySourceConfig,
}) async {
  if (_noticeAttempted) return;
  _noticeAttempted = true;
  // 测试环境默认直通：真实网络在 fake-async 区永不完成或污染套件
  // （与 activation_flow 的 FLUTTER_TEST 占位同一坑）。
  if (debugConfig == null &&
      debugFetcher == null &&
      Platform.environment.containsKey('FLUTTER_TEST')) {
    return;
  }
  final RemoteNoticeConfig? config;
  if (debugConfig != null) {
    config = debugConfig;
  } else {
    try {
      final body = debugFetcher != null
          ? await debugFetcher()
          : await fetchRemoteNoticeConfig();
      config = body == null ? null : RemoteNoticeConfig.tryParse(body);
    } on Object {
      return;
    }
  }
  if (config == null) return;

  // sourceConfig 段与弹窗内容无关：无论是否弹卡都先转发核心热更；失败
  // 静默（核心校验拒绝 / 桥不可用都保持当前生效值），不阻塞弹窗链路。
  final sourceConfig = config.sourceConfig;
  if (sourceConfig != null && sourceConfig.isNotEmpty) {
    try {
      await (debugApplySourceConfig ?? applyNativeSourceConfig)(sourceConfig);
    } on Object {
      // 尽力而为。
    }
  }
  if (!context.mounted) return;

  final update = config.update;
  final localBuild = parseBuildNumber(currentVersion);
  final hasUpdate =
      update != null && localBuild != null && update.build > localBuild;
  final announcement = config.announcement;
  if (!hasUpdate && announcement == null) return;

  await showRemoteNoticeCard(
    context,
    announcement: announcement,
    update: hasUpdate ? update : null,
  );
}

/// 尝试用系统浏览器打开外链；失败（无浏览器/非 http(s)）返回 false。
Future<bool> openRemoteNoticeLink(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      !(uri.scheme == 'https' || uri.scheme == 'http')) {
    return false;
  }
  try {
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}

/// 启动弹窗玻璃卡：与全应用瓷面同材质（信息卡实档），公告段与更新段
/// 同卡时以细线分隔；更新段主按钮「去下载」跳系统浏览器，失败时降级为
/// 卡内可复制链接。barrier 轻压背景、不可点外关闭（保证被看到），系统
/// 返回键仍可关闭。
Future<void> showRemoteNoticeCard(
  BuildContext context, {
  RemoteNoticeAnnouncement? announcement,
  RemoteNoticeUpdate? update,
}) {
  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: false,
    barrierLabel: '关于$appName',
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
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final scheme = Theme.of(dialogContext).colorScheme;
      final textTheme = Theme.of(dialogContext).textTheme;
      var linkFallback = '';

      Widget sectionHeader(String icon, String text) => Row(
        children: [
          AppIcon(icon, size: 22, color: scheme.primary),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      );

      Widget bodyText(String text) => Text(
        text,
        style: textTheme.bodyMedium?.copyWith(
          height: 1.45,
          color: scheme.onSurfaceVariant,
        ),
      );

      Widget announcementImage(String url) => ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 200),
          child: Image.network(
            url,
            width: double.infinity,
            fit: BoxFit.cover,
            // 加载中给固定高度占位，避免弹窗高度跳动。
            loadingBuilder: (context, child, progress) {
              if (progress == null) return child;
              return Container(
                height: 120,
                alignment: Alignment.center,
                color: scheme.onSurfaceVariant.withValues(alpha: 0.06),
              );
            },
            // 加载失败整块消失：与远程公告静默容错哲学一致。
            errorBuilder: (context, error, stackTrace) =>
                const SizedBox.shrink(),
          ),
        ),
      );

      return Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: GlassSurface(
            radius: 20,
            topHighlight: true,
            // 连续文字信息面（同关于卡）：底色取实档，海报透上来会糊字。
            tint: GlassTint.card,
            child: Material(
              type: MaterialType.transparency,
              child: StatefulBuilder(
                builder: (dialogContext, setDialogState) {
                  Future<void> onDownload() async {
                    final url = (update?.url.trim().isNotEmpty ?? false)
                        ? update!.url
                        : defaultReleasesUrl;
                    if (await openRemoteNoticeLink(url)) {
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                      return;
                    }
                    // 打不开浏览器：卡内降级展示可复制链接。
                    unawaited(
                      Clipboard.setData(ClipboardData(text: url)).then(
                        (_) {},
                        // 测试/无剪贴板实现环境下静默（MethodChannel 未注册）。
                        onError: (Object _) {},
                      ),
                    );
                    setDialogState(() => linkFallback = url);
                  }

                  Future<void> onLearnMore(String url) async {
                    if (await openRemoteNoticeLink(url) &&
                        dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  }

                  final sections = <Widget>[];
                  if (announcement != null) {
                    if (announcement.title.isNotEmpty) {
                      sections.add(
                        sectionHeader(AppIcons.info, announcement.title),
                      );
                    }
                    final hasImage = announcement.image.isNotEmpty;
                    if (announcement.message.isNotEmpty || hasImage) {
                      if (announcement.title.isNotEmpty) {
                        sections.add(const SizedBox(height: 10));
                      }
                      sections.add(
                        Flexible(
                          child: SingleChildScrollView(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (announcement.message.isNotEmpty)
                                  bodyText(announcement.message),
                                if (announcement.message.isNotEmpty && hasImage)
                                  const SizedBox(height: 12),
                                if (hasImage)
                                  announcementImage(announcement.image),
                              ],
                            ),
                          ),
                        ),
                      );
                    }
                  }
                  if (update != null) {
                    if (announcement != null) {
                      sections.add(
                        Divider(
                          height: 28,
                          thickness: 1,
                          color: scheme.onSurfaceVariant
                              .withValues(alpha: 0.12),
                        ),
                      );
                    }
                    sections.add(
                      sectionHeader(
                        AppIcons.download,
                        update.version.isEmpty
                            ? '发现新版本'
                            : '发现新版本 v${update.version}',
                      ),
                    );
                    if (update.notes.isNotEmpty) {
                      sections.add(const SizedBox(height: 10));
                      sections.add(
                        Flexible(
                          child: SingleChildScrollView(
                            child: bodyText(update.notes),
                          ),
                        ),
                      );
                    }
                  }

                  final actions = <Widget>[];
                  if (update != null) {
                    actions
                      ..add(TextButton(
                        onPressed: () =>
                            Navigator.of(dialogContext).pop(),
                        child: const Text('稍后再说'),
                      ))
                      ..add(const SizedBox(width: 10))
                      ..add(Expanded(
                        child: FolmePress(
                          child: FilledButton(
                            autofocus: true,
                            onPressed: onDownload,
                            child: const Text('去下载'),
                          ),
                        ),
                      ));
                  } else if (announcement != null) {
                    if (announcement.link.trim().isNotEmpty) {
                      actions
                        ..add(TextButton(
                          onPressed: () =>
                              onLearnMore(announcement.link),
                          child: const Text('了解详情'),
                        ))
                        ..add(const SizedBox(width: 10));
                    }
                    actions.add(
                      Expanded(
                        child: FolmePress(
                          child: FilledButton(
                            autofocus: true,
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(),
                            child: Text(announcement.button),
                          ),
                        ),
                      ),
                    );
                  }

                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: sections,
                        ),
                      ),
                      if (linkFallback.isNotEmpty)
                        Padding(
                          padding:
                              const EdgeInsets.fromLTRB(20, 14, 20, 0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '无法打开浏览器，链接已复制，可手动粘贴：',
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                              const SizedBox(height: 4),
                              SelectableText(
                                linkFallback,
                                style: textTheme.bodySmall?.copyWith(
                                  color: scheme.primary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
                        child: Row(children: actions),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}

/// 启动弹窗触发器：包裹在 home 的 HomeScreen 外（锁屏 ProfilesScreen
/// 不经过此组件故不弹）。首帧后再等 1.5s 触发，避开冷启动预取与首屏
/// 渲染竞态；会话守卫保证整个进程生命周期最多尝试一次。
class RemoteNoticeTrigger extends StatefulWidget {
  const RemoteNoticeTrigger({
    super.key,
    required this.version,
    required this.child,
    this.debugConfig,
    this.debugFetcher,
    this.debugApplySourceConfig,
  });

  /// 当前安装版本串（AppDevice channel 提供，格式 `0.2.96+2129`）。
  final String version;
  final Widget child;
  final RemoteNoticeConfig? debugConfig;
  final RemoteConfigFetcher? debugFetcher;

  /// sourceConfig 转发桩（仅测试注入，避免真调核心桥）。
  final Future<void> Function(Map<String, dynamic> config)?
      debugApplySourceConfig;

  @override
  State<RemoteNoticeTrigger> createState() => _RemoteNoticeTriggerState();
}

class _RemoteNoticeTriggerState extends State<RemoteNoticeTrigger> {
  Timer? _pending;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pending = Timer(const Duration(milliseconds: 1500), () {
        if (!mounted) return;
        unawaited(
          maybeShowRemoteNotice(
            context,
            currentVersion: widget.version,
            debugConfig: widget.debugConfig,
            debugFetcher: widget.debugFetcher,
            debugApplySourceConfig: widget.debugApplySourceConfig,
          ),
        );
      });
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
