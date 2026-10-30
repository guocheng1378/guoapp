import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'local_store.dart';
import 'models.dart';
import 'related_catalog_screen.dart';
import 'widgets.dart';

/// 一次候选查询：拿到内容就停，拿不到就降级到下一级。
class RelatedAttempt {
  const RelatedAttempt(this.label, {this.query = '', this.category = ''});
  final String label;
  final String query;
  final String category;
}

/// 剧名主干：剥掉尾部的系列后缀（「第N部/第N季/番外/1~2位续集数字」），
/// 拿主干搜索就能带回同系列各部。裸数字只剥 1~2 位（「长公主驾到2」），
/// 4 位年份（「重生1998」）绝不剥——搜「重生」只会捞回一屏无关剧；
/// 剥完太短（<3 字）也不可靠，一律返回原题让调用方跳过同系列尝试。
final _seriesSuffix = RegExp(
  r'[\s　]*[（(【\[]?\s*(第[0-9一二三四五六七八九十百]+[部季]|番外篇?|[0-9]{1,2})\s*[）)】\]]?$',
);

String seriesBaseTitle(String title) {
  final trimmed = title.trim();
  final base = trimmed.replaceAll(_seriesSuffix, '').trim();
  if (base.length >= 3 && base != trimmed) return base;
  return trimmed;
}

/// 简介页「相关推荐」的候选链。
///
/// 按相关度从高到低：同系列（剧名主干搜索）→ 同主演（首个主演搜索，
/// maccms 站内检索覆盖主演字段；红果不暴露主演数据自然跳过）
/// → 站点 content_kind（最贴分类）→ 分类关键词 → 前两个标签
/// → 该源全部（兜底，宁可内容不够贴也不要什么都没有）。
List<RelatedAttempt> relatedAttemptsFor(Drama drama) {
  final attempts = <RelatedAttempt>[];
  final base = seriesBaseTitle(drama.title);
  if (base.isNotEmpty && base != drama.title.trim()) {
    attempts.add(RelatedAttempt('同系列', query: base));
  }
  String actor = '';
  for (final candidate in drama.actors) {
    final name = candidate.trim();
    if (name.length >= 2) {
      actor = name;
      break;
    }
  }
  if (actor.isNotEmpty) attempts.add(RelatedAttempt(actor, query: actor));
  final category = drama.category.trim();
  if (category.isNotEmpty) {
    final kind = kindIdForCategory(drama.source, category);
    if (kind.isNotEmpty) attempts.add(RelatedAttempt(category, category: kind));
    attempts.add(RelatedAttempt(category, query: category));
  }
  for (final tag in drama.tags) {
    final label = tag.trim();
    if (label.isEmpty || attempts.length >= 6) continue;
    attempts.add(RelatedAttempt(label, query: label));
  }
  attempts.add(const RelatedAttempt('全部'));
  return attempts;
}

/// 简介页底部的「相关推荐」横向卡条。
///
/// 为什么不复用 repository.recommendations(genre)：那是**红果专用**推荐
/// （core_bridge 里 _authorize('hongguo')，其它站源直接抛错），而且按题材推荐、
/// 与当前这部剧无关 — 在真果·鉴上是一片空白。真正「与这部剧同类」的数据只能从
/// repository.catalog 取，所以这里按 relatedAttemptsFor 分级降级拿第一页。
///
/// 加载中/失败/空结果一律 SizedBox.shrink：简介页的主体是简介与剧集，推荐是
/// 锦上添花，不能因为某个源不支持检索就在这里摆一块错误面板。
class RelatedDramaRail extends StatefulWidget {
  const RelatedDramaRail({
    super.key,
    required this.repository,
    required this.store,
    required this.drama,
    required this.onOpen,
    this.maxItems = 12,
  });

  final AppRepository repository;
  final LocalStore store;
  final Drama drama;
  final ValueChanged<Drama> onOpen;
  final int maxItems;

  @override
  State<RelatedDramaRail> createState() => _RelatedDramaRailState();
}

