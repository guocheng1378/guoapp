import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('视频类分组恒以真果·鉴打头', () {
    final video = SourceSite.allValues.where(
      (site) => site.isVideoSource && !site.inHuangguoCategory,
    );
    final ordered = SourceSite.orderVideoGroup(video);
    expect(ordered, isNotEmpty);
    expect(ordered.first.id, 'dongpiandi');
    // 韩小圈可以出现在视频类里，但不得占首位。
    final hanxiaoquan = ordered.indexWhere((site) => site.id == 'hanxiaoquan');
    if (hanxiaoquan >= 0) {
      expect(hanxiaoquan, greaterThan(0));
    }
  });

  test('列表无真果·鉴时保持原顺序', () {
    final ordered = SourceSite.orderVideoGroup([SourceSite.hanxiaoquan]);
    expect(ordered.map((site) => site.id).toList(), ['hanxiaoquan']);
  });

  test('真果·鉴在中间/重复时只前置一次', () {
    final dongpiandi = SourceSite.byId('dongpiandi');
    expect(dongpiandi, isNotNull);
    final ordered = SourceSite.orderVideoGroup([
      SourceSite.hanxiaoquan,
      dongpiandi!,
      SourceSite.hanxiaoquan,
    ]);
    expect(ordered.first.id, 'dongpiandi');
    expect(ordered.where((site) => site.id == 'dongpiandi').length, 1);
    expect(ordered.length, 3);
  });
}
