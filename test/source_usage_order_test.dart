import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('orderByUsage 按次数降序，未使用与并列保持原顺序', () {
    final sites = [
      SourceSite.byId('hongguo')!,
      SourceSite.byId('dongpiandi')!,
      SourceSite.byId('huangdou')!,
    ];
    expect(
      SourceSite.orderByUsage(sites, {
        'huangdou': 5,
        'hongguo': 3,
      }).map((site) => site.id).toList(),
      ['huangdou', 'hongguo', 'dongpiandi'],
    );
    // 全未使用：保持定义顺序（不再把真果·鉴硬置顶）。
    expect(
      SourceSite.orderByUsage(sites, const {}).map((site) => site.id).toList(),
      ['hongguo', 'dongpiandi', 'huangdou'],
    );
    // 次数并列：原始下标决定先后，避免每次 build 抖动。
    expect(
      SourceSite.orderByUsage(sites, {
        'hongguo': 2,
        'huangdou': 2,
      }).map((site) => site.id).toList(),
      ['hongguo', 'huangdou', 'dongpiandi'],
    );
  });

  test('使用次数随切源累加并在新实例中读回', () async {
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await store.recordSourceUse('hongguo');
    await store.recordSourceUse('hongguo');
    await store.recordSourceUse('dongpiandi');
    expect(store.sourceUsage['hongguo'], 2);
    expect(store.sourceUsage['dongpiandi'], 1);

    final reopened = LocalStore(await SharedPreferences.getInstance());
    addTearDown(reopened.dispose);
    expect(reopened.sourceUsage['hongguo'], 2);
    expect(reopened.sourceUsage['dongpiandi'], 1);
  });
}
