import 'dart:convert';
import 'dart:io';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const red = FixtureRepository.free;
  const other = FixtureRepository.vip;

  test('edition sources exclude the retired DSD source', () async {
    SharedPreferences.setMockInitialValues({'source': 'huangdou'});
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(appSlug, allSourcesEnabled ? 'zhenguojian' : 'hongguojian');
    // 青空源需登录默认关闭（2026-10-30），全源默认可见数减一。
    expect(store.sources.length, allSourcesEnabled ? 19 : 1);
    expect(
      SourceSite.values.any((source) => source.id == 'dsd'),
      isFalse,
    );
    expect(SourceSite.isAvailable('dsd'), isFalse);
    expect(SourceSite.isKnown('dsd'), isTrue);
    expect(store.allowsSource('dsd'), isFalse);
    expect(store.source, 'hongguo');
    store.dispose();
  });

  test(
    'edition filtering preserves favorites and history through backup restore',
    () async {
      final history = [
        for (final drama in [red, other])
          WatchEntry(
            drama: drama,
            episode: 1,
            position: 12,
            duration: 60,
            updatedAt: DateTime(2026, 9, 19),
          ).toJson(),
      ];
      SharedPreferences.setMockInitialValues({
        'source': 'huangdou',
        // 黄豆为受限源，默认关；此用例考察「开关开着时」的收藏与历史语义。
        'sourceSwitches': jsonEncode({'huangdou': true}),
        'favorites': jsonEncode([red.toJson(), other.toJson()]),
        'history': jsonEncode(history),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.favorites.length, allSourcesEnabled ? 2 : 1);
      expect(store.history.length, allSourcesEnabled ? 2 : 1);
      expect(store.isFavorite(other.id), allSourcesEnabled);
      expect(store.watched(other.id) != null, allSourcesEnabled);
      await store.toggleFavorite(red);
      final backup = await store.exportBackup();
      final library =
          (jsonDecode(backup)['libraries'] as Map)['default'] as Map;
      expect((library['favorites'] as List).map((row) => (row as Map)['id']), [
        other.id,
      ]);
      expect(library['history'], hasLength(2));
      await store.importBackup(backup);
      expect(store.preferences.getString('source'), 'huangdou');
      expect(store.history, hasLength(allSourcesEnabled ? 2 : 1));
      expect(
        store.favorites.map((drama) => drama.id),
        allSourcesEnabled ? [other.id] : isEmpty,
      );
      store.dispose();
    },
  );

  test(
    'a restored foreign-source profile keeps its identity and permissions',
    () async {
      SharedPreferences.setMockInitialValues({
        'profiles': jsonEncode([
          LocalProfile(
            id: 'default',
            name: '管理员',
            admin: true,
            salt: '0' * 32,
            pinHash: '1' * 64,
          ).toJson(),
          const LocalProfile(
            id: 'viewer',
            name: '已有用户',
            sources: ['huangdou'],
            download: false,
          ).toJson(),
        ]),
        'activeProfile': 'viewer',
        'profile.viewer.source': 'huangdou',
        // 黄豆为受限源，默认关；恢复用户后开关需保持开启才能保留其权限语义。
        'sourceSwitches': jsonEncode({'huangdou': true}),
      });
      final store = LocalStore(await SharedPreferences.getInstance());
      expect(store.profile.id, 'viewer');
      expect(store.profile.admin, isFalse);
      expect(store.profile.sources, ['huangdou']);
      expect(store.canDownload, isFalse);
      expect(store.source, allSourcesEnabled ? 'huangdou' : '');
      expect(store.allowsSource('hongguo'), isFalse);
      expect(store.allowsSource('huangdou'), allSourcesEnabled);
      store.dispose();
    },
  );

  test('restored DSD profile data follows edition availability', () async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        LocalProfile(
          id: 'default',
          name: '管理员',
          admin: true,
          salt: '0' * 32,
          pinHash: '1' * 64,
        ).toJson(),
        const LocalProfile(
          id: 'viewer',
          name: '帝果旧用户',
          sources: ['dsd'],
          download: false,
        ).toJson(),
      ]),
      'activeProfile': 'viewer',
      'profile.viewer.source': 'dsd',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    expect(store.configurationError, isNull);
    expect(store.profile.sources, ['dsd']);
    expect(store.sources, isEmpty);
    expect(store.source, '');
    expect(store.allowsSource('dsd'), isFalse);
    store.dispose();
  });

  test(
    'background requests reject unavailable sources before native I/O',
    () async {
      // 「当前版本不包含此站源」的判定要读核心 allSources 戳，即拒绝路径
      // 本身依赖核心可加载。无 duanju_core.dll 的环境（CI 无 Windows 构建
      // 产物）整条 native 路径不可用，本用例无从考察，直接跳过。
      if (Platform.isWindows) {
        final coreDll = File(
          '${File(Platform.resolvedExecutable).parent.path}\\duanju_core.dll',
        );
        if (!coreDll.existsSync()) {
          debugPrint('skip: 未找到 ${coreDll.path}，跳过 native 拒绝路径用例');
          return;
        }
      }
      final repository = NativeRepository(background: true);
      // 豆瓣是榜单专用源：只读链路（榜单/封面）按 SourceSite.authorized
      // 放行，不属于「当前版本不包含此站源」的拒绝集合。
      final denied = [
        ...SourceSite.allValues
            .where(
              (source) =>
                  !SourceSite.isAvailable(source.id) &&
                  !SourceSite.isRankingOnly(source.id),
            )
            .map((source) => source.id),
        'unknown',
      ];
      for (final source in denied) {
        final drama = Drama(id: '$source:123', source: source, title: '合成数据');
        final episode = Episode({'id': '1'}, 1);
        for (final request in [
          () => repository.catalog(source),
          () => repository.cached(source),
          () => repository.sourceStatus(source),
          () => repository.startSourceJob(source, 'update'),
          () => repository.cancelSourceJob(source),
          () => repository.detail(drama),
          () => repository.cover(drama),
          () => repository.resolve(drama, episode),
          () => repository.resolveOnline(drama, episode),
          () => repository.enqueueDownloads(DramaDetail(drama, [episode]), [
            episode,
          ]),
          () => repository.localPlayback(drama, episode),
        ]) {
          await expectLater(
            request(),
            throwsA(
              isA<AppFailure>().having(
                (error) => error.message,
                'message',
                '当前版本不包含此站源',
              ),
            ),
          );
        }
      }
    },
  );

  test('ranking-only source stays authorized for read-only requests', () {
    // 回归：「豆瓣榜单没图」。豆瓣不注册 provider、不进站源菜单，
    // isAvailable 恒 false；曾经 _authorize 无条件按 isAvailable 拒绝，
    // 导致榜单条目 cover 请求恒抛「当前版本不包含此站源」，榜单与首页
    // 轮播的豆瓣卡全部落到失败态（只显示重试图标）。
    expect(SourceSite.isAvailable('douban'), isFalse);
    expect(SourceSite.isRankingOnly('douban'), isTrue);
    expect(SourceSite.authorized('douban'), isTrue);
    // 其余非白名单源（含已下线的 DSD）仍按变体拦截。
    expect(SourceSite.authorized('dsd'), isFalse);
    expect(SourceSite.authorized('unknown'), isFalse);
    expect(SourceSite.authorized('hongguo'), isTrue);
  });
}
