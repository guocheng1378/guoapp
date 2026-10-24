import 'package:duanju_app/catalog_browser.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures.dart';

void main() {
  group('dramaIsLongDrama 全源统一时长规则（单集 >10 分钟=长剧）', () {
    test('有单集时长数据时按时长判定，600 秒为短剧上界', () {
      expect(dramaIsLongDrama(const Drama(id: 'a', source: 'hongguo', title: '甲', duration: 2712), null), isTrue);
      expect(dramaIsLongDrama(const Drama(id: 'b', source: 'hongguo', title: '乙', duration: 601), null), isTrue);
      expect(dramaIsLongDrama(const Drama(id: 'c', source: 'hongguo', title: '丙', duration: 600), null), isFalse);
      expect(dramaIsLongDrama(const Drama(id: 'd', source: 'hongguo', title: '丁', duration: 120), null), isFalse);
    });

    test('时长未知时按条目「短剧」信号兜底（真果·鉴短剧 kind / maccms 短剧频道）', () {
      expect(dramaIsLongDrama(const Drama(id: 'a', source: 'dongpiandi', title: '甲', category: '短剧'), null), isFalse);
      expect(
        dramaIsLongDrama(const Drama(id: 'b', source: 'dongpiandi', title: '乙', tags: ['逆袭', '短剧']), null),
        isFalse,
      );
    });

    test('仍无信号时按站源注册分类兜底，最后默认长剧', () {
      expect(dramaIsLongDrama(const Drama(id: 'a', source: 'hongguo', title: '甲'), SourceSite.byId('hongguo')), isFalse);
      // 视频类源/未知源默认长剧：以电视剧/电影为主，宁判长不冒充短剧。
      expect(dramaIsLongDrama(const Drama(id: 'b', source: 'yingshigongchang', title: '乙'), null), isTrue);
    });

    test('有时长数据时信时长，短剧标签不再覆盖', () {
      expect(
        dramaIsLongDrama(
          const Drama(id: 'a', source: 'hongguo', title: '甲', duration: 2712, category: '短剧'),
          SourceSite.byId('hongguo'),
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
        Drama(id: 'l1', source: 'hongguo', title: '长剧样本', duration: 1200),
        Drama(id: 's1', source: 'hongguo', title: '短剧样本', duration: 120),
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
      expect(categories.map((c) => c.name), containsAll(['长剧', '短剧']));
      expect(
        categories.map((c) => c.id),
        containsAll([localLongCategory, localShortCategory]),
      );
    });

    test('只有长剧内容时隐藏「短剧」档', () async {
      final categories = await categoriesFor(const [
        Drama(id: 'l1', source: 'hongguo', title: '长剧样本', duration: 2712),
        Drama(id: 'l2', source: 'hongguo', title: '另一部长剧', duration: 900),
      ]);
      expect(categories.map((c) => c.name), contains('长剧'));
      expect(categories.map((c) => c.name), isNot(contains('短剧')));
    });

    test('题材词组按命中过滤：无命中整组消失、标题命中才出现', () async {
      final miss = await categoriesFor(const [
        Drama(id: 'a', source: 'hongguo', title: '长剧样本', duration: 1200),
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
        Drama(id: 'a', source: 'hongguo', title: '总裁的贴身司机', duration: 1200),
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
        duration: 1200,
      );
      const short = Drama(
        id: 's1',
        source: 'hongguo',
        title: '短剧样本',
        duration: 120,
      );
      repository.cachedPages['hongguo'] = CatalogPage(const [long]);
      await browser.loadCategories(group, cacheOnly: true);
      expect(
        browser.categories(group).map((c) => c.name),
        isNot(contains('短剧')),
      );

      // 同一 browser：缓存页补进短剧 → 再次加载池 → 「短剧」组出现。
      repository.cachedPages['hongguo'] = CatalogPage(const [long, short]);
      await browser.loadCategories(group, cacheOnly: true);
      expect(
        browser.categories(group).map((c) => c.name),
        containsAll(['长剧', '短剧']),
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
  });
}
