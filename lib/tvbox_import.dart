import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import 'custom_sources.dart';
import 'floating_card.dart';
import 'live_source_entry.dart';
import 'local_store.dart';
import 'tvbox_config.dart';

class TvboxImportOutcome {
  const TvboxImportOutcome({
    required this.sitesAdded,
    required this.liveUrlsAdded,
    required this.skippedSites,
    required this.errors,
  });

  final int sitesAdded;
  final int liveUrlsAdded;
  final int skippedSites;
  final List<String> errors;

  String get summary {
    final parts = <String>[
      '已导入 $sitesAdded 个站源、$liveUrlsAdded 个直播源',
    ];
    if (skippedSites > 0) parts.add('跳过 $skippedSites 个已存在或超限');
    if (errors.isNotEmpty) parts.add('${errors.length} 项失败');
    return parts.join('，');
  }
}

/// 直播订阅的去重键：普通订阅用 URL；内联条目（TVBox 的 channels 正文）的
/// URL 只是配置内序号，必须连正文一起比，否则不同配置会互相吞掉。
String _liveEntryKey(LiveSourceEntry entry) {
  if (!entry.isInline) return entry.url;
  var hash = 0;
  for (final unit in entry.payload.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return '${entry.url}#$hash';
}

/// 执行导入计划：逐条登记自定义站源 → 一次全量下发 Go 核心 → 合并直播订阅。
/// [publish] 由调用方提供（repository.setCustomSources），便于测试替换。
Future<TvboxImportOutcome> applyTvboxImport({
  required LocalStore store,
  required Future<void> Function(List<CustomSourceSpec> sources) publish,
  required TvboxImportPlan plan,
}) async {
  final errors = <String>[];
  final existing = <String>{
    for (final source in store.customSources) source.url,
  };
  var sitesAdded = 0;
  var skippedSites = 0;
  final addedIds = <String>[];
  for (var i = 0; i < plan.sites.length; i++) {
    final site = plan.sites[i];
    if (existing.contains(site.url)) {
      skippedSites++;
      continue;
    }
    if (store.customSources.length >= CustomSourceSpec.maxSources) {
      errors.add('自定义站源已达 ${CustomSourceSpec.maxSources} 个上限');
      skippedSites += plan.sites.length - i;
      break;
    }
    try {
      await store.addCustomSource(
        name: site.name,
        url: site.url,
        category: site.category,
        typeId: site.typeId,
        headers: site.headers,
        localPackage: plan.localPackage,
      );
      addedIds.add(CustomSourceSpec.idFor(site.url));
      existing.add(site.url);
      sitesAdded++;
    } catch (error) {
      errors.add('${site.name}：$error');
    }
  }
  if (sitesAdded > 0) {
    try {
      await publish(store.customSources);
    } catch (error) {
      // 下发核心失败必须回滚本地：否则用户重试时全部被判「已存在」跳过，
      // 留下的是一批核心并不认识的站源。
      for (final id in addedIds) {
        try {
          await store.removeCustomSource(id);
        } catch (_) {
          // 单条回滚失败不阻断其它条目。
        }
      }
      sitesAdded = 0;
      errors.add('站源下发核心失败，已回滚本次导入：$error');
    }
  }

  var liveUrlsAdded = 0;
  if (plan.liveSources.isNotEmpty) {
    final before = store.liveSourceEntries;
    // 内联条目的 url 是 inline:N（按配置内序号生成），不同配置必然撞键：
    // 只用 url 去重会把新配置的内嵌频道静默丢掉。内联条目改按「url + 正文」。
    final seen = <String>{for (final entry in before) _liveEntryKey(entry)};
    final merged = <LiveSourceEntry>[...before];
    for (final entry in plan.liveSources) {
      final key = _liveEntryKey(entry);
      if (seen.contains(key)) continue;
      seen.add(key);
      merged.add(entry);
    }
    if (merged.length > before.length) {
      try {
        await store.setLiveSourceEntries(merged);
        liveUrlsAdded = merged.length - before.length;
      } catch (error) {
        errors.add('直播源保存失败：$error');
      }
    }
  }

  return TvboxImportOutcome(
    sitesAdded: sitesAdded,
    liveUrlsAdded: liveUrlsAdded,
    skippedSites: skippedSites,
    errors: errors,
  );
}

/// 拉取配置正文的注入点：测试用替身替代真实网络。
typedef TvboxConfigFetcher = Future<String> Function(String url);

/// 输入框里是一行 TVBox 接口地址（而不是已粘贴的 JSON 正文）。
bool looksLikeTvboxUrl(String text) {
  final lower = text.trim().toLowerCase();
  return lower.startsWith('http://') || lower.startsWith('https://');
}

const int _maxConfigBytes = 8 * 1024 * 1024;

/// TVBox 接口大多是静态 JSON，任何 UA 均可，但部分站点会拦非浏览器 UA；
/// 先按移动端浏览器 UA 取，失败再按 TVBox 常用的 okhttp UA 重试一次。
const List<String> _configUserAgents = [
  'Mozilla/5.0 (Linux; Android 13; Pixel 7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
  'okhttp/3.12.11',
];

/// 从 TVBox 接口地址拉取配置正文；失败抛 [TvboxConfigException]（文案可直接展示）。
Future<String> fetchTvboxConfig(String url) async {
  final uri = Uri.tryParse(url.trim());
  if (uri == null ||
      uri.host.isEmpty ||
      (uri.scheme != 'http' && uri.scheme != 'https')) {
    throw const TvboxConfigException('请填写 http 或 https 开头的 TVBox 接口地址');
  }
  Object? failure;
  for (final agent in _configUserAgents) {
    try {
      return await _fetchConfigText(uri, agent);
    } on TvboxConfigException catch (error) {
      failure = error;
    } on Object catch (error) {
      failure = TvboxConfigException('拉取失败：$error');
    }
  }
  throw failure is TvboxConfigException
      ? failure
      : const TvboxConfigException('拉取配置失败，请检查网络或地址');
}

Future<String> _fetchConfigText(Uri uri, String agent) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 8)
    ..userAgent = agent;
  try {
    final request = await client
        .getUrl(uri)
        .timeout(const Duration(seconds: 10));
    request.headers.set(
      HttpHeaders.acceptHeader,
      'application/json, text/plain, */*',
    );
    final response = await request
        .close()
        .timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw TvboxConfigException('地址返回 HTTP ${response.statusCode}');
    }
    final bytes = <int>[];
    await for (final chunk in response.timeout(const Duration(seconds: 20))) {
      bytes.addAll(chunk);
      if (bytes.length > _maxConfigBytes) {
        throw const TvboxConfigException('配置超过 8MB，已中止拉取');
      }
    }
    final text = utf8
        .decode(bytes, allowMalformed: true)
        .replaceFirst('\uFEFF', '')
        .trim();
    if (text.isEmpty) {
      throw const TvboxConfigException('地址返回了空内容');
    }
    if (text.startsWith('<')) {
      throw const TvboxConfigException('该地址返回的是网页，可能已失效或需要登录');
    }
    return text;
  } finally {
    client.close(force: true);
  }
}

