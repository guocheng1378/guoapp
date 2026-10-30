import 'dart:convert';

import 'package:duanju_app/custom_sources.dart';
import 'package:duanju_app/local_snapshot.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _idPattern = RegExp(r'^custom-[0-9a-f]{12}$');

Future<LocalStore> _buildStore([
  Map<String, Object> initial = const {},
]) async {
  SharedPreferences.setMockInitialValues(initial);
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  return store;
}

void main() {
  setUp(() {
    // SourceSite._customSites 是进程级静态注册表，测试间先清空防串扰。
    SourceSite.registerCustomSites(const []);
  });

  group('CustomSourceSpec.validate', () {
    test('accepts a valid maccms source', () {
      expect(
        CustomSourceSpec.validate(
          name: '我的源',
          url: 'https://api.example.com/provide/vod/',
          category: 'video',
          typeId: '1',
        ),
        isNull,
      );
      // LocalStore.addCustomSource 才有分类缺省值；validate 侧必填。
      expect(
        CustomSourceSpec.validate(
          name: '我的源',
          url: 'http://api.example.com/at/xml.php',
          category: 'shortDrama',
        ),
        isNull,
      );
    });

    test('rejects blank or oversized names', () {
      expect(
        CustomSourceSpec.validate(
          name: '  ',
          url: 'https://a.com/vod',
          category: 'shortDrama',
        ),
        '请填写站源名称',
      );
      expect(
        CustomSourceSpec.validate(
          name: 'x' * 33,
          url: 'https://a.com/vod',
          category: 'shortDrama',
        ),
        '站源名称不能超过 32 个字符',
      );
    });

    test('rejects urls without http(s) scheme or host', () {
      const invalid = {
        '缺少协议': 'api.example.com/provide/vod/',
        '不支持 ftp': 'ftp://api.example.com/vod',
        '没有主机': 'https:///vod',
        '空地址': '',
      };
      for (final url in invalid.values) {
        expect(
          CustomSourceSpec.validate(
            name: '源',
            url: url,
            category: 'shortDrama',
          ),
          '请填写合法的 http(s) 站源地址',
          reason: 'url=[$url] 应被拒绝',
        );
      }
    });

    test('rejects unknown category', () {
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com/vod',
          category: 'movie',
        ),
        '请选择站源分类',
      );
    });

    test('rejects malformed type ids', () {
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com/vod',
          category: 'shortDrama',
          typeId: '动作 1',
        ),
        '分类 ID 仅支持字母数字下划线短横线（不超过 32 位）',
      );
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com/vod',
          category: 'shortDrama',
          typeId: 't' * 33,
        ),
        '分类 ID 仅支持字母数字下划线短横线（不超过 32 位）',
      );
      // 合法 typeId。
      expect(
        CustomSourceSpec.validate(
          name: '源',
          url: 'https://a.com/vod',
          category: 'shortDrama',
          typeId: 'type_20-1',
        ),
        isNull,
      );
    });
  });

  group('CustomSourceSpec identity', () {
    test('idFor derives a stable custom id from the url', () {
      final id = CustomSourceSpec.idFor('https://api.example.com/vod');
      expect(_idPattern.hasMatch(id), isTrue, reason: 'id=$id');
      expect(
        CustomSourceSpec.idFor('https://api.example.com/vod'),
        id,
        reason: '同一地址必须得到同一 ID（去重依据）',
      );
      expect(
        CustomSourceSpec.idFor('https://api.example.com/vod2'),
        isNot(id),
      );
    });
  });

  group('CustomSourceSpec json', () {
    test('toJson/toPayload round-trips through fromJson', () {
      const spec = CustomSourceSpec(
        id: 'custom-0123456789ab',
        name: '本地源',
        url: 'https://api.example.com/provide/vod/',
        category: 'video',
        typeId: '20',
      );
      final restored = CustomSourceSpec.fromJson(jsonDecode(jsonEncode(spec)));
      expect(restored, isNotNull);
      expect(restored!.id, spec.id);
      expect(restored.name, spec.name);
      expect(restored.url, spec.url);
      expect(restored.category, spec.category);
      expect(restored.typeId, spec.typeId);
      expect(restored.toPayload(), spec.toJson());
    });

    test('fromJson rejects malformed rows', () {
      expect(CustomSourceSpec.fromJson(null), isNull);
      expect(CustomSourceSpec.fromJson('custom-1'), isNull);
      expect(CustomSourceSpec.fromJson(<String, String>{}), isNull);
      expect(
        CustomSourceSpec.fromJson({'name': '源', 'url': 'https://a.com'}),
        isNull,
      );
      expect(
        CustomSourceSpec.fromJson({
          'id': 'official-x',
          'name': '源',
          'url': 'https://a.com',
        }),
        isNull,
        reason: '非 custom- 前缀的 ID 一律拒绝',
      );
      expect(
        CustomSourceSpec.fromJson({
          'id': 'custom-0123456789ab',
          'name': '   ',
          'url': 'https://a.com',
        }),
        isNull,
      );
    });

    test('fromJson falls back to defaults for bad optional fields', () {
      final spec = CustomSourceSpec.fromJson({
        'id': 'custom-0123456789ab',
        'name': '源',
        'url': 'https://a.com',
        'category': 42,
        'typeId': 20,
      });
      expect(spec, isNotNull);
      expect(spec!.category, 'shortDrama');
      expect(spec.typeId, '');
    });

    test('toSourceSite carries the category override', () {
      const adult = CustomSourceSpec(
        id: 'custom-0123456789ab',
        name: '成人源',
        url: 'https://a.com/vod',
        category: 'adult',
      );
      final site = adult.toSourceSite();
      expect(site.id, adult.id);
      expect(site.category, SourceCategory.adult);
      expect(site.isAdultSource, isTrue);
      expect(site.isShortDrama, isFalse);
    });
  });

  group('LocalStore custom sources', () {
    test('admin can add a source and it registers into SourceSite', () async {
      final store = await _buildStore();
      final before = SourceSite.values.length;
      await store.addCustomSource(
        name: '本地视频源',
        url: 'https://api.example.com/provide/vod/',
        category: 'video',
        typeId: '20',
      );

      expect(store.customSources, hasLength(1));
      final spec = store.customSources.single;
      expect(spec.name, '本地视频源');
      expect(spec.url, 'https://api.example.com/provide/vod/');
      expect(spec.category, 'video');
      expect(spec.typeId, '20');
      expect(_idPattern.hasMatch(spec.id), isTrue, reason: 'id=${spec.id}');

      // 站源菜单/管理页/授权等消费方通过注册表自动感知。
      expect(SourceSite.customSites, hasLength(1));
      expect(SourceSite.values.length, before + 1);
      expect(SourceSite.isAvailable(spec.id), isTrue);
      expect(SourceSite.isKnown(spec.id), isTrue);
      final site = SourceSite.byId(spec.id);
      expect(site, isNotNull);
      expect(site!.name, '本地视频源');
      expect(site.category, SourceCategory.video);
      // 非成人分类不受限。
      expect(SourceSite.isRestricted(spec.id), isFalse);
    });

    test('invalid spec is rejected without mutating state', () async {
      final store = await _buildStore();
      await expectLater(
        store.addCustomSource(
          name: '坏源',
          url: 'api.example.com/provide/vod/',
          category: 'video',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '请填写合法的 http(s) 站源地址',
          ),
        ),
      );
      expect(store.customSources, isEmpty);
      expect(SourceSite.customSites, isEmpty);
    });

    test('duplicate url is rejected after trimming', () async {
      final store = await _buildStore();
      await store.addCustomSource(
        name: '源一',
        url: 'https://api.example.com/provide/vod/',
      );
      await expectLater(
        store.addCustomSource(
          name: '源二',
          url: '  https://api.example.com/provide/vod/  ',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '该站源地址已添加',
          ),
        ),
      );
      expect(store.customSources, hasLength(1));
    });

    test('enforces the 16-source cap', () async {
      final store = await _buildStore();
      for (var i = 0; i < CustomSourceSpec.maxSources; i++) {
        await store.addCustomSource(
          name: '源$i',
          url: 'https://src$i.example.com/provide/vod/',
        );
      }
      expect(store.customSources, hasLength(CustomSourceSpec.maxSources));
      await expectLater(
        store.addCustomSource(
          name: '超出',
          url: 'https://overflow.example.com/provide/vod/',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '自定义站源最多 ${CustomSourceSpec.maxSources} 个',
          ),
        ),
      );
      expect(store.customSources, hasLength(CustomSourceSpec.maxSources));
    });

    test('remove is idempotent and unregisters the site', () async {
      final store = await _buildStore();
      await store.addCustomSource(
        name: '源一',
        url: 'https://api.example.com/provide/vod/',
      );
      final id = store.customSources.single.id;

      await store.removeCustomSource(id);
      expect(store.customSources, isEmpty);
      expect(SourceSite.customSites, isEmpty);
      expect(SourceSite.isAvailable(id), isFalse);
      expect(SourceSite.byId(id), isNull);

      // 重复删除同一 ID 静默成功。
      await store.removeCustomSource(id);
      expect(store.customSources, isEmpty);
    });

    test('adult category source becomes restricted', () async {
      final store = await _buildStore();
      await store.addCustomSource(
        name: '成人源',
        url: 'https://adult.example.com/provide/vod/',
        category: 'adult',
      );
      await store.addCustomSource(
        name: '短剧源',
        url: 'https://short.example.com/provide/vod/',
      );

      final restricted = store.customSources.singleWhere(
        (source) => source.category == 'adult',
      );
      final normal = store.customSources.singleWhere(
        (source) => source.category == 'shortDrama',
      );
      expect(SourceSite.isRestricted(restricted.id), isTrue);
      expect(SourceSite.isRestricted(normal.id), isFalse);
      expect(SourceSite.byId(restricted.id)!.isAdultSource, isTrue);
    });

    test('non-admin cannot add or remove custom sources', () async {
      final store = await _buildStore();
      await store.saveProfile(
        id: 'default',
        name: '管理员',
        sources: ['hongguo'],
        download: true,
        pin: '123456',
      );
      await store.saveProfile(
        name: 'child',
        sources: ['hongguo'],
        download: true,
      );
      final child = store.profiles.firstWhere((profile) => !profile.admin);
      await store.switchProfile(child.id);

      await expectLater(
        store.addCustomSource(
          name: '越权源',
          url: 'https://api.example.com/provide/vod/',
        ),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            '仅管理员可以修改此设置',
          ),
        ),
      );
      await expectLater(
        store.removeCustomSource('custom-0123456789ab'),
        throwsA(isA<StateError>()),
      );
      expect(store.customSources, isEmpty);
    });

    test('custom sources survive a restart', () async {
      final prefs = await _preparePrefs();
      final store = LocalStore(await SharedPreferences.getInstance());
      addTearDown(store.dispose);
      await store.addCustomSource(
        name: '源一',
        url: 'https://one.example.com/provide/vod/',
        category: 'video',
        typeId: '1',
      );
      await store.addCustomSource(
        name: '源二',
        url: 'https://two.example.com/provide/vod/',
      );
      // 快照以单键 blob 落盘（localSnapshot.v1），customSources 在其内。
      final raw = prefs.getString(LocalSnapshot.storageKey);
      expect(raw, isNotNull);

      // 模拟重启：把落盘快照整体作为初始值重建 LocalStore。
      final restored = await _buildStore({LocalSnapshot.storageKey: raw!});
      expect(restored.customSources, hasLength(2));
      expect(restored.customSources[0].name, '源一');
      expect(restored.customSources[0].category, 'video');
      expect(restored.customSources[1].name, '源二');
      // 注册表在启动加载时同步恢复。
      expect(SourceSite.customSites, hasLength(2));
      expect(
        SourceSite.isAvailable(restored.customSources[0].id),
        isTrue,
      );
      // 损坏条目被防御性跳过而不是让启动失败。
      final broken = await _buildStore({
        'customSources': jsonEncode([
          store.customSources[0].toJson(),
          {'id': 'bad'},
          'not-a-map',
        ]),
      });
      expect(broken.customSources, hasLength(1));
    });
  });
}

Future<SharedPreferences> _preparePrefs() async {
  SharedPreferences.setMockInitialValues(<String, Object>{});
  return SharedPreferences.getInstance();
}
