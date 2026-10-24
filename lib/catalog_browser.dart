import 'dart:math';

import 'core_bridge.dart';
import 'models.dart';

String categoryName(String name) {
  final compact = name.trim().replaceAll(RegExp(r'\s+'), '');
  return switch (compact) {
    'AI成人短剧' || 'AI短剧' => 'AI 短剧',
    'AI成人漫剧' || 'AI漫剧' => 'AI 漫剧',
    'AI换脸' => 'AI 换脸',
    'AI魔改' => 'AI 魔改',
    'AI剧' => 'AI 剧',
    '' => '未分类',
    _ => name.trim(),
  };
}

/// 首页「题材」本地筛选词表（local: 类目）。不依赖源站分类上报——
/// 无论条目带不带分类字段，筛选条都固定提供这些题材，匹配见
/// [matchesLocalGenre]：分类/标签/标题/简介任一命中即算。
///
/// 短剧与视频的内容类型不同，词表按组的内容类型分别下发：
/// 短剧组（含混合组）给短剧题材词，纯视频组另外给影视题材词。
const shortDramaGenreCatalog = [
  '总裁', '战神', '赘婿', '甜宠', '逆袭', '闪婚', '复仇', '重生',
  '穿越', '萌宝', '豪门', '神豪', '玄幻', '都市', '古装', '年代',
  '追妻', '马甲', '神医', '离婚', '乡村', '民国', '女帝', '先婚后爱',
];

/// 影视类站源（maccms 系）的题材/类型词：按片单类型筛选。
const videoGenreCatalog = [
  '动作', '喜剧', '悬疑', '科幻', '恐怖', '惊悚', '爱情', '战争',
  '犯罪', '动画', '纪录', '奇幻', '冒险', '剧情', '武侠', '家庭',
  '历史', '音乐', '传记', '运动',
];

/// 按组的内容类型挑选题材词：纯视频组只用影视词，其余情况给短剧词，
/// 混合组两套都给。
List<String> genreCatalogFor(SourceGroup group) {
  final short = group.sources.any((source) => source.isShortDrama);
  final video = group.sources.any((source) => source.isVideoSource);
  return [
    if (short || !video) ...shortDramaGenreCatalog,
    if (video) ...videoGenreCatalog,
  ];
}

/// 题材本地匹配：优先命中条目的分类字段（源站 genre 的规范化名），
/// 其次标签；标题/简介兜底（「战神归来」标题即含题材词）。
bool matchesLocalGenre(Drama drama, String genre) {
  if (categoryName(drama.category) == genre) return true;
  for (final tag in drama.tags) {
    if (tag.contains(genre)) return true;
  }
  return drama.title.contains(genre) || drama.description.contains(genre);
}

/// 短剧/长剧的分界：单集时长超过 10 分钟（600 秒）即长剧。
/// 全源统一规则，与站源注册分类无关。
const int longDramaThresholdSeconds = 600;

/// 「长剧/短剧」本地分类 id。local: 前缀走本地过滤，但与题材词
/// （'local:<词>'）不同源，home_screen 侧需先按这两个 id 分流。
const String localLongCategory = 'local:kind:long';
const String localShortCategory = 'local:kind:short';

/// 判定条目是长剧还是短剧：
/// 1. 有单集时长数据 → 时长 >600 秒即长剧；
/// 2. 无时长数据 → 条目短剧信号兜底（分类/标签含「短剧」，如真果·鉴
///    的 short_drama 条目与 maccms 短剧频道）；
/// 3. 仍无信号 → 站源注册分类（短剧源→短剧），最后默认长剧
///    （视频类内容以电视剧/电影为主，宁判长不冒充短剧）。
bool dramaIsLongDrama(Drama drama, SourceSite? site) {
  if (drama.duration > 0) return drama.duration > longDramaThresholdSeconds;
  if (drama.category.contains('短剧')) return false;
  for (final tag in drama.tags) {
    if (tag.contains('短剧')) return false;
  }
  if (site != null && site.isShortDrama) return false;
  return true;
}

