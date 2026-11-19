import 'package:flutter/material.dart';

import 'core_bridge.dart';
import 'detail_screen.dart';
import 'floating_card.dart';
import 'local_store.dart';
import 'models.dart';

/// 多源精选：复刻站源 homeVod()「推荐 = 平台首页精选位」的语义。
/// 只在【与锚点源同一分类】的其它站源之间轮换（三分类口径见
/// SourceSite.classKey）：短剧类只抽短剧站，视频类只抽视频站，黄果类
/// 只在黄果系入口之间轮换，避免跨类推荐位混味；锚点通常是当前站源。
/// 按「当年天数 + shift」确定性轮换：刷新不乱跳、一天一换；shift 供
/// 「换一换」类操作递增跳到下一个源。
const int featuredCount = 12;

/// 可用于精选轮换的站源：排除锚点自身，且三分类与锚点一致。
/// 无同类可轮换时返回空表（单源变体常见），调用方按无精选位处理。
List<String> featuredSources(LocalStore store, SourceSite anchor) => [
  for (final site in store.sources)
    if (site.id != anchor.id &&
        site.classKey == anchor.classKey &&
        store.allowsSource(site.id))
      site.id,
];

/// 今天的精选源；黄果类锚点不走精选（返回空串，轮播回退自家条目，
/// 黄豆/剧果/野果等即使开启也只在自家内容里出轮播位）；无可轮换源
/// 返回空串，调用方按空隐藏精选位。
String pickFeaturedSource(
  LocalStore store,
  SourceSite anchor, {
  int shift = 0,
}) {
  if (anchor.inHuangguoCategory) return '';
  final sources = featuredSources(store, anchor);
  if (sources.isEmpty) return '';
  final now = DateTime.now();
  final dayOfYear = now.difference(DateTime(now.year, 1, 1)).inDays;
  return sources[(dayOfYear + shift) % sources.length];
}

/// 拉取精选源的首页目录，截取精选位条目数。
Future<List<Drama>> loadFeatured(
  AppRepository repository,
  String source,
) async {
  final page = await repository.catalog(source);
  return page.items.take(featuredCount).toList(growable: false);
}

/// —— 豆瓣选片 ——
///
/// 首页轮播直接播豆瓣「近期热门国产剧」榜（用户定调 2026-10-19）：榜
/// 单条目本身上卡（豆瓣封面由封面下载层带站内 Referer 拉取），带蓝色
/// 豆瓣徽章 + 评分摘要；点击经同名搜索聚合多个站源的命中，由用户选源
/// 后进详情（openDoubanReferral）。榜单条目不足 [doubanMatchCount] 张由调用方
/// 用当前源条目补位；黄果类锚点整体不拉榜、纯回退自家条目。
///
/// - 缓存：按「当年天数|锚点」会话级缓存（含空结果），切站源/回首页
///   当天不重拉。任何失败返回空表，轮播静默回退。
const int doubanMatchCount = 5;

/// 轮播取片的豆瓣官方合集：近期热门国产剧（TTL 1h，Go 端缓存）。
const String doubanCarouselBoard = 'douban-tv-domestic';

/// 轮播的豆瓣卡：[drama] 是豆瓣榜单条目本身（无播放链路），[tag] 是
/// 豆瓣评分摘要（如「8.5分」「1994」），供卡片徽章展示。
class DoubanPick {
  const DoubanPick(this.drama, this.tag);
  final Drama drama;
  final String tag;
}

class _DoubanPickCache {
  const _DoubanPickCache(this.picks);
  final List<DoubanPick> picks;
}

final Map<String, _DoubanPickCache> _doubanCaches = {};

/// 轮播的「按类取榜」卡：[drama] 是榜单条目本身（带真实源，可直接播放；
/// 豆瓣条目无播放链路），[boardLabel] 是左上角来源徽章（如「豆瓣」「红果榜」
/// 「黄果榜」），[tag] 是评分/热度摘要（豆瓣取评分，其它类可空）。
class RankingPick {
  const RankingPick(this.drama, {this.boardLabel = '', this.tag = ''});
  final Drama drama;
  final String boardLabel;
  final String tag;
}

class _CategoryPickCache {
  const _CategoryPickCache(this.picks);
  final List<RankingPick> picks;
}

/// 「按类取榜」会话缓存（仿 [_doubanCaches]）：按「当天|锚点」落键。
final Map<String, _CategoryPickCache> _categoryCaches = {};

/// 测试专用：清空豆瓣选片会话缓存（生产路径按天自然失效）。
@visibleForTesting
void clearDoubanPicksCache() => _doubanCaches.clear();

/// 测试专用：清空按类取榜会话缓存。
@visibleForTesting
void clearCategoryPicksCache() => _categoryCaches.clear();

