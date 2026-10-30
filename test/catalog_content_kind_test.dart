import 'package:duanju_app/catalog_browser.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('dramaIsLongDrama 不看时长，只认显式定性/短剧信号/站源属性', () {
    test('时长不再参与判定：时长很长的条目仍按信号链走', () {
      // 2712 秒（45 分钟）但分类含「短剧」→ 短剧。
      // （旧口径「有时长信时长」会判成长剧，时长一漂移结论就翻。）
      expect(
        dramaIsLongDrama(
          const Drama(
            id: 'a',
            source: 'yingshigongchang',
            title: '甲',
            duration: 2712,
            category: '短剧',
          ),
          null,
        ),
        isFalse,
      );
      // 时长 120 秒但无任何短剧信号、站源是视频类 → 长剧。
      expect(
        dramaIsLongDrama(
          const Drama(
            id: 'b',
            source: 'yingshigongchang',
            title: '乙',
            duration: 120,
          ),
          SourceSite.byId('yingshigongchang'),
        ),
        isTrue,
      );
    });

    test('显式定性优先级最高（覆盖分类与站源信号）', () {
      expect(
        dramaIsLongDrama(
          const Drama(
            id: 'a',
            source: 'hongguo',
            title: '甲',
            contentKind: 'long',
          ),
          SourceSite.byId('hongguo'),
        ),
        isTrue,
        reason: 'contentKind=long 覆盖红果的短剧源属性',
      );
      expect(
        dramaIsLongDrama(
          const Drama(
            id: 'b',
            source: 'yingshigongchang',
            title: '乙',
            contentKind: 'short',
          ),
          SourceSite.byId('yingshigongchang'),
        ),
        isFalse,
        reason: 'contentKind=short 覆盖视频类源',
      );
    });

    test('条目短剧信号兜底（真果·鉴 kind / maccms 短剧频道）', () {
      expect(
        dramaIsLongDrama(
          const Drama(id: 'a', source: 'dongpiandi', title: '甲', category: '短剧'),
          null,
        ),
        isFalse,
      );
      expect(
        dramaIsLongDrama(
          const Drama(
            id: 'b',
            source: 'dongpiandi',
            title: '乙',
            tags: ['逆袭', '短剧'],
          ),
          null,
        ),
        isFalse,
      );
    });

    test('仍无信号时按站源注册分类兜底，最后默认长剧', () {
      expect(
        dramaIsLongDrama(
          const Drama(id: 'a', source: 'hongguo', title: '甲'),
          SourceSite.byId('hongguo'),
        ),
        isFalse,
      );
      // 视频类源/未知源默认长剧：以电视剧/电影为主，宁判长不冒充短剧。
      expect(
        dramaIsLongDrama(
          const Drama(id: 'b', source: 'yingshigongchang', title: '乙'),
          null,
        ),
        isTrue,
      );
    });
  });

  group('分类条本地分组按条目池命中过滤（点开必有内容）', () {
    final group = SourceGroup('hongguo', '红果', [SourceSite.hongguo]);

    // 喂池走公开路径：cached() 返回缓存页 → loadCategories(cacheOnly)
    // 只读池不发网 → _remember 进条目池 → categories() 按命中过滤。
    Future<List<CatalogCategory>> categoriesFor(List<Drama> items) async {
      final repository = FixtureRepository()
        ..cachedPages['hongguo'] = CatalogPage(items);
      final browser = CatalogBrowser(repository);
      await browser.loadCategories(group, cacheOnly: true);
      return browser.categories(group);
    }

    test('空条目池只保留「全部」，长短剧档与题材词组都不下发', () async {
      final categories = await categoriesFor(const []);
      expect(categories, hasLength(1));
      expect(categories.single.id, CatalogCategory.all.id);
    });

    test('池中长剧短剧齐备时两档都显，id 走 local:kind: 前缀', () async {
      final categories = await categoriesFor(const [
        Drama(id: 'l1', source: 'hongguo', title: '长剧样本', contentKind: 'long'),
        Drama(id: 's1', source: 'hongguo', title: '短剧样本'),
      ]);
      expect(categories.first.id, CatalogCategory.all.id);
      // 池派生分类组（如「未分类」）天然有内容不受此限；这里断言的是
      // 固定题材词表无命中不下发。
      expect(
        categories
            .map((c) => c.id)
            .where(
              (id) =>
                  id.startsWith('local:') &&
                  !id.startsWith('local:kind:') &&
                  id != 'local:未分类',
            ),
        isEmpty,
        reason: '题材词无命中不下发',
      );
      expect(
        categories.map((c) => c.name),
        containsAll(['长剧·内容', '短剧·内容']),
      );
      expect(
        categories.map((c) => c.id),
        containsAll([localLongCategory, localShortCategory]),
      );
    });

    test('只有长剧内容时隐藏「短剧」档', () async {
      final categories = await categoriesFor(const [
        Drama(id: 'l1', source: 'hongguo', title: '长剧样本', contentKind: 'long'),
        Drama(id: 'l2', source: 'hongguo', title: '另一部长剧', contentKind: 'long'),
      ]);
      expect(categories.map((c) => c.name), contains('长剧·内容'));
      expect(categories.map((c) => c.name), isNot(contains('短剧·内容')));
    });

    test('题材词组按命中过滤：无命中整组消失、标题命中才出现', () async {
      final miss = await categoriesFor(const [
        Drama(id: 'a', source: 'hongguo', title: '长剧样本', contentKind: 'long'),
      ]);
      expect(
        miss
            .map((c) => c.id)
            .where(
              (id) =>
                  id.startsWith('local:') &&
                  !id.startsWith('local:kind:') &&
                  id != 'local:未分类',
            ),
        isEmpty,
        reason: '词表无命中时不应有任何题材组',
      );

      final hit = await categoriesFor(const [
        Drama(
          id: 'a',
          source: 'hongguo',
          title: '总裁的贴身司机',
          contentKind: 'long',
        ),
      ]);
      expect(hit.map((c) => c.id), contains('local:总裁'));
    });

    test('条目池更新后本地分组自然出现（命中缓存按 epoch 失效重算）', () async {
      final repository = FixtureRepository();
      final browser = CatalogBrowser(repository);
      const long = Drama(
        id: 'l1',
        source: 'hongguo',
        title: '长剧样本',
        contentKind: 'long',
      );
      const short = Drama(id: 's1', source: 'hongguo', title: '短剧样本');
      repository.cachedPages['hongguo'] = CatalogPage(const [long]);
      await browser.loadCategories(group, cacheOnly: true);
      expect(
        browser.categories(group).map((c) => c.name),
        isNot(contains('短剧·内容')),
      );

      // 同一 browser：缓存页补进短剧 → 再次加载池 → 「短剧」组出现。
      repository.cachedPages['hongguo'] = CatalogPage(const [long, short]);
      await browser.loadCategories(group, cacheOnly: true);
      expect(
        browser.categories(group).map((c) => c.name),
        containsAll(['长剧·内容', '短剧·内容']),
      );
    });

    // 分类条上同一名字只能出现一次：短剧源自己就上报「短剧」，与本地定性档撞名。
    test('源站已上报「短剧」时与本地定性档并存且名字唯一', () async {
      final categories = await categoriesFor(const [
        Drama(id: 's1', source: 'hongguo', title: '短剧样本', category: '短剧'),
        Drama(id: 'l1', source: 'hongguo', title: '长剧样本', contentKind: 'long'),
      ]);
      final names = categories.map((c) => c.name).toList();
      expect(
        names.toSet().length,
        names.length,
        reason: '分类条名字必须唯一，实际 $names',
      );
      expect(names, contains('短剧'), reason: '源站上报的「短剧」分类保留原名');
      expect(
        names,
        contains('短剧·内容'),
        reason: '本地定性档恒带后缀，实际 $names',
      );
      // ID 不变：home_screen 的 local:kind: 过滤分支与选中态都按 id 走。
      expect(categories.map((c) => c.id), contains(localShortCategory));
      expect(categories.map((c) => c.id), contains(localLongCategory));
    });

    // 恒定命名：名字不随条目池/菜单到达顺序变化，避免分类条先显「短剧」
    // 再跳成「短剧·内容」。同一分组重复读也必须拿到同一份结果（缓存）。
    test('本地档名恒定，重复读取不跳字', () async {
      final repository = FixtureRepository()
        ..cachedPages['hongguo'] = CatalogPage(const [
          Drama(id: 's1', source: 'hongguo', title: '短剧样本'),
        ]);
      final browser = CatalogBrowser(repository);
      await browser.loadCategories(group, cacheOnly: true);
      final first = browser.categories(group).map((c) => c.name).toList();
      final second = browser.categories(group).map((c) => c.name).toList();
      expect(first, contains('短剧·内容'));
      expect(second, first, reason: '分类条结果必须可重复（缓存命中不重算）');
      expect(identical(browser.categories(group), browser.categories(group)), isTrue,
          reason: '命中缓存应返回同一实例，避免 build 期重复分配');
    });

    // 源站分类菜单异步到达后，分类条必须失效重算（menusEpoch）。
    test('源站菜单到达后分类条自动补上源站分类', () async {
      final repository = _MenusRepository()
        ..cachedPages['hongguo'] = CatalogPage(const [
          Drama(id: 's1', source: 'hongguo', title: '短剧样本'),
        ]);
      final browser = CatalogBrowser(repository);
      await browser.loadCategories(group, cacheOnly: true);
      final before = browser.categories(group).map((c) => c.name).toList();
      await browser.loadCategories(group);
      final after = browser.categories(group).map((c) => c.name).toList();
      expect(before, isNot(contains('短剧')));
      expect(
        after,
        contains('短剧'),
        reason: '菜单到达后应多出源站「短剧」分类，实际 before=$before after=$after',
      );
      expect(
        after.toSet().length,
        after.length,
        reason: '源站「短剧」与本地「短剧·内容」并存但名字唯一，实际 $after',
      );
    });
  });

  group('Drama.duration 解析与详情回填', () {
    test('fromJson 解析、merge 时详情真值优先', () {
      final drama = Drama.fromJson(const {
        'id': 'a',
        'source': 'hongguo',
        'title': '甲',
        'duration': 2712,
      });
      expect(drama.duration, 2712);
      // 详情回填了真实时长（90 秒）→ 覆盖。
      final healed = drama.merge(
        Drama.fromJson(const {'id': 'a', 'source': 'hongguo', 'title': '甲', 'duration': 90}),
      );
      expect(healed.duration, 90);
      // 详情未回填时长（0）→ 保留原值。
      expect(
        drama.merge(Drama.fromJson(const {'id': 'a', 'source': 'hongguo', 'title': '甲'})).duration,
        2712,
      );
    });

    test('显式定性 contentKind 解析与 merge 保留', () {
      final drama = Drama.fromJson(const {
        'id': 'a',
        'source': 'hongguo',
        'title': '甲',
        'contentKind': 'long',
      });
      expect(drama.contentKind, 'long');
      // 详情未带定性 → 保留原值。
      expect(
        drama.merge(Drama.fromJson(const {'id': 'a', 'source': 'hongguo', 'title': '甲'})).contentKind,
        'long',
      );
      // 详情带回定性 → 覆盖。
      expect(
        drama
            .merge(
              Drama.fromJson(const {
                'id': 'a',
                'source': 'hongguo',
                'title': '甲',
                'contentKind': 'short',
              }),
            )
            .contentKind,
        'short',
      );
    });
  });
}

/// 分类菜单可见的仓库：默认 FixtureRepository 不返回源站分类，
/// 这里补一条与本地档撞名的「短剧」，用于验证 menusEpoch 失效与名字唯一。
class _MenusRepository extends FixtureRepository {
  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [
    CatalogCategory('', '全部'),
    CatalogCategory('27', '短剧'),
  ];
}
