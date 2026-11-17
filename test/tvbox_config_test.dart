import 'dart:convert';

import 'package:duanju_app/custom_sources.dart';
import 'package:duanju_app/tvbox_config.dart';
import 'package:flutter_test/flutter_test.dart';

String _config(Object sites, Object lives) =>
    jsonEncode({'sites': sites, 'lives': lives});

String _reason(TvboxImportPlan plan, String label) => plan.notices
    .firstWhere((notice) => notice.label == label,
        orElse: () => const TvboxNotice('', ''))
    .reason;

void main() {
  group('CustomSourceSpec.normalizeUrl', () {
    test('strips the full CMS api path so Go does not append it twice', () {
      const cases = <String, String>{
        'https://host.example/api.php/provide/vod/?ac=videolist':
            'https://host.example',
        'https://host.example/api.php/provide/vod?at=json':
            'https://host.example',
        'https://host.example/cms/api.php/provide/vod':
            'https://host.example/cms',
        'https://host.example/provide/vod/': 'https://host.example',
        'http://host.example:8080/api.php/provide/vod?ac=list':
            'http://host.example:8080',
      };
      cases.forEach((input, expected) {
        expect(CustomSourceSpec.normalizeUrl(input), expected,
            reason: 'input=$input');
        // 归一化必须幂等（Go 核心会再做一次）。
        expect(CustomSourceSpec.normalizeUrl(expected), expected);
      });
    });

    test('keeps subdirectory installs and plain roots', () {
      expect(CustomSourceSpec.normalizeUrl('https://host.example/maccms/'),
          'https://host.example/maccms');
      expect(CustomSourceSpec.normalizeUrl('  https://host.example/  '),
          'https://host.example');
      expect(CustomSourceSpec.normalizeUrl('https://host.example'),
          'https://host.example');
    });

    test('returns invalid urls unchanged for validate to reject', () {
      expect(CustomSourceSpec.normalizeUrl('ftp://host.example/vod'),
          'ftp://host.example/vod');
      expect(CustomSourceSpec.normalizeUrl('api.example.com/vod'),
          'api.example.com/vod');
    });
  });

  group('TvboxConfigParser sites', () {
    test('imports CMS sites and skips spider/embedded sources with reasons', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {
              'key': 'cms1',
              'name': '我的影视',
              'type': 1,
              'api': 'https://cms.example.com/api.php/provide/vod/?ac=videolist',
              'categories': ['电影', '电视剧'],
            },
            {
              'key': 'short',
              'name': '短剧站',
              'type': 0,
              'api': 'https://short.example.com',
              'categories': ['短剧'],
            },
            {
              'key': 'spider',
              'name': '爬虫源',
              'type': 3,
              'api': 'csp_MySpider',
              'jar': './jar/custom.jar',
            },
          ],
          [
            {
              'name': '我的直播',
              'type': 0,
              'url': 'https://live.example.com/a.m3u',
              'epg': 'https://epg.example.com/e.xml',
            },
            {'name': '备用', 'url': 'https://live.example.com/b.txt'},
            {
              'name': '内嵌',
              'channels': [
                {
                  'name': 'CCTV1',
                  'urls': ['https://x.example.com/y.m3u8'],
                },
              ],
            },
          ],
        ),
      );

      expect(plan.sites, hasLength(2));
      expect(plan.sites[0].url, 'https://cms.example.com');
      expect(plan.sites[0].category, 'video');
      expect(plan.sites[1].url, 'https://short.example.com');
      expect(plan.sites[1].category, 'shortDrama');
      expect(
        [for (final entry in plan.liveSources) entry.url],
        containsAll(<String>[
          'https://live.example.com/a.m3u',
          'https://live.example.com/b.txt',
        ]),
      );
      expect(plan.liveSources.any((entry) => entry.isInline), isTrue);
      expect(_reason(plan, '短剧站'), contains('XML'));
      expect(_reason(plan, '爬虫源'), contains('爬虫 jar'));
      expect(_reason(plan, '内嵌'), contains('内联订阅'));
      expect(_reason(plan, '我的直播'), contains('EPG'));
      expect(plan.notices.any((n) => n.label == '直播订阅'), isTrue,
          reason: '需提示支持的订阅正文格式');
    });

    test('extracts typeId from ext object/json string/plain number/query', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {
              'name': 'A',
              'api': 'https://a.example.com/api.php/provide/vod/?t=12',
              'ext': {'type_id': 12},
            },
            {
              'name': 'B',
              'api': 'https://b.example.com',
              'ext': '{"type_id":7}',
            },
            {
              'name': 'C',
              'api': 'https://c.example.com/',
              'ext': 'type_id=9',
            },
            {'name': 'D', 'api': 'https://d.example.com', 'ext': '5'},
            {
              'name': 'E',
              'api': 'https://e.example.com/?t=21',
            },
          ],
          <Object?>[],
        ),
      );
      expect(
        [for (final site in plan.sites) site.typeId],
        ['12', '7', '9', '5', '21'],
      );
      expect(
        [for (final site in plan.sites) site.url],
        [
          'https://a.example.com',
          'https://b.example.com',
          'https://c.example.com',
          'https://d.example.com',
          'https://e.example.com',
        ],
      );
    });

    test('skips non-CMS and non-http entries', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {'name': '非CMS', 'api': 'https://x.example.com/api/v1/vod'},
            {'name': 'csp', 'api': 'csp_Xxx'},
            {'name': '无api'},
            {'name': '静态', 'api': 'https://x.example.com/list.json'},
          ],
          <Object?>[],
        ),
      );
      expect(plan.sites, isEmpty);
      expect(_reason(plan, '非CMS'), contains('非苹果 CMS'));
      expect(_reason(plan, 'csp'), contains('爬虫标记'));
      expect(_reason(plan, '无api'), contains('没有 http(s)'));
      expect(_reason(plan, '静态'), contains('非苹果 CMS'));
      expect(plan.isEmpty, isTrue);
    });

    test('deduplicates sites by normalized url', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {'name': '一', 'api': 'https://x.example.com'},
            {
              'name': '二',
              'api': 'https://x.example.com/api.php/provide/vod/?ac=videolist',
            },
          ],
          <Object?>[],
        ),
      );
      expect(plan.sites, hasLength(1));
      expect(_reason(plan, '二'), contains('重复'));
    });

    test('sanitizes names and maps adult/ua notices', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {'name': '名' * 40, 'api': 'https://long.example.com'},
            {'api': 'https://blank.example.com'},
            {
              'name': '成人站',
              'api': 'https://adult.example.com',
              'categories': ['成人', '福利'],
              'ua': 'Mozilla/5.0',
            },
          ],
          <Object?>[],
        ),
      );
      expect(plan.sites[0].name.runes.length, 32);
      expect(plan.sites[1].name, 'TVBox 站点 2');
      expect(plan.sites[2].category, 'adult');
      expect(plan.sites[2].headers['User-Agent'], 'Mozilla/5.0');
      expect(_reason(plan, '成人站'), contains('默认隐藏'));
      expect(plan.notices.any((n) => n.reason.contains('已携带')), isTrue);
    });
  });

  group('TvboxConfigParser config shapes', () {
    test('accepts JSONC comments and string lives', () {
      const text = '''
      {
        // 站点
        "sites": [{"name": "注释源", "api": "https://c.example.com"}],
        /* 直播 */
        "lives": ["https://live.example.com/a.m3u"],
        "spider": "https://jar.example.com/x.jar",
        "parse": {"a": 1}
      }
      ''';
      final plan = TvboxConfigParser.parse(text);
      expect(plan.sites.single.name, '注释源');
      expect(
        [for (final entry in plan.liveSources) entry.url],
        ['https://live.example.com/a.m3u'],
      );
      expect(_reason(plan, 'spider'), contains('爬虫 jar'));
      expect(plan.notices.any((n) => n.label == '其它配置'), isTrue);
    });

    test('deduplicates live urls and ignores epg/proxy-only entries', () {
      final plan = TvboxConfigParser.parse(
        _config(
          <Object?>[],
          [
            {'name': 'a', 'url': 'https://live.example.com/a.m3u', 'type': 1},
            'https://live.example.com/a.m3u',
            {'name': 'b', 'url': 'ftp://live.example.com/b.m3u'},
            {'name': 'c', 'epg': 'https://epg.example.com/e.xml'},
          ],
        ),
      );
      expect(
        [for (final entry in plan.liveSources) entry.url],
        ['https://live.example.com/a.m3u'],
      );
      expect(_reason(plan, 'a'), contains('代理型'));
      expect(_reason(plan, 'b'), contains('不是 http(s)'));
      expect(_reason(plan, 'c'), contains('没有订阅链接'));
    });

    test('rejects non-config input with actionable messages', () {
      expect(() => TvboxConfigParser.parse(''),
          throwsA(isA<TvboxConfigException>()));
      expect(() => TvboxConfigParser.parse('{}'),
          throwsA(isA<TvboxConfigException>()));
      expect(() => TvboxConfigParser.parse('[]'),
          throwsA(isA<TvboxConfigException>()));
      // 地址拉取由导入对话框负责；解析器只做兜底提示（内容取回但非 JSON）。
      expect(
        () => TvboxConfigParser.parse('https://x.example.com/config.json'),
        throwsA(isA<TvboxConfigException>()
            .having((e) => e.message, 'message', contains('接口地址'))),
      );
      final encoded = 'eyJzaXRlcyI6W10sImxpdmVzIjpbXX0=${'A' * 60}';
      expect(
        () => TvboxConfigParser.parse(encoded),
        throwsA(isA<TvboxConfigException>()
            .having((e) => e.message, 'message', contains('加密'))),
      );
    });
  });

  group('P1: per-source headers and inline channels', () {
    test('site ua/header in object, JSON string and key:value forms', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {
              'name': '对象头',
              'api': 'https://a.example.com',
              'header': {'Referer': 'https://a.example.com/'},
              'ua': 'UA-Object',
            },
            {
              'name': 'JSON头',
              'api': 'https://b.example.com',
              'header': '{"User-Agent":"UA-Json","Cookie":"sid=1"}',
            },
            {
              'name': '行头',
              'api': 'https://c.example.com',
              'headers': 'Referer: https://c.example.com/\nX-Token: abc',
            },
          ],
          <Object?>[],
        ),
      );
      expect(plan.sites, hasLength(3));
      expect(plan.sites[0].headers, {
        'User-Agent': 'UA-Object',
        'Referer': 'https://a.example.com/',
      });
      expect(plan.sites[1].headers,
          {'User-Agent': 'UA-Json', 'Cookie': 'sid=1'});
      expect(plan.sites[2].headers,
          {'Referer': 'https://c.example.com/', 'X-Token': 'abc'});
    });

    test('embedded channels become an inline subscription with JSON payload',
        () {
      final plan = TvboxConfigParser.parse(
        _config(
          <Object?>[],
          [
            {
              'name': '央视组',
              'channels': [
                {
                  'name': 'CCTV1',
                  'urls': [
                    'https://cdn.example.com/1.m3u8',
                    'https://cdn.example.com/1b.m3u8',
                  ],
                },
                {
                  'name': 'CCTV5',
                  'url': 'https://cdn.example.com/5.m3u8',
                },
                {'name': '坏频道'},
              ],
            },
          ],
        ),
      );
      final inline = plan.liveSources.single;
      expect(inline.isInline, isTrue);
      expect(inline.displayLabel, '央视组');
      final decoded = jsonDecode(inline.payload) as Map<String, dynamic>;
      final channels = decoded['channels'] as List;
      expect(channels, hasLength(2));
      expect((channels.first as Map)['name'], 'CCTV1');
      expect((channels.first as Map)['urls'], hasLength(2));
      expect(inline.toPayload()['payload'], inline.payload);
    });

    test('live subscription carries its ua/header', () {
      final plan = TvboxConfigParser.parse(
        _config(
          <Object?>[],
          [
            {
              'name': '带防盗链',
              'url': 'https://live.example.com/a.m3u',
              'ua': 'okhttp/4.9',
              'header': {'Referer': 'https://live.example.com/'},
            },
          ],
        ),
      );
      final entry = plan.liveSources.single;
      expect(entry.headers,
          {'User-Agent': 'okhttp/4.9', 'Referer': 'https://live.example.com/'});
      expect(entry.toPayload()['headers'], entry.headers);
    });

    test('too many headers are truncated to the core limit', () {
      final plan = TvboxConfigParser.parse(
        _config(
          [
            {
              'name': '多头',
              'api': 'https://many.example.com',
              'header': {
                for (var i = 0; i < 12; i++) 'X-H$i': 'v$i',
              },
            },
          ],
          <Object?>[],
        ),
      );
      expect(plan.sites.single.headers, hasLength(8));
    });
  });
}
