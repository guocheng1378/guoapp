import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bulk source switches open every permitted source in one commit',
      () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    final ids = [for (final site in SourceSite.values) site.id];
    // 受限站源（黄果类）与需登录站源（青空，2026-10-30）默认关闭，
    // 因此初始可见数量少于全部站源。
    expect(store.sources.length, allSourcesEnabled ? 19 : 1);

    // 青空：站点加账号墙（登录+滑块验证码才能播放，2026-10-30 真网取证），
    // 默认关闭；不属受限名单，无需管理员密码即可手动开启。
    if (allSourcesEnabled) {
      expect(store.sourceEnabled('sorani'), isFalse);
      expect(store.allowsSource('sorani'), isFalse);
      await store.setSourceEnabled('sorani', true);
      expect(store.sourceEnabled('sorani'), isTrue);
      expect(store.allowsSource('sorani'), isTrue);
      await store.setSourceEnabled('sorani', false);
    }

    await store.setSourceSwitches({
      for (final id in ids) id: true,
      'ghost-source': true,
    });
    expect(store.sources.length, ids.length);
    expect(store.sourceEnabled('hongguo'), isTrue);
    // 当前版本不存在的站源不会写入开关表。
    expect(
      store.preferences.getString('sourceSwitches'),
      isNot(contains('ghost-source')),
    );

    await store.setSourceSwitches({for (final id in ids) id: false});
    expect(store.sources, isEmpty);
    expect(store.sourceEnabled('hongguo'), isFalse);
  });
}
