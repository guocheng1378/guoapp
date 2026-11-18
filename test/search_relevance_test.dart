import 'package:duanju_app/home_screen.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('maccms 视频源搜索结果必须本地相关度复核', () {
    final site = SourceSite.byId('yingshigongchang');
    expect(site, isNotNull);
    final unrelated = Drama(
      id: 'yingshigongchang:1',
      source: 'yingshigongchang',
      title: '完全无关的电影',
      description: '简介里也没有关键词',
    );
    final related = Drama(
      id: 'yingshigongchang:2',
      source: 'yingshigongchang',
      title: '庆余年 第1集',
    );
    // 服务端 wd 模糊结果不可信：不含关键词的条目必须被砍掉。
    expect(acceptsSearchHit(unrelated, '庆余年', site), isFalse);
    expect(acceptsSearchHit(related, '庆余年', site), isTrue);
    // 空 query 是浏览态，全部放行。
    expect(acceptsSearchHit(unrelated, '', site), isTrue);
  });

  test('精准搜索源信任服务端，本地匹配源仍复核', () {
    // 红果走精准搜索：标题用了别名、不含字面关键词，也信任服务端结果。
    final alias = Drama(id: 'hongguo:1', source: 'hongguo', title: '别名剧');
    expect(acceptsSearchHit(alias, '庆余年', SourceSite.hongguo), isTrue);

    // 真果·鉴/韩小圈都不标记在线搜索（走本地匹配），无关条目被复核砍掉；
    // 这是既有行为，新判定只对 maccms 视频源收紧，不改变它们。
    for (final id in ['dongpiandi', 'hanxiaoquan']) {
      final unrelated = Drama(
        id: '$id:1',
        source: id,
        title: '无关剧',
      );
      expect(
        acceptsSearchHit(unrelated, '庆余年', SourceSite.byId(id)),
        isFalse,
        reason: '$id 走本地匹配，应复核',
      );
    }
  });
}
