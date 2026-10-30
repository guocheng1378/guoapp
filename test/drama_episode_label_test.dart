import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/models.dart';

Drama _drama(int episodes, String releaseStatus) => Drama.fromJson({
  'id': 'dongpiandi:demo',
  'source': 'dongpiandi',
  'title': '故纵',
  'episodes': episodes,
  'releaseStatus': releaseStatus,
});

void main() {
  test('连载中的集数写成「更新至 N 集」', () {
    // 真果·鉴连载剧：内核给的是已更新集数（站点原文「更新至74集」），
    // 写「共 74 集」会让人误以为全集已放出。
    expect(_drama(74, 'ongoing').episodeLabel, '更新至 74 集');
  });

  test('已完结的集数写成「共 N 集」', () {
    expect(_drama(80, 'finished').episodeLabel, '共 80 集');
    expect(_drama(20, 'completed').episodeLabel, '共 20 集');
  });

  test('状态未知沿用「共 N 集」', () {
    expect(_drama(74, 'unknown').episodeLabel, '共 74 集');
    expect(_drama(74, '').episodeLabel, '共 74 集');
  });

  test('没有集数时不产生文案', () {
    expect(_drama(0, 'ongoing').episodeLabel, '');
  });

  test('连载状态文案', () {
    expect(_drama(74, 'ongoing').releaseLabel, '连载中');
    expect(_drama(80, 'finished').releaseLabel, '已完结');
  });
}
