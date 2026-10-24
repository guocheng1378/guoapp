import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 线路面板分组的数据前提：官方源平铺、第三方源折叠。
/// Go 侧 nativePlan 输出 routeOfficial，Dart 侧据此分组；缺失或长度不足时
/// 必须退化成「全部算第三方」（即不分组），不能把线路弄丢。
void main() {
  PlaybackPlan planWith(List<bool> official, {int index = 0}) => PlaybackPlan(
    url: 'https://example.test/v.mp4',
    session: 'session',
    routeIndex: index,
    routeCount: 4,
    routeLabels: const ['官方线甲', '新浪资源', '官方线乙', '豆瓣资源'],
    routeOfficial: official,
  );

  test('官方线/第三方线按标记分组且保持原顺序', () {
    final plan = planWith(const [true, false, true, false]);
    expect(plan.officialRoutes, [0, 2]);
    expect(plan.thirdPartyRoutes, [1, 3]);
    expect(plan.onOfficialRoute, isTrue);
  });

  test('当前在第三方线时 onOfficialRoute 为 false', () {
    final plan = planWith(const [true, false, true, false], index: 3);
    expect(plan.onOfficialRoute, isFalse);
  });

  test('没有官方标记时全部算第三方（面板退化为平铺）', () {
    final plan = planWith(const []);
    expect(plan.officialRoutes, isEmpty);
    expect(plan.thirdPartyRoutes, [0, 1, 2, 3]);
  });

  test('routeOfficial 比 routeCount 短时不越界', () {
    final plan = planWith(const [true]);
    expect(plan.officialRoutes, [0]);
    expect(plan.thirdPartyRoutes, [1, 2, 3]);
  });

  test('fromJson 解析 routeOfficial，缺失时为空表', () {
    final parsed = PlaybackPlan.fromJson(const {
      'url': 'https://example.test/v.mp4',
      'routeCount': 3,
      'routeLabels': ['官方线', '新浪资源', '豆瓣资源'],
      'routeOfficial': [true, false, false],
    });
    expect(parsed.officialRoutes, [0]);
    expect(parsed.thirdPartyRoutes, [1, 2]);

    final legacy = PlaybackPlan.fromJson(const {
      'url': 'https://example.test/v.mp4',
      'routeCount': 2,
    });
    expect(legacy.officialRoutes, isEmpty);
    expect(legacy.thirdPartyRoutes, [0, 1]);
  });
}