class _CatalogChoice {
  _CatalogChoice(this.category);
  final CatalogCategory category;
  final requests = <String, String>{};
}

class _CatalogEntry {
  List<Drama> items = [];
  int page = 0;
  int nextPage = 1;
  bool hasMore = true;
  bool fresh = false;
}

class _CatalogSession {
  final entries = <String, _CatalogEntry>{};
  int generation = 0;
}

class CatalogBrowser {
  CatalogBrowser(this.repository);
  final AppRepository repository;
  final _menus = <String, List<CatalogCategory>>{};
  final _library = <String, Map<String, Drama>>{};
  final _sessions = <String, _CatalogSession>{};
  int _generation = 0;

  /// 条目池版本号：_remember/updateDramas 改动库时递增，让内容命中
  /// 缓存（_contentfulCache）失效重算，避免 build 期全量重复匹配。
  int _libraryEpoch = 0;
  final _contentfulCache = <String, (int, Set<String>)>{};

  Future<void> cancel() {
    _generation++;
    for (final session in _sessions.values) {
      session.generation++;
    }
    return repository.cancelCatalog();
  }

  void _remember(String source, Iterable<Drama> items) {
    _libraryEpoch++;
    final library = _library.putIfAbsent(source, () => {});
    for (final drama in items) {
      if (drama.source == source) {
        library[drama.id] = library[drama.id]?.merge(drama) ?? drama;
      }
    }
  }

  void updateDrama(Drama drama) {
    updateDramas([drama]);
  }

  void updateDramas(Iterable<Drama> dramas) {
    // 详情回填可能改变时长/分类/标签，内容命中判定随之变化。
    _libraryEpoch++;
    final updates = {for (final drama in dramas) drama.id: drama};
    for (final drama in updates.values) {
      final library = _library[drama.source];
      if (library?.containsKey(drama.id) == true) {
        library![drama.id] = library[drama.id]!.merge(drama);
      }
    }
    for (final session in _sessions.values) {
      for (final entry in session.entries.values) {
        entry.items = [
          for (final item in entry.items)
            updates[item.id] == null ? item : item.merge(updates[item.id]!),
        ];
      }
    }
  }

  Future<void> _each<T>(List<T> entries, Future<void> Function(T) visit) async {
    var index = 0;
    Future<void> worker() async {
      while (index < entries.length) {
        final entry = entries[index++];
        await visit(entry);
      }
    }

    await Future.wait(List.generate(min(2, entries.length), (_) => worker()));
  }