String _doubanDayKey() {
  final now = DateTime.now();
  return '${now.year}-${now.difference(DateTime(now.year, 1, 1)).inDays}';
}

/// 今天的豆瓣榜单：近期热门国产剧（用户定调轮播播国产剧，不再按天
/// 轮换 top250/weekly）。
String doubanBoardForToday() => doubanCarouselBoard;

/// 今天的豆瓣选片缓存是否已能填满 [need] 张：首页判断「条目变化是否
/// 需要刷新补位」用——命中已满格时补位卡不上屏，网格条目变化无需重拉。
bool doubanPicksFill(int need, SourceSite anchor) {
  if (anchor.inHuangguoCategory) return false;
  final cached = _doubanCaches['${_doubanDayKey()}|${anchor.id}'];
  return cached != null && cached.picks.length >= need;
}

/// 轮播取片是否已能填满 [need] 张：视频类走豆瓣缓存判定；其它大类走
/// 按类取榜缓存判定（不再对黄果类恒返回 false——黄果类现在也拉自家榜）。
bool categoryPicksFill(int need, SourceSite anchor) {
  if (anchor.classKey == SourceSite.douban.classKey) {
    return doubanPicksFill(need, anchor);
  }
  final cached = _categoryCaches['${_doubanDayKey()}|${anchor.id}'];
  return cached != null && cached.picks.length >= need;
}

/// 今天的豆瓣选片结果：命中「当天+锚点已搜过」直接返回缓存，否则拉
/// 榜单剧名并发搜同类站源（口径见「豆瓣选片」注释块）。
Future<List<DoubanPick>> loadDoubanPicks(
  AppRepository repository,
  LocalStore store,
  SourceSite anchor,
) async {
  // 黄果类锚点不搜：轮播整体回退自家条目，零请求。
  if (anchor.inHuangguoCategory) return const [];
  final cacheKey = '${_doubanDayKey()}|${anchor.id}';
  final cached = _doubanCaches[cacheKey];
  if (cached != null) return cached.picks;
  final picks = await _searchDoubanPicks(repository, store, anchor);
  _doubanCaches[cacheKey] = _DoubanPickCache(picks);
  return picks;
}

Future<List<DoubanPick>> _searchDoubanPicks(
  AppRepository repository,
  LocalStore store,
  SourceSite anchor,
) async {
  try {
    final page = await repository.rankings(doubanBoardForToday());
    // 榜单条目本身直接上卡；豆瓣榜自身偶有重复条目，按规范化标题去重。
    // 徽章标签取 metric 首段——榜单页展示完整「8.5分 · N人评价 · 年份」，
    // 轮播徽章只放「8.5分」一级摘要，避免长串挤爆卡片。
    final picks = <DoubanPick>[];
    final seenTitles = <String>{};
    for (final item in page.items) {
      final title = item.drama.title.trim();
      if (title.isEmpty) continue;
      if (!seenTitles.add(_normalizeTitle(title))) continue;
      picks.add(DoubanPick(item.drama, item.metric.split(' · ').first.trim()));
      if (picks.length >= doubanMatchCount) break;
    }
    return List.unmodifiable(picks);
  } catch (_) {
    // 榜单拉取失败静默：首页主体是剧卡流，不打扰。
    return const [];
  }
}

/// 轮播按大类取榜：视频类复用豆瓣选片（用户定调「视频类的不用改」），其余
/// 大类直接播该大类自己的榜单（取首个归属当前 classKey 的榜，主热播榜），
/// 条目带真实源、点按直接进详情/播放。任何失败返回空 → 轮播静默回退当前
/// 源条目。
Future<List<RankingPick>> loadCategoryRankingPicks(
  AppRepository repository,
  LocalStore store,
  SourceSite anchor,
) async {
  // 视频类：保持豆瓣选片（零改动复用），徽章标「豆瓣」+ 评分摘要。
  if (anchor.classKey == SourceSite.douban.classKey) {
    final picks = await loadDoubanPicks(repository, store, anchor);
    return [
      for (final pick in picks)
        RankingPick(pick.drama, boardLabel: '豆瓣', tag: pick.tag),
    ];
  }
  final cacheKey = '${_doubanDayKey()}|${anchor.id}';
  final cached = _categoryCaches[cacheKey];
  if (cached != null) return cached.picks;
  final picks = await _searchCategoryPicks(repository, anchor);
  _categoryCaches[cacheKey] = _CategoryPickCache(picks);
  return picks;
}

