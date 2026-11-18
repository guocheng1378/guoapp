import 'package:duanju_app/js_module_screen.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  testWidgets('站源模块页提供已装与在线仓库两个标签', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: JsModuleScreen(repository: FixtureRepository())),
    );
    await tester.pumpAndSettle();
    expect(find.text('已装模块'), findsOneWidget);
    expect(find.text('在线仓库'), findsOneWidget);
    expect(find.byKey(const ValueKey('js-module-install')), findsOneWidget);
  });

  testWidgets('在线仓库在核心不支持模块时给出提示', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: JsModuleScreen(repository: FixtureRepository())),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('在线仓库'));
    await tester.pumpAndSettle();
    expect(find.textContaining('当前核心不支持站源模块'), findsOneWidget);
  });

  testWidgets('传入 store 时提供内置站源入口', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = LocalStore(preferences);
    await tester.pumpWidget(
      MaterialApp(
        home: JsModuleScreen(repository: FixtureRepository(), store: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('js-module-builtin-sources')), findsOneWidget);
  });

  group('站源模块能力中文化', () {
    test('核心英文能力映射为中文，未知能力原样保留', () {
      expect(moduleCapabilityLabel('catalog'), '目录浏览');
      expect(moduleCapabilityLabel('detail'), '详情解析');
      expect(moduleCapabilityLabel('search'), '搜索');
      expect(moduleCapabilityLabel('danmaku'), '弹幕');
      expect(moduleCapabilityLabel('rankings'), '榜单');
      expect(moduleCapabilityLabel('mediaauth'), '播放凭证');
      // 大小写与空白归一。
      expect(moduleCapabilityLabel('  SEARCH '), '搜索');
      // 未识别的能力不丢失信息。
      expect(moduleCapabilityLabel('futureFeature'), 'futureFeature');
    });
  });

  group('站源模块按原分类分组 + 隐藏限制内容', () {
    Map<String, dynamic> module(
      String id, {
      String category = 'shortDrama',
      bool adult = false,
    }) => <String, dynamic>{
      'id': id,
      'name': id,
      'category': category,
      'adult': adult,
      'capabilities': ['catalog', 'detail', 'search'],
    };

    test('模块按短剧/视频/黄果/成人归类，与官方文档口径一致', () {
      expect(moduleClassKey(module('fengche', category: 'video')), 'video');
      expect(moduleClassKey(module('my-short')), 'shortDrama');
      // 黄果系成员按 id 归黄果类，即使 manifest category=shortDrama。
      expect(moduleClassKey(module('huangdou')), 'huangguo');
      // 成人源按 id 或 adult 标记归成人类。
      expect(moduleClassKey(module('zy155', category: 'video', adult: true)),
          'adult');
      expect(moduleClassKey(module('custom-adult', adult: true)), 'adult');
    });

    test('未解锁时黄果类/成人类整组隐藏，解锁后出现', () {
      final modules = [
        module('my-short'),
        module('fengche', category: 'video'),
        module('huangdou'),
        module('zy155', adult: true),
      ];
      final locked = groupInstalledModules(modules, unlocked: false);
      expect(locked.map((g) => g.key), ['shortDrama', 'video']);
      final unlocked = groupInstalledModules(modules, unlocked: true);
      expect(unlocked.map((g) => g.key),
          ['shortDrama', 'video', 'huangguo', 'adult']);
      // 在线仓库同样过滤。
      expect(visibleStoreModules(modules, unlocked: false).length, 2);
      expect(visibleStoreModules(modules, unlocked: true).length, 4);
    });

    test('空组不出现，分类顺序恒为短剧→视频→黄果→成人', () {
      final groups = groupInstalledModules([
        module('zy155', adult: true),
        module('my-short'),
      ], unlocked: true);
      expect(groups.map((g) => g.key), ['shortDrama', 'adult']);
    });
  });

  // 模块装好后必须按 manifest 分类进 SourceSite，首页分组才认得出它；
  // 早前核心没下发 category，导致所有模块都被当成短剧类。
  group('模块登记进 SourceSite 的分类', () {
    tearDown(() => SourceSite.registerModuleSites(const []));

    test('manifest category 与 adult 标记都参与归类', () {
      expect(
        sourceModuleCategoryFor(<String, dynamic>{
          'id': 'modvideo',
          'category': 'video',
        }),
        SourceCategory.video,
      );
      expect(
        sourceModuleCategoryFor(<String, dynamic>{'id': 'modshort'}),
        SourceCategory.shortDrama,
      );
      // manifest 漏写 category 但 adult=true：仍判成人，不能混进短剧类。
      expect(
        sourceModuleCategoryFor(<String, dynamic>{
          'id': 'modadult',
          'adult': true,
        }),
        SourceCategory.adult,
      );
      // 上游的 adult 是「受限」语义：黄果系也标 true，但按 id 归黄果类，
      // 不能被误判成成人内容。
      expect(
        sourceModuleCategoryFor(<String, dynamic>{
          'id': 'huangju',
          'category': 'shortDrama',
          'adult': true,
        }),
        SourceCategory.shortDrama,
      );
    });

    test('登记的模块出现在站源表里，分类与受限口径正确', () {
      applySourceModules([
        <String, dynamic>{'id': 'modvideo', 'name': '视频模块', 'category': 'video'},
        <String, dynamic>{'id': 'modadult', 'name': '成人模块', 'adult': true},
      ]);
      expect(SourceSite.isAvailable('modvideo'), isTrue);
      expect(SourceSite.byId('modvideo')?.category, SourceCategory.video);
      expect(SourceSite.isAvailable('modadult'), isTrue);
      expect(SourceSite.byId('modadult')?.category, SourceCategory.adult);
      // 成人模块默认关闭（需「关于」解锁后才显示）。
      expect(SourceSite.isRestricted('modadult'), isTrue);
      expect(SourceSite.isRestricted('modvideo'), isFalse);
    });
  });
}