  Future<String?> loadCategories(
    SourceGroup group, {
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final failures = <String>[];
    await _each(group.sources, (source) async {
      try {
        final cached = await repository.cached(source.id);
        _remember(source.id, cached.items);
      } catch (_) {}
      if (cacheOnly) return;
      try {
        _menus[source.id] = await repository.categories(
          source.id,
          force: force,
        );
      } catch (_) {
        failures.add(source.groupName);
      }
    });
    return failures.isEmpty ? null : '部分分类暂未加载，点击重试';
  }

  List<_CatalogChoice> _choices(SourceGroup group) {
    final choices = <String, _CatalogChoice>{};
    for (final source in group.sources) {
      for (final category in _menus[source.id] ?? const <CatalogCategory>[]) {
        if (category.id.isEmpty) continue;
        final name = categoryName(category.name);
        final choice = choices.putIfAbsent(
          name,
          () => _CatalogChoice(CatalogCategory('category:$name', name)),
        );
        choice.requests[source.id] = category.id;
      }
    }
    final names = {
      for (final source in group.sources)
        for (final item in _library[source.id]?.values ?? const <Drama>[])
          categoryName(item.category),
    }.toList()..sort();
    for (final name in names) {
      choices.putIfAbsent(
        name,
        () => _CatalogChoice(CatalogCategory('local:$name', name, local: true)),
      );
    }
    return choices.values.toList();
  }

  /// 组内条目池上有内容的 local 类目 id 集合（长剧/短剧档 + 题材词）。
  /// 判定与 home_screen._visible 的 local 过滤同源
  /// （dramaIsLongDrama/matchesLocalGenre），保证显示的分组点进去必有内容。
  Set<String> _contentfulLocals(SourceGroup group) {
    final key = group.sources.map((source) => source.id).join('|');
    final cached = _contentfulCache[key];
    if (cached != null && cached.$1 == _libraryEpoch) return cached.$2;
    final genres = genreCatalogFor(group);
    final hits = <String>{};
    for (final source in group.sources) {
      for (final drama in _library[source.id]?.values ?? const <Drama>[]) {
        final site = SourceSite.byId(drama.source);
        hits.add(
          dramaIsLongDrama(drama, site)
              ? localLongCategory
              : localShortCategory,
        );
        for (final genre in genres) {
          if (matchesLocalGenre(drama, genre)) hits.add('local:$genre');
        }
      }
    }
    _contentfulCache[key] = (_libraryEpoch, hits);
    return hits;
  }

  List<CatalogCategory> categories(SourceGroup group) {
    final known = _choices(group)
        .map((choice) => choice.category.name)
        .toSet()
      // 「未分类」是空 category 的兜底名，不算源站自带分组。
      ..remove(categoryName(''));
    // 本地兜底组（长剧/短剧档与题材词）的内容完全来自条目池，按池命中
    // 过滤：没有对应内容的分组不下发（点进去必空），条目到达后自然出现。
    // category: 源站上报组不在此列——其内容在服务端，本地浏览缓存只是
    // 冰山一角，按池判定会误杀。
    final hits = _contentfulLocals(group);
    return [
      CatalogCategory.all,
      // 短剧/长剧固定档：按单集时长（>10 分钟=长剧）全源统一划分，
      // 不依赖源站分类上报，与题材词兜底互不冲突。
      if (hits.contains(localLongCategory))
        const CatalogCategory(localLongCategory, '长剧', local: true),
      if (hits.contains(localShortCategory))
        const CatalogCategory(localShortCategory, '短剧', local: true),
      for (final choice in _choices(group)) choice.category,
      // 固定题材词表只作兜底：源站自己上报过分类（条目带分类字段）时
      // 不再追加提示词分组，避免与源自带分组重复/冲突；完全无分类的
      // 源（如部分 maccms 采集站）才下发词表。
      if (known.isEmpty)
        for (final genre in genreCatalogFor(group))
          if (hits.contains('local:$genre'))
            CatalogCategory('local:$genre', genre, local: true),
    ];
  }

  _CatalogChoice? _choice(SourceGroup group, String category) => _choices(
    group,
  ).where((choice) => choice.category.id == category).firstOrNull;

  Future<CatalogPage> load(
    SourceGroup group, {
    String category = '',
    String query = '',
    String sort = '',
    bool more = false,
    bool force = false,
    bool useCache = false,
    bool cacheOnly = false,
    void Function(CatalogPage)? onCached,
  }) async {
    if (cacheOnly && (more || force || query.trim().isNotEmpty)) {
      throw AppFailure('缓存读取不能同时请求搜索或续页');
    }
    final request = ++_generation;
    for (final session in _sessions.values) {
      session.generation++;
    }
    await repository.cancelCatalog();
    if (request != _generation) throw AppFailure('已取消加载');
    final choice = query.isEmpty ? _choice(group, category) : null;
    final requests = choice != null && !choice.category.local
        ? choice.requests
        : {for (final source in group.sources) source.id: ''};
    final key =
        '${group.sources.map((s) => s.id).join(',')}|'
        '${choice?.category.local == false ? category : ''}|$query|'
        // 服务端排序参与会话隔离：不同排序各自缓存页序，切换排序即切换会话。
        '$sort';
    final session = _sessions.putIfAbsent(key, _CatalogSession.new);
    final generation = ++session.generation;
    final failures = <String, String>{};
    final sourceOrder = requests.keys.toList();
    for (final source in sourceOrder) {
      session.entries.putIfAbsent(source, _CatalogEntry.new);
    }

    CatalogPage snapshot() {
      final rows = sourceOrder
          .map((source) => session.entries[source]!.items)
          .toList();
      final items = <String, Drama>{};
      final count = rows.fold<int>(0, (count, row) => max(count, row.length));
      for (var index = 0; index < count; index++) {
        for (final row in rows) {
          if (index < row.length) items[row[index].id] = row[index];
        }
      }
      if (choice != null) {
        for (final source in group.sources) {
          for (final item in _library[source.id]?.values ?? const <Drama>[]) {
            if (choice.category.local ||
                categoryName(item.category) == choice.category.name) {
              items.putIfAbsent(item.id, () => item);
            }
          }
        }
      }
      return CatalogPage(
        items.values.toList(),
        hasMore: sourceOrder.any((source) => session.entries[source]!.hasMore),
        page: sourceOrder.fold<int>(
          1,
          (page, source) => max(page, session.entries[source]!.page),
        ),
        fresh: sourceOrder.every((source) => session.entries[source]!.fresh),
        warning: failures.values.toSet().join('；'),
      );
    }

    if ((useCache || cacheOnly) && !force && !more && query.isEmpty) {
      await _each(sourceOrder, (source) async {
        try {
          final cached = await repository.cached(
            source,
            category: requests[source]!,
          );
          if (generation != session.generation || cached.items.isEmpty) return;
          final entry = session.entries[source]!;
          entry.items = cached.items;
          entry.page = cached.page;
          entry.nextPage = cached.page + 1;
          entry.hasMore = cached.hasMore || cached.warning.isNotEmpty;
          entry.fresh = cached.fresh && cached.warning.isEmpty;
          if (cached.warning.isNotEmpty) failures[source] = cached.warning;
          _remember(source, cached.items);
        } catch (error) {
          if (cacheOnly) failures[source] = error.toString();
        }
      });
      if (generation != session.generation) return snapshot();
      final cached = snapshot();
      if (cached.items.isNotEmpty) onCached?.call(cached);
      if (cacheOnly) return cached;
      if (cached.fresh && cached.items.isNotEmpty) return cached;
    }

    await _each(sourceOrder, (source) async {
      if (generation != session.generation) return;
      final entry = session.entries[source]!;
      if (more && !entry.hasMore) return;
      if (useCache && !force && !more && entry.fresh) return;
      final page = more ? entry.nextPage : 1;
      try {
        final result = await repository.catalog(
          source,
          category: requests[source]!,
          query: query,
          sort: sort,
          page: page,
          force: force,
        );
        if (generation != session.generation) return;
        final items = <String, Drama>{
          if (more)
            for (final item in entry.items) item.id: item,
          for (final item in result.items) item.id: item,
        };
        entry.items = items.values.toList();
        entry.page = result.page;
        entry.nextPage = result.warning.isEmpty ? result.page + 1 : page;
        entry.hasMore =
            (query.isEmpty || (SourceSite.byId(source)?.pagedSearch ?? false)) &&
            (result.hasMore || result.warning.isNotEmpty);
        entry.fresh = result.fresh && result.warning.isEmpty;
        if (query.isEmpty) _remember(source, result.items);
        if (result.warning.isNotEmpty) {
          failures[source] = result.warning;
        } else {
          failures.remove(source);
        }
      } catch (error) {
        if (generation != session.generation) return;
        entry.nextPage = page;
        entry.hasMore =
            query.isEmpty || (SourceSite.byId(source)?.pagedSearch ?? false);
        entry.fresh = false;
        if (force) entry.items = [];
        failures[source] = error.toString();
      }
    });
    final result = snapshot();
    if (result.items.isEmpty && failures.isNotEmpty) {
      throw AppFailure(result.warning);
    }
    return result;
  }
}
