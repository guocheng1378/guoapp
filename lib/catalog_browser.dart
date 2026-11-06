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

/// 「长剧/短剧」本地分类 id。local: 前缀走本地过滤，但与题材词
/// （'local:<词>'）不同源，home_screen 侧需先按这两个 id 分流。
const String localLongCategory = 'local:kind:long';
const String localShortCategory = 'local:kind:short';

/// 判定条目是长剧还是短剧（**不看时长**）：
/// 1. 显式定性 [Drama.contentKind]（'short'/'long'）优先；
/// 2. 条目短剧信号（分类/标签含「短剧」，如真果·鉴的 short_drama 条目与
///    maccms 短剧频道）；
/// 3. 站源注册分类（短剧源→短剧）；
/// 4. 仍无信号 → 默认长剧（视频类内容以电视剧/电影为主，宁判长不冒充短剧）。
///
/// 时长曾是第一判据（>600 秒即长剧），但时长会漂移：条目缓存里有无、
/// 详情回填自愈都可能改变取值，同一部剧前后判定不一致 → 首页「长剧/短剧」
/// 分类档忽隐忽现、播放器形态在切集时跳变。故已移除时长判据。
bool dramaIsLongDrama(Drama drama, SourceSite? site) {
  final kind = drama.contentKind;
  if (kind == 'short') return false;
  if (kind == 'long') return true;
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

  /// 源站分类菜单版本号：loadCategories 写入 _menus 后递增。
  int _menusEpoch = 0;

  /// 分类条结果缓存（按分组键）。home_screen 的 build 每帧都会读
  /// _categories，而 categories() 要遍历全部条目池聚合分类名（O(N)），
  /// 不缓存就等于每帧扫一遍整库。键里同时带两个 epoch：条目池变化
  /// （详情回填可能改分类）与源站菜单到达都必须失效重算。
  final _categoriesCache =
      <String, (int libraryEpoch, int menusEpoch, List<CatalogCategory>)>{};

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
        _menusEpoch++;
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
    final key = group.sources.map((source) => source.id).join('|');
    final cached = _categoriesCache[key];
    if (cached != null &&
        cached.$1 == _libraryEpoch &&
        cached.$2 == _menusEpoch) {
      return cached.$3;
    }
    final choices = _choices(group);
    // 「源站自带分组」只认站点菜单：choices 还混了条目池分类名，而磁盘
    // 缓存/详情回填是逐步到达的，用它判定会让题材词表在冷启动先出现、
    // 菜单到达后整组消失（分类条闪变），也会误把条目池名字当源站分组。
    final known = <String>{
      for (final source in group.sources)
        for (final category in _menus[source.id] ?? const <CatalogCategory>[])
          categoryName(category.name),
    }..remove(categoryName(''));
    final hits = _contentfulLocals(group);
    // 内容去重而不是名字去重：旧实现给本地档恒加「·内容」后缀来回避
    // 撞名，于是「短剧」与「短剧·内容」两个 chip 内容几乎逐条相同；纯
    // 视频源全被判长剧时「长剧·内容」又与「全部」全等。只有长短剧都
    // 存在时这两个档才有区分意义，且源站已上报短剧类时不再发短剧档。
    // 任何名字里带「短剧」的既有分组（源站菜单上报的 category:短剧，
    // 或条目池分类名 local:短剧）都与本地短剧档内容重复，只保留前者。
    final hasShortNamedChoice = choices.any(
      (choice) => choice.category.name.contains('短剧'),
    );
    final hasBothKinds =
        hits.contains(localLongCategory) && hits.contains(localShortCategory);
    final listed = <CatalogCategory>[
      CatalogCategory.all,
      if (hasBothKinds && !hasShortNamedChoice)
        CatalogCategory(localShortCategory, '短剧·内容', local: true),
      if (hasBothKinds)
        CatalogCategory(localLongCategory, '长剧·内容', local: true),
      for (final choice in choices) choice.category,
      // 固定题材词表只作兜底：源站自己上报过分类（条目带分类字段）时
      // 不再追加提示词分组，避免与源自带分组重复/冲突；完全无分类的
      // 源（如部分 maccms 采集站）才下发词表。
      if (known.isEmpty)
        for (final genre in genreCatalogFor(group))
          if (hits.contains('local:$genre'))
            CatalogCategory('local:$genre', genre, local: true),
    ];
    // 兜底去重：不同 ID 同名的分类在条上无法区分，只保留先出现的一项。
    final seen = <String>{};
    final result = [
      for (final category in listed)
        if (seen.add(category.name)) category,
    ];
    _categoriesCache[key] = (_libraryEpoch, _menusEpoch, result);
    return result;
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
    // 会话必须包含原始 category（含 `local:` 档）与 group.id：旧实现把
    // local 档的 category 段写成空串，导致「全部 / 长剧·内容 / 题材」
    // 共用同一份会话与 nextPage，切档后上拉分页拿到的是上一档的下一页。
    final key =
        '${group.id}|${group.sources.map((s) => s.id).join(',')}|'
        '$category|$query|'
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
      // 叠加本地缓存池时只收「匹配本组」的条目：旧实现对 local choice
      // 无条件叠加整份池，导致题材页比「全部」页还多出历史条目；完全
      // 不叠加又会让纯本地缓存的题材页空白。short/long 内容档不在
      // _choices 里（choice==null），走不到这段，天然与「全部」同池。
      if (choice != null) {
        for (final source in group.sources) {
          for (final item in _library[source.id]?.values ?? const <Drama>[]) {
            final matches = categoryName(item.category) == choice.category.name ||
                (choice.category.local &&
                    matchesLocalGenre(item, choice.category.name));
            if (matches) items.putIfAbsent(item.id, () => item);
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
      // 带排序时不能 early-return 基础缓存：Go 的 `cached` 只按
      // source|category 取键，读到的永远是「源站顺序」，且 UI 仍显示
      // 已选排序 → 切源/切档后「选了排序纹丝不动」。继续往下发带
      // sort 的 catalog 请求覆盖即可。
      if (sort.isEmpty && cached.fresh && cached.items.isNotEmpty) {
        return cached;
      }
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
        // 强制刷新失败（断网/源站超时）不能清掉已在显示的磁盘缓存：
        // 旧实现把 entry.items 清空，用户看到的就是「下拉刷新一下，
        // 缓存突然没有了」。错误仍通过 failures 以横幅/警告呈现。
        failures[source] = error.toString();
      }
    });
    final result = snapshot();
    // 强制刷新失败时即便仍保有缓存条目也要把错误抛给 UI（错误横幅）。
    // 条目本身不再清空：交给首页在 catch 里保留旧列表，避免「下拉刷新
    // 一下缓存就没了」。普通加载有缓存可显示时照旧静默降级。
    if (failures.isNotEmpty && (result.items.isEmpty || force)) {
      throw AppFailure(result.warning);
    }
    return result;
  }
}
