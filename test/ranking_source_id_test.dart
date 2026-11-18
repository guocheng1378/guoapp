import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/ranking_models.dart';

void main() {
  test('榜单 id 反解站源：黄果 AI 的 huangguo-* 前缀必须映射到 huangguoai', () {
    // 回归：黄果 AI 榜单 id 前缀是 huangguo-*，而站源 id 是 huangguoai。
    // 若这里返回空串，core_bridge 的 rankings 授权会抛「当前版本不包含此站源」，
    // 三个黄果 AI 榜全部点不开。
    expect(RankingBoard.sourceForID('huangguo-hot'), 'huangguoai');
    expect(RankingBoard.sourceForID('huangguo-recommend'), 'huangguoai');
    expect(RankingBoard.sourceForID('huangguo-potential'), 'huangguoai');
  });

  test('榜单 id 反解站源：既有前缀与未知前缀行为不变', () {
    expect(RankingBoard.sourceForID('hongguo-hot'), 'hongguo');
    expect(RankingBoard.sourceForID('dongpiandi-hot'), 'dongpiandi');
    expect(RankingBoard.sourceForID('yingshigongchang-new'), 'yingshigongchang');
    expect(RankingBoard.sourceForID('yunzhui-daily-drama'), 'yunzhui');
    expect(RankingBoard.sourceForID('douban-top250'), 'douban');
    expect(RankingBoard.sourceForID('nosuch-board'), '');
  });
}
