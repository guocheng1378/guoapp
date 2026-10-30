import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:duanju_app/models.dart';
import 'package:duanju_app/remote_widgets.dart';

Episode episode(Map<String, dynamic> raw, int fallback) => Episode(raw, fallback);

void main() {
  test('纯序号兜底的标题不额外显示文字', () {
    final plain = episode({'id': 'av_1', 'title': '第7集', 'currentEpisode': 7}, 7);
    expect(plain.remoteLabel, isNull);
    // 站点没给标题时核心兜底成「第N集」，同样不值得占格子。
    expect(episode({'id': 'av_2'}, 3).remoteLabel, isNull);
    expect(episode({'id': 'av_3', 'title': '  '}, 5).remoteLabel, isNull);
  });

  test('批次与附加内容归一成格子放得下的紧凑写法', () {
    // 真果·鉴不少目录是「一个条目 = 20 集合集」：原文「第1-20集」在选集
    // 格子里会被切成人「第1…」，所以只保留区间号。
    expect(episode({'id': 'a', 'title': '第1-20集', 'currentEpisode': 1}, 1).remoteLabel, '1-20');
    expect(episode({'id': 'a', 'title': '第21~40集', 'currentEpisode': 21}, 21).remoteLabel, '21-40');
    // 带后缀的附加内容把集号挪到后面：「第3集彩蛋」→「彩蛋3」。
    expect(episode({'id': 'b', 'title': '第3集彩蛋', 'currentEpisode': 3}, 3).remoteLabel, '彩蛋3');
    expect(episode({'id': 'c', 'title': '第5集预告', 'currentEpisode': 5}, 5).remoteLabel, '预告5');
    // 本来就是短词的照原样显示。
    expect(episode({'id': 'd', 'title': '陪看1', 'currentEpisode': 2}, 2).remoteLabel, '陪看1');
    expect(episode({'id': 'e', 'title': '正片', 'currentEpisode': 1}, 1).remoteLabel, '正片');
  });

  test('显示用紧凑写法，序号与完整标题都不动', () {
    final batch = episode({'id': 'a', 'title': '第1-20集', 'currentEpisode': 1}, 1);
    expect(batch.remoteLabel, '1-20');
    // 完整标题保留（读屏用），序号仍是站点原值（续播/定位依赖它）。
    expect(batch.title, '第1-20集');
    expect(batch.number, 1);
  });

  testWidgets('选集按钮：有站点文字画文字，没有画数字', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            const RemoteEpisodeButton(
              number: 1,
              label: '1-20',
              semanticsLabel: '第1-20集',
              onPressed: _noop,
            ),
            const RemoteEpisodeButton(number: 2, onPressed: _noop),
          ],
        ),
      ),
    );
    expect(find.text('1-20'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);

    final labels = <String>{
      for (final element in find.byType(Semantics).evaluate())
        (element.widget as Semantics).properties.label ?? '',
    };
    // 读屏念的是完整语义，不能把批次念成「第 1 集」。
    expect(labels, contains('第1-20集'));
    expect(labels, contains('第 2 集'));
  });

  testWidgets('详情页选集把站点文字透传给按钮', (tester) async {
    final episodes = [
      episode({'id': 'a', 'title': '第1-20集', 'currentEpisode': 1}, 1),
      episode({'id': 'b', 'title': '第2集', 'currentEpisode': 2}, 2),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              for (final item in episodes)
                RemoteEpisodeButton(
                  key: ValueKey('episode-${item.number}'),
                  number: item.number,
                  label: item.remoteLabel,
                  semanticsLabel: item.title,
                  onPressed: _noop,
                ),
            ],
          ),
        ),
      ),
    );
    final batch = tester.widget<RemoteEpisodeButton>(
      find.byKey(const ValueKey('episode-1')),
    );
    final single = tester.widget<RemoteEpisodeButton>(
      find.byKey(const ValueKey('episode-2')),
    );
    expect(batch.label, '1-20');
    expect(single.label, isNull);
    expect(batch.number, 1);
    expect(single.number, 2);
  });
}

void _noop() {}