/// 本地配置文件包的读取结果；用户取消返回 null。
class TvboxConfigFile {
  const TvboxConfigFile({required this.name, required this.content});

  final String name;
  final String content;
}

typedef TvboxConfigFileLoader = Future<TvboxConfigFile?> Function();

/// 默认实现：系统文件选择器挑一个 .json/.txt 配置包，按 UTF-8 读正文。
/// 走 SAF 选文件，不需要存储权限。
Future<TvboxConfigFile?> pickTvboxConfigFile() async {
  final file = await FilePicker.pickFile(
    dialogTitle: '选择 TVBox 配置文件',
    type: FileType.custom,
    allowedExtensions: const ['json', 'txt', 'conf', 'config'],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  final text = utf8
      .decode(bytes, allowMalformed: true)
      .replaceFirst('\uFEFF', '');
  if (text.trim().isEmpty) {
    throw const TvboxConfigException('这个文件是空的');
  }
  return TvboxConfigFile(name: file.name, content: text);
}

/// 粘贴 TVBox 配置 JSON / 填写接口地址 / 选本地配置包 → 解析预览 →
/// 用户确认后返回导入计划。
Future<TvboxImportPlan?> showTvboxImportDialog(
  BuildContext context, {
  TvboxConfigFetcher fetcher = fetchTvboxConfig,
  TvboxConfigFileLoader fileLoader = pickTvboxConfigFile,
}) {
  return showFloatingDialog<TvboxImportPlan>(
    context: context,
    barrierLabel: '导入 TVBox 配置',
    width: 460,
    title: const Text('导入 TVBox 配置'),
    actions: const [],
    content: _TvboxImportBody(fetcher: fetcher, fileLoader: fileLoader),
  );
}

/// 输入框的 controller 由对话框自身持有，避免弹窗退出动画期间提前 dispose。
class _TvboxImportBody extends StatefulWidget {
  const _TvboxImportBody({required this.fetcher, required this.fileLoader});

  final TvboxConfigFetcher fetcher;
  final TvboxConfigFileLoader fileLoader;

  @override
  State<_TvboxImportBody> createState() => _TvboxImportBodyState();
}

class _TvboxImportBodyState extends State<_TvboxImportBody> {
  final TextEditingController _controller = TextEditingController();
  TvboxImportPlan? _plan;
  String? _error;
  bool _busy = false;

  /// 本次解析的来源是本地配置文件包（导入后归「本地类」）。
  bool _sourceIsLocal = false;
  String? _localFileName;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _parse() async {
    if (_busy) return;
    final text = _controller.text.trim();
    if (!looksLikeTvboxUrl(text)) {
      _applyParsed(text);
      return;
    }
    setState(() {
      _busy = true;
      _plan = null;
      _error = null;
    });
    try {
      final body = await widget.fetcher(text);
      if (!mounted) return;
      _busy = false;
      _applyParsed(body);
    } on TvboxConfigException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _plan = null;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _plan = null;
        _error = '拉取配置失败：$error';
      });
    }
  }

  Future<void> _pickFile() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _plan = null;
      _error = null;
    });
    try {
      final file = await widget.fileLoader();
      if (!mounted) return;
      if (file == null) {
        setState(() => _busy = false);
        return;
      }
      _busy = false;
      _sourceIsLocal = true;
      _localFileName = file.name;
      _controller.clear();
      _applyParsed(file.content);
    } on TvboxConfigException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _plan = null;
        _error = error.message;
      });
    } on Object catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _plan = null;
        _error = '读取文件失败：$error';
      });
    }
  }

  void _applyParsed(String text) {
    try {
      _plan = TvboxConfigParser.parse(text, localPackage: _sourceIsLocal);
      _error = null;
    } on TvboxConfigException catch (error) {
      _plan = null;
      _error = error.message;
    }
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plan;
    final notices = plan?.notices ?? const <TvboxNotice>[];
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            '粘贴 TVBox 配置 JSON、填 TVBox 接口地址（如 https://…/tvbox.json），'
            '或直接打开手机里的本地配置包；可批量导入苹果 CMS 站源与 m3u/txt 直播订阅，'
            '本地包的站源会单独归入「本地类」。爬虫 jar、drpy 类站点会自动跳过。',
            style: TextStyle(fontSize: 12),
          ),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('tvbox-import-input'),
            controller: _controller,
            maxLines: 6,
            minLines: 3,
            decoration: const InputDecoration(
              hintText: '{"sites":[…],"lives":[…]} 或 https://…/tvbox.json',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (_) {
              // 手动改输入 = 不再是本地包来源，重置归类标记。
              final stale = _plan != null ||
                  _error != null ||
                  _sourceIsLocal ||
                  _localFileName != null;
              if (stale) {
                setState(() {
                  _plan = null;
                  _error = null;
                  _sourceIsLocal = false;
                  _localFileName = null;
                });
              }
            },
          ),
          if (_localFileName != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                '来源：本地配置包 $_localFileName（站源导入后归「本地类」）',
                key: const ValueKey('tvbox-import-local-source'),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                key: const ValueKey('tvbox-import-pick-file'),
                onPressed: _busy ? null : _pickFile,
                icon: const Icon(Icons.folder_open, size: 18),
                label: const Text('打开本地配置包'),
              ),
              const Spacer(),
              TextButton(
                key: const ValueKey('tvbox-import-parse'),
                onPressed: _busy ? null : _parse,
                child: _busy
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('解析配置'),
              ),
            ],
          ),
          if (_error != null)
            Text(
              _error!,
              key: const ValueKey('tvbox-import-error'),
              style: TextStyle(
                color: Theme.of(context).colorScheme.error,
                fontSize: 12,
              ),
            ),
          if (plan != null) ...[
            Text(
              '可导入：${plan.sites.length} 个站源 · '
              '${plan.liveSources.length} 个直播源',
              key: const ValueKey('tvbox-import-summary'),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (plan.isEmpty)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '没有可导入的内容，请查看下方跳过原因。',
                  style: TextStyle(fontSize: 12),
                ),
              ),
            for (final site in plan.sites.take(5))
              Text('站点 · ${site.name} · ${site.url}',
                  style: const TextStyle(fontSize: 11)),
            if (plan.sites.length > 5)
              Text('……另有 ${plan.sites.length - 5} 个站点',
                  style: const TextStyle(fontSize: 11)),
            for (final entry in plan.liveSources.take(3))
              Text('直播 · ${entry.displayLabel}',
                  style: const TextStyle(fontSize: 11)),
            if (plan.liveSources.length > 3)
              Text('……另有 ${plan.liveSources.length - 3} 条直播订阅',
                  style: const TextStyle(fontSize: 11)),
            if (notices.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('跳过 / 提示 ${notices.length} 项',
                  style: const TextStyle(fontSize: 12)),
              for (final notice in notices.take(6))
                Text('${notice.label}：${notice.reason}',
                    style: const TextStyle(fontSize: 11)),
              if (notices.length > 6)
                Text('……另有 ${notices.length - 6} 项',
                    style: const TextStyle(fontSize: 11)),
            ],
          ],
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                key: const ValueKey('tvbox-import-confirm'),
                onPressed: plan == null || plan.isEmpty
                    ? null
                    : () => Navigator.of(context).pop(plan),
                child: const Text('导入'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
