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
    // 受限站源（黄果类）默认关闭，因此初始可见数量少于全部站源。
    expect(store.sources.length, allSourcesEnabled ? 20 : 1);

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