/// 按锚点大类取首个匹配榜的条目：与榜单页「按内容类型」口径一致。
Future<List<RankingPick>> _searchCategoryPicks(
  AppRepository repository,
  SourceSite anchor,
) async {
  try {
    final boards = await repository.rankingBoards();
    // 取首个归属当前大类的榜（主热播榜）；按类隔离与榜单页同口径。
    final matches = boards.where(
      (b) => SourceSite.byId(b.source)?.classKey == anchor.classKey,
    );
    final board = matches.isEmpty ? null : matches.first;
    if (board == null) return const [];
    final page = await repository.rankings(board.id);
    final picks = <RankingPick>[];
    final seenTitles = <String>{};
    final label = '${SourceSite.byId(board.source)?.name ?? board.source}榜';
    for (final item in page.items) {
      final title = item.drama.title.trim();
      if (title.isEmpty) continue;
      if (!seenTitles.add(_normalizeTitle(title))) continue;
      // 与榜单页 _rankingMetricLabel 同口径：站源榜条目也展示 item.metric
      // （红果原始热度数字、黄豆「X热度」等），空 metric 时只显示来源徽章。
      picks.add(RankingPick(item.drama, boardLabel: label, tag: item.metric.trim()));
      if (picks.length >= doubanMatchCount) break;
    }
    return List.unmodifiable(picks);
  } catch (_) {
    // 榜单拉取失败静默：首页主体是剧卡流，不打扰。
    return const [];
  }
}

/// 标题规范化：小写、去空白与中英文标点，容纳「名：副题」「名（2024）」
/// 这类排版差异，只留字母数字汉字参与比较。
String _normalizeTitle(String title) =>
    title.toLowerCase().replaceAll(RegExp(r'[\s\p{P}\p{S}]', unicode: true), '');

/// 豆瓣条目点击跳转（全局单飞，榜单页与首页轮播共用）。
bool _doubanReferralBusy = false;

/// 测试专用：重置单飞标志，隔离用例间的跳转状态。
@visibleForTesting
void resetDoubanReferralBusy() => _doubanReferralBusy = false;

/// 同名跳转最多并发查的站源数。候选覆盖全部已启用大类（短剧/视频/
/// 黄果/成人），不再只搜视频类——否则黑桃、红果等源永远进不了选择列表。
const int referralSourceLimit = 8;

/// 单源搜索超时：某个慢源不能拖住整个选择面板。
const Duration referralSearchTimeout = Duration(seconds: 6);

/// 大类轮转顺序：视频类 → 短剧类 → 黄果类 → 成人类。
int _referralClassPriority(String classKey) => switch (classKey) {
  'video' => 0,
  'shortDrama' => 1,
  'local' => 2,
  'huangguo' => 3,
  'adult' => 4,
  _ => 5,
};

/// 候选站源：当前站源优先，其余按大类轮转取（每类每轮各取一个），
/// 同类保持站源表顺序。轮转而非「按类排序后截断」，是为了不让源数量
/// 最多的视频类独占全部名额，黑桃等黄果类源也能进选择列表。
/// 榜单专用源（豆瓣）无播放链路，排除在外。
@visibleForTesting
List<String> doubanReferralSources(LocalStore store) {
  final enabled = [
    for (final site in store.sources)
      if (!SourceSite.isRankingOnly(site.id)) site.id,
  ];
  final current = store.source;
  final sources = <String>[];
  if (enabled.contains(current)) sources.add(current);
  final buckets = <String, List<String>>{};
  for (final id in enabled) {
    if (id == current) continue;
    final key = SourceSite.byId(id)?.classKey ?? '';
    buckets.putIfAbsent(key, () => <String>[]).add(id);
  }
  final keys = buckets.keys.toList()
    ..sort(
      (a, b) => _referralClassPriority(a).compareTo(
        _referralClassPriority(b),
      ),
    );
  for (var round = 0; sources.length < referralSourceLimit; round++) {
    var added = false;
    for (final key in keys) {
      final bucket = buckets[key]!;
      if (round >= bucket.length) continue;
      sources.add(bucket[round]);
      added = true;
      if (sources.length >= referralSourceLimit) break;
    }
    if (!added) break;
  }
  return List.unmodifiable(sources);
}

/// 标题匹配档位：精确 > 结果包含榜名 > 榜名包含结果。规范化后比较
/// （去标点/空白，容纳「名：副题」排版差异），短于 2 字不做包含匹配
/// 以免单字标题把整页结果都误判成同名。
@visibleForTesting
int referralMatchScore(String query, String candidate) {
  final a = _normalizeTitle(query);
  final b = _normalizeTitle(candidate);
  if (a.isEmpty || b.isEmpty) return 0;
  if (a == b) return 3;
  if (a.length >= 2 && b.contains(a)) return 2;
  if (b.length >= 2 && a.contains(b)) return 1;
  return 0;
}