class _RelatedDramaRailState extends State<RelatedDramaRail> {
  final _items = <Drama>[];
  bool _loading = true;
  int _generation = 0;
  RelatedAttempt _hit = const RelatedAttempt('全部');

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant RelatedDramaRail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.drama.id != widget.drama.id ||
        oldWidget.repository != widget.repository) {
      _load();
    }
  }

  Future<void> _load() async {
    final request = ++_generation;
    if (mounted) {
      setState(() {
        _loading = true;
        _items.clear();
      });
    }
    var missed = false;
    final attempts = relatedAttemptsFor(widget.drama);
    for (final attempt in attempts) {
      final found = await _fetch(attempt);
      if (request != _generation) return;
      if (found.isEmpty) {
        missed = true;
        continue;
      }
      if (!mounted) return;
      setState(() {
        _items
          ..clear()
          ..addAll(found.take(widget.maxItems));
        _hit = attempt;
        _loading = false;
      });
      return;
    }
    // 整条链都空：真机上最常见的原因是同源目录读取正在排队或被上层的
    // cancelCatalog 掐掉（详情页刚打开时首页仍在收尾），一次抖动不该让整块
    // 推荐消失。歇一下只重试「该源全部」这一级（它必然有第一页数据）。
    if (missed) {
      await Future<void>.delayed(const Duration(milliseconds: 800));
      if (request != _generation) return;
      final retry = await _fetch(const RelatedAttempt('全部'));
      if (request != _generation) return;
      if (retry.isNotEmpty && mounted) {
        setState(() {
          _items
            ..clear()
            ..addAll(retry.take(widget.maxItems));
          _hit = const RelatedAttempt('全部');
          _loading = false;
        });
        return;
      }
    }
    if (!mounted || request != _generation) return;
    // 生产包也打一行：真机上「没有推荐」时靠它区分是没数据还是没渲染。
    debugPrint(
      '相关推荐为空：source=${widget.drama.source} '
      'category=${widget.drama.category} tags=${widget.drama.tags.take(2)}',
    );
    setState(() => _loading = false);
  }

  Future<List<Drama>> _fetch(RelatedAttempt attempt) async {
    try {
      final page = await widget.repository.catalog(
        widget.drama.source,
        page: 1,
        query: attempt.query,
        category: attempt.category,
      );
      return page.items
          .where(
            (item) =>
                item.id.isNotEmpty &&
                item.id != widget.drama.id &&
                item.source == widget.drama.source,
          )
          .toList();
    } catch (_) {
      // 部分源不支持按分类/关键词检索，或者源本身不可用 —— 静默降级到下一级。
      return const <Drama>[];
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading || _items.isEmpty) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 18),
        Row(
          children: [
            Text(
              '相关推荐',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
            ),
            const Spacer(),
            TextButton(
              onPressed: () => openRelatedCatalog(
                context,
                repository: widget.repository,
                store: widget.store,
                drama: widget.drama,
                label: _hit.label,
              ),
              child: const Text('查看全部'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 196,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: _items.length,
            itemBuilder: (context, index) => Padding(
              padding: const EdgeInsets.only(right: 10),
              child: _card(colors, _items[index]),
            ),
          ),
        ),
      ],
    );
  }

  Widget _card(ColorScheme colors, Drama drama) {
    return SizedBox(
      width: 104,
      child: InkWell(
        // 卡片 key：简介页标题与卡片文本会重名，测试要按 id 精确断言排除自身。
        key: ValueKey('related-card-${drama.id}'),
        borderRadius: BorderRadius.circular(8),
        onTap: () => widget.onOpen(drama),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // DramaCover 内部是 Stack，必须有界高度：这里用 AspectRatio 给。
            AspectRatio(
              aspectRatio: 0.74,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: DramaCover(drama: drama, repository: widget.repository),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              drama.title,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            if (drama.episodeLabel.isNotEmpty)
              Text(
                drama.episodeLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
              ),
          ],
        ),
      ),
    );
  }
}
