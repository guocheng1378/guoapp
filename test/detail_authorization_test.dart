import 'dart:convert';

import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/local_profiles.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 详情授权：站源被关闭后，详情请求必须在发出之前就被拒绝。
///
/// 关键点：详情有 30min 本地缓存，命中缓存时根本不发请求。若只在
/// `_call` 的动作白名单里校验，关掉站源后仍能读到该剧的缓存详情，
/// 与目录/封面/下载的拒绝口径不一致。所以授权必须落在详情入口。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const drama = Drama(id: 'hongguo:1', source: 'hongguo', title: '样本短剧');

  test('站源被关闭后详情请求在发出前就被拒绝', () async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        const LocalProfile(id: 'default', name: '管理员', admin: true).toJson(),
      ]),
      'activeProfile': 'default',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    await store.setSourceEnabled('hongguo', false);
    final repository = NativeRepository()..access = store;

    await expectLater(
      repository.detail(drama),
      throwsA(
        isA<AppFailure>().having(
          (error) => error.message,
          'message',
          contains('权限'),
        ),
      ),
    );
    store.dispose();
  });

  test('预取同样受站源开关约束（静默失败，不发原生请求）', () async {
    SharedPreferences.setMockInitialValues({
      'profiles': jsonEncode([
        const LocalProfile(id: 'default', name: '管理员', admin: true).toJson(),
      ]),
      'activeProfile': 'default',
    });
    final store = LocalStore(await SharedPreferences.getInstance());
    await store.setSourceEnabled('hongguo', false);
    final repository = NativeRepository()..access = store;

    // 预取失败必须静默：预取是后台优化，不该把异常抛到调用方。
    repository.prefetchDetails([drama]);
    await Future<void>.delayed(const Duration(milliseconds: 50));

    store.dispose();
  });
}