class _ReferralMatch {
  const _ReferralMatch(this.drama, this.score, this.order);
  final Drama drama;
  final int score;
  final int order;
}

/// 单源只留最佳一条；失败/超时静默跳过，不影响其它源出结果。
Future<_ReferralMatch?> _searchReferralSource(
  AppRepository repository,
  String source,
  String title,
  int order,
) async {
  try {
    final page = await repository
        .catalog(source, query: title)
        .timeout(referralSearchTimeout);
    _ReferralMatch? best;
    for (final row in page.items) {
      final score = referralMatchScore(title, row.title);
      if (score == 0) continue;
      if (best == null || score > best.score) {
        best = _ReferralMatch(row, score, order);
      }
      if (score == 3) break;
    }
    return best;
  } catch (_) {
    return null;
  }
}

/// 并发搜全部候选源，按匹配档位、源顺序排序并按剧集 ID 去重。
Future<List<_ReferralMatch>> _collectReferralMatches(
  AppRepository repository,
  List<String> sources,
  String title,
) async {
  final found = <_ReferralMatch>[];
  await Future.wait([
    for (var index = 0; index < sources.length; index++)
      _searchReferralSource(repository, sources[index], title, index).then((
        match,
      ) {
        if (match != null) found.add(match);
      }),
  ]);
  final seen = <String>{};
  final unique = <_ReferralMatch>[];
  for (final match in found) {
    if (seen.add(match.drama.id)) unique.add(match);
  }
  unique.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : a.order.compareTo(b.order);
  });
  return unique;
}

/// 多个站源都有同名内容时，列出来由用户选一个再进详情。
/// [Builder] 保证 pop 用的是对话框内 context，不会误弹外层页面。
Future<Drama?> _pickReferralMatch(
  BuildContext context,
  String title,
  List<_ReferralMatch> matches,
) {
  return showFloatingDialog<Drama>(
    context: context,
    width: 340,
    barrierLabel: '选择播放来源',
    title: Text('「$title」的可播放来源'),
    content: Builder(
      builder: (dialogContext) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final match in matches)
            FloatingOptionRow(
              key: ValueKey('referral-${match.drama.source}'),
              label:
                  SourceSite.byId(match.drama.source)?.name ??
                  match.drama.source,
              subtitle: [
                match.drama.title.trim(),
                match.drama.episodeLabel,
              ].where((part) => part.isNotEmpty).join(' · '),
              onTap: () => Navigator.of(dialogContext).pop(match.drama),
            ),
        ],
      ),
    ),
  );
}

/// 按标题在所有已启用站源中并发搜同名内容（8 源并发 + 单源 6 秒超时 +
/// 失败静默跳过）。命中多条弹「选择播放来源」面板由用户挑源进详情；
/// 只命中一条直进，全部落空则提示手动搜索。
///
/// 这是豆瓣榜条目点击与「换个源找」共用的快速聚合入口——比普通分组搜索
/// 快，因为它不等待慢源（6 秒截断）且跨全部大类找源。
Future<void> openTitleReferral(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required String title,
}) async {
  if (_doubanReferralBusy) return;
  _doubanReferralBusy = true;
  final messenger = ScaffoldMessenger.of(context);
  try {
    final sources = doubanReferralSources(store);
    final query = title.trim();
    if (query.isEmpty || sources.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('当前没有可用于查找的站源')),
      );
      return;
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text('正在查找「$query」的可播放来源…'),
        duration: const Duration(seconds: 2),
      ),
    );
    final matches = await _collectReferralMatches(repository, sources, query);
    if (!context.mounted) return;
    if (matches.isEmpty) {
      messenger.showSnackBar(
        SnackBar(content: Text('未在站源中找到「$query」，可到搜索页手动查找')),
      );
      return;
    }
    Drama? target = matches.first.drama;
    if (matches.length > 1) {
      target = await _pickReferralMatch(context, query, matches);
    }
    if (target == null || !context.mounted) return;
    // 闭包捕获的可空局部变量不会被流分析收窄，落成非空局部常量再用。
    final chosen = target;
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => DetailScreen(
          drama: chosen,
          repository: repository,
          store: store,
        ),
      ),
    );
  } catch (_) {
    if (context.mounted) {
      messenger.showSnackBar(
        const SnackBar(content: Text('查找同名内容失败，请稍后重试')),
      );
    }
  } finally {
    _doubanReferralBusy = false;
  }
}

/// 豆瓣榜条目入口：保留旧签名兼容测试与既有调用，内部走通用标题聚合。
Future<void> openDoubanReferral(
  BuildContext context, {
  required AppRepository repository,
  required LocalStore store,
  required Drama drama,
}) => openTitleReferral(
  context,
  repository: repository,
  store: store,
  title: drama.title,
);
