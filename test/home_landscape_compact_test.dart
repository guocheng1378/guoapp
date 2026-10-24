import 'package:duanju_app/app_bottom_navigation.dart';
import 'package:duanju_app/app_layout.dart';
import 'package:duanju_app/catalog_filters.dart';
import 'package:duanju_app/glass.dart';
import 'package:duanju_app/local_store.dart';
import 'package:duanju_app/main.dart';
import 'package:duanju_app/models.dart';
import 'package:duanju_app/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fixtures.dart';

class _GridRepository extends FixtureRepository {
  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async => CatalogPage([
    for (var i = 0; i < 8; i++)
      Drama(id: 'grid:$i', source: source, title: '横屏网格第$i部'),
  ]);
}

/// 手机横屏沉浸+紧凑化（折叠屏展开态 869x400 一类）：
/// 顶栏 56→44、底栏/分类条/海报文字降档、网格 6 列、
/// 进横屏 immersiveSticky / 回竖屏恢复 edgeToEdge。
/// 守卫口径：MediaQuery 宽>高且逻辑短边 <600，桌面/TV 恒 false——
/// 测试宿主 800x600 短边=600 恰在守卫外，既有测试布局零漂移。
void main() {
  Future<LocalStore> mount(
    WidgetTester tester, {
    double width = 390,
    double height = 844,
    double dpr = 1,
  }) async {
    tester.view.physicalSize = Size(width * dpr, height * dpr);
    tester.view.devicePixelRatio = dpr;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final store = LocalStore(await SharedPreferences.getInstance());
    addTearDown(store.dispose);
    await tester.pumpWidget(
      DuanjuApp(repository: _GridRepository(), store: store),
    );
    await tester.pumpAndSettle();
    return store;
  }

  /// SystemChrome.setEnabledSystemUIMode 出站消息桩：记录目标模式并回
  /// 成功信封（flutter_tester 下不 mock 会永久挂起，见 2143 教训）。
  /// 消息 arguments 即 mode.toString() 字符串（SDK 609 行 invokeMethod
  /// 第二参数），非 map——读取方式必须与其一致。
  List<String> mockSystemUiModes(WidgetTester tester) {
    final modes = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMessageHandler(
      SystemChannels.platform.name,
      (msg) async {
        final call = const JSONMethodCodec().decodeMethodCall(msg!);
        if (call.method == 'SystemChrome.setEnabledSystemUIMode') {
          final args = call.arguments;
          if (args is String) modes.add(args);
        }
        return const JSONMethodCodec().encodeSuccessEnvelope(null);
      },
    );
    addTearDown(() {
      tester.binding.defaultBinaryMessenger.setMockMessageHandler(
        SystemChannels.platform.name,
        null,
      );
    });
    return modes;
  }

  testWidgets('landscapePhone 口径：折叠屏横屏 true、竖屏 false', (tester) async {
    tester.view.physicalSize = const Size(1738, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    late bool landscape;
    late bool portrait;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            landscape = AppLayout.landscapePhone(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(landscape, isTrue);

    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            portrait = AppLayout.landscapePhone(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(portrait, isFalse);
  });

  testWidgets('landscapePhone 排除桌面平台（窗口尺寸不可控）', (tester) async {
    tester.view.physicalSize = const Size(1738, 800);
    tester.view.devicePixelRatio = 2;
    addTearDown(tester.view.reset);
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    late bool result;
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Builder(
          builder: (context) {
            result = AppLayout.landscapePhone(context);
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    expect(result, isFalse);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('横屏紧凑：顶栏44+底栏/分类条/胶囊紧凑+网格6列', (tester) async {
    await mount(tester, width: 869, height: 400, dpr: 2);
    final context = tester.element(find.byType(Scaffold).first);

    // 顶栏 56→44（沉浸后 padding.top=0，顶栏即吸顶头）。
    expect(find.byType(AppBar), findsOneWidget);
    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, 44);

    // 底栏整体降档（外边距/项内边距/图标/字号随 compact 收窄）。
    final nav = tester.widget<AppBottomNavigation>(
      find.byType(AppBottomNavigation),
    );
    expect(nav.compact, isTrue);

    // 分类条降一档（52 档 → 38 档 + extra 4）。
    expect(CatalogFilters.barHeight(context), closeTo(42, 0.01));

    // 分类条胶囊进 dense 档（内边距 18/9 → 12/5）。
    expect(
      find.byWidgetPredicate((w) => w is GlassChip && w.dense),
      findsWidgets,
    );

    // 网格 /150 分母 → 869 宽出 6 列（竖屏 3 列与桌面分档不变）。
    final delegate =
        dramaGridDelegate(context, 869) as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 6);
    expect(delegate.mainAxisSpacing, 14);

    // 海报文字降档（标题 14→12.5、副标题 12→10.5）。
    expect(DramaTile.titleHeight(context), closeTo(12.5 * 2.6, 0.01));
    expect(DramaTile.subtitleHeight(context), closeTo(10.5 * 1.3, 0.01));
  });

  testWidgets('竖屏维持原布局（紧凑档不误伤）', (tester) async {
    await mount(tester);
    final context = tester.element(find.byType(Scaffold).first);

    expect(tester.widget<AppBar>(find.byType(AppBar)).toolbarHeight, isNull);
    final nav = tester.widget<AppBottomNavigation>(
      find.byType(AppBottomNavigation),
    );
    expect(nav.compact, isFalse);
    expect(CatalogFilters.barHeight(context), closeTo(56, 0.01));
    expect(
      find.byWidgetPredicate((w) => w is GlassChip && w.dense),
      findsNothing,
    );
    final delegate =
        dramaGridDelegate(context, 390) as SliverGridDelegateWithFixedCrossAxisCount;
    expect(delegate.crossAxisCount, 3);
    expect(DramaTile.titleHeight(context), closeTo(14 * 2.6, 0.01));
  });

  testWidgets('进横屏切沉浸、回竖屏恢复 edgeToEdge', (tester) async {
    final modes = mockSystemUiModes(tester);
    await mount(tester);

    // 竖屏启动：初始态即 edgeToEdge 恒等，不产生平台调用。
    expect(modes, isEmpty);

    // 折叠屏展开 → 沉浸（状态栏隐藏，下滑临时呼出）。
    tester.view.physicalSize = const Size(1738, 800);
    tester.view.devicePixelRatio = 2;
    await tester.pumpAndSettle();
    expect(modes, isNotEmpty);
    expect(modes.last, 'SystemUiMode.immersiveSticky');

    // 折叠回竖屏 → 恢复常规 edgeToEdge。
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    await tester.pumpAndSettle();
    expect(modes.last, 'SystemUiMode.edgeToEdge');
  });
}
