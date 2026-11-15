import 'package:duanju_app/core_bridge.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预取冷却隔离的 Dart 侧契约：
/// 载荷里的 `background` 键必须与原生 nativeInput.Background 的 json tag
/// 一致，否则原生侧收不到标记，预取的 429 还是会污染前台冷却表。
void main() {
  const drama = Drama(
    id: 'hongguo:1',
    source: 'hongguo',
    sourceId: '1',
    title: '样本剧',
  );

  test('后台预取的详情请求带 background 标记', () {
    final input = buildDetailInput(drama, background: true);
    expect(input['action'], 'detail');
    expect(input['background'], true);
    expect((input['drama'] as Map<String, dynamic>)['id'], 'hongguo:1');
  });

  test('前台详情请求不带 background 标记', () {
    final input = buildDetailInput(drama, background: false);
    expect(input['action'], 'detail');
    expect(input.containsKey('background'), isFalse);
  });
}
