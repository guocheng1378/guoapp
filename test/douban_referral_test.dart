import 'dart:async';

import 'package:duanju_app/app_build.dart';
import 'package:duanju_app/detail_screen.dart';
import 'package:duanju_app/featured_catalog.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/models.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

/// 按站源返回不同的同名命中，记录被搜过的源（验证并发覆盖范围）。
class _ReferralRepository extends FixtureRepository {
  _ReferralRepository(this.hits);

  final Map<String, List<Drama>> hits;
  final searched = <String>[];

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async {
    searched.add(source);
    return CatalogPage(hits[source] ?? const <Drama>[]);
  }
}

const _doubanDrama = Drama(
  id: 'douban:100',
  source: 'douban',
  title: '长夜将明',
);

Drama _hit(String source, String title) =>
    Drama(id: '$source:100', source: source, title: title, episodes: 24);

Future<LocalStore> _storeWithOnly(List<String> enabled) async {
  SharedPreferences.setMockInitialValues({});
  final store = LocalStore(await SharedPreferences.getInstance());
  addTearDown(store.dispose);
  final switches = <String, bool>{
    for (final site in SourceSite.values) site.id: false,
  };
  for (final id in enabled) {
    switches[id] = true;
  }
  await store.setSourceSwitches(switches);
  return store;
}

Future<void> _pumpHost(
  WidgetTester tester, {
  required _ReferralRepository repository,
  required LocalStore store,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              key: const ValueKey('go'),
              onPressed: () => unawaited(
                openDoubanReferral(
                  context,
                  repository: repository,
                  store: store,
                  drama: _doubanDrama,
                ),
              ),
              child: const Text('查找'),
            ),
          ),
        ),
      ),
    ),
  );
}

/// 详情页相关推荐链落空时会起 800ms 重试 timer（related_dramas.dart）。
/// 纯 timer 不调度帧，pumpAndSettle 不会等它；显式推进一秒让它自然收尾，
/// 否则用例结束会报「A Timer is still pending」。
Future<void> _settleDetailScreen(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(resetDoubanReferralBusy);

  test('标题匹配档位：精确 > 包含，标点归一，短标题不误命中', () {
    expect(referralMatchScore('长夜将明', '长夜将明'), 3);
    expect(referralMatchScore('长夜将明', '长夜将明（2024）'), 2);
    expect(referralMatchScore('长夜将明：第一季', '长夜将明'), 1);
    expect(referralMatchScore('长夜将明', '无关剧集'), 0);
    // 单字榜名不能把整页结果都算成同名。
    expect(referralMatchScore('爱', '爱情剧'), 0);
    expect(referralMatchScore('长夜将明', ''), 0);
  });

  testWidgets('候选源覆盖各大类、排除豆瓣、不超过上限', (tester) async {
    final store = await _storeWithOnly([
      'hongguo',
      'dongpiandi',
      'heitao',
    ]);
    final sources = doubanReferralSources(store);
    if (allSourcesEnabled) {
      expect(sources, containsAll(<String>['hongguo', 'dongpiandi', 'heitao']));
    } else {
      // 单源变体里 heitao/dongpiandi 不在编译期站源表中。
      expect(sources, <String>['hongguo']);
    }
    expect(sources, isNot(contains('douban')));
    expect(sources.length, lessThanOrEqualTo(referralSourceLimit));
    expect(sources.first, store.source);
  });

  testWidgets('多个站源命中时列出来源，点非真果·鉴的源即进该源详情',
      (tester) async {
    if (!allSourcesEnabled) return;
    final store = await _storeWithOnly([
      'hongguo',
      'dongpiandi',
      'heitao',
    ]);
    final repository = _ReferralRepository({
      'hongguo': [_hit('hongguo', '长夜将明')],
      'dongpiandi': [_hit('dongpiandi', '长夜将明（2024）')],
      'heitao': [_hit('heitao', '长夜将明')],
    });
    await _pumpHost(tester, repository: repository, store: store);

    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();

    expect(find.text('「长夜将明」的可播放来源'), findsOneWidget);
    expect(find.byKey(const ValueKey('referral-hongguo')), findsOneWidget);
    expect(find.byKey(const ValueKey('referral-dongpiandi')), findsOneWidget);
    expect(find.byKey(const ValueKey('referral-heitao')), findsOneWidget);
    // 三个源都被并发搜过，且不会去问无播放链路的豆瓣。
    expect(
      repository.searched.toSet(),
      containsAll(<String>['hongguo', 'dongpiandi', 'heitao']),
    );
    expect(repository.searched, isNot(contains('douban')));

    await tester.tap(find.byKey(const ValueKey('referral-heitao')));
    await _settleDetailScreen(tester);

    expect(find.byType(DetailScreen), findsOneWidget);
    expect(
      tester.widget<DetailScreen>(find.byType(DetailScreen)).drama.source,
      'heitao',
    );
  });

  testWidgets('只有一个站源命中时直进详情、不弹选择面板', (tester) async {
    if (!allSourcesEnabled) return;
    final store = await _storeWithOnly([
      'hongguo',
      'dongpiandi',
      'heitao',
    ]);
    final repository = _ReferralRepository({
      'hongguo': [_hit('hongguo', '长夜将明')],
    });
    await _pumpHost(tester, repository: repository, store: store);

    await tester.tap(find.byKey(const ValueKey('go')));
    await _settleDetailScreen(tester);

    expect(find.text('「长夜将明」的可播放来源'), findsNothing);
    expect(find.byType(DetailScreen), findsOneWidget);
    expect(
      tester.widget<DetailScreen>(find.byType(DetailScreen)).drama.source,
      'hongguo',
    );
  });

  testWidgets('全部落空时提示手动搜索', (tester) async {
    final store = await _storeWithOnly(['hongguo']);
    final repository = _ReferralRepository(const {});
    await _pumpHost(tester, repository: repository, store: store);

    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
    // 「正在查找」SnackBar 有 2s 时长，结果提示排在它后面出队。
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();

    expect(find.textContaining('未在站源中找到'), findsOneWidget);
    expect(find.byType(DetailScreen), findsNothing);
  });

  testWidgets('取消选择面板不进详情', (tester) async {
    if (!allSourcesEnabled) return;
    final store = await _storeWithOnly([
      'hongguo',
      'dongpiandi',
      'heitao',
    ]);
    final repository = _ReferralRepository({
      'hongguo': [_hit('hongguo', '长夜将明')],
      'dongpiandi': [_hit('dongpiandi', '长夜将明')],
      'heitao': [_hit('heitao', '长夜将明')],
    });
    await _pumpHost(tester, repository: repository, store: store);

    await tester.tap(find.byKey(const ValueKey('go')));
    await tester.pumpAndSettle();
    expect(find.text('「长夜将明」的可播放来源'), findsOneWidget);

    await tester.tapAt(const Offset(8, 8));
    await tester.pumpAndSettle();
    expect(find.byType(DetailScreen), findsNothing);
  });
}
