import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'glass.dart';
import 'glass_preferences.dart';
import 'motion.dart';
import 'soft_glass.dart';

abstract final class AppTheme {
  /// 浅/深两套主题按「当前材质配方 + 玻璃开关」缓存：配方或开关变化时
  /// 重建（调参台实时生效），未变化时复用同一实例（避免每次 build 都
  /// 新建 ThemeData）。
  static ThemeData? _lightCache;
  static ThemeData? _darkCache;
  static SoftGlassSpec? _cacheSpec;
  static bool? _cacheGlass;

  static ThemeData get light => _themes(Brightness.light);
  static ThemeData get dark => _themes(Brightness.dark);

  static ThemeData _themes(Brightness brightness) {
    final spec = SoftGlassStore.state.value;
    final glass = GlassPreferences.enabled.value;
    if (_cacheSpec != spec || _cacheGlass != glass) {
      _cacheSpec = spec;
      _cacheGlass = glass;
      _lightCache = _theme(Brightness.light);
      _darkCache = _theme(Brightness.dark);
    }
    return brightness == Brightness.dark ? _darkCache! : _lightCache!;
  }

  static ThemeMode mode(String preference) => switch (preference) {
    'light' => ThemeMode.light,
    'dark' => ThemeMode.dark,
    _ => ThemeMode.system,
  };

  static String label(String preference) => switch (preference) {
    'light' => '浅色',
    'dark' => '深色',
    _ => '跟随系统',
  };

  static SystemUiOverlayStyle systemBars(Brightness brightness) {
    final icons = brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: icons,
      statusBarBrightness: brightness,
      systemStatusBarContrastEnforced: false,
      systemNavigationBarColor: Colors.transparent,
      systemNavigationBarDividerColor: Colors.transparent,
      systemNavigationBarIconBrightness: icons,
      systemNavigationBarContrastEnforced: false,
    );
  }

  static ThemeData _theme(Brightness brightness) {
    final dark = brightness == Brightness.dark;
    final background = dark ? const Color(0xFF101114) : const Color(0xFFFAF8F6);
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFFFF664F),
      brightness: brightness,
      primary: dark ? const Color(0xFFFF765F) : const Color(0xFFAD3826),
      onPrimary: dark ? const Color(0xFF3B0E07) : Colors.white,
      primaryContainer: dark
          ? const Color(0xFF5C3027)
          : const Color(0xFFFFE0D8),
      onPrimaryContainer: dark
          ? const Color(0xFFFFE0D8)
          : const Color(0xFF4B160D),
      tertiary: dark ? const Color(0xFFF6C86B) : const Color(0xFF805500),
      surface: dark ? const Color(0xFF16171B) : Colors.white,
      onSurface: dark ? const Color(0xFFF2F0F4) : const Color(0xFF252328),
      onSurfaceVariant: dark
          ? const Color(0xFFB9B6C2)
          : const Color(0xFF68636C),
      outline: dark ? const Color(0xFF85818B) : const Color(0xFF7C757D),
      outlineVariant: dark ? const Color(0xFF34343D) : const Color(0xFFE3DFDC),
      surfaceContainerLowest: dark ? const Color(0xFF0D0E11) : Colors.white,
      surfaceContainerLow: dark
          ? const Color(0xFF191A20)
          : const Color(0xFFF7F3F0),
      surfaceContainer: dark
          ? const Color(0xFF1E2026)
          : const Color(0xFFF2EEEB),
      surfaceContainerHigh: dark
          ? const Color(0xFF25262D)
          : const Color(0xFFEDE8E5),
      surfaceContainerHighest: dark
          ? const Color(0xFF30313A)
          : const Color(0xFFE6E0DC),
      surfaceTint: Colors.transparent,
    );
    // 柔光玻璃材质：主题层挂不了 BackdropFilter，只能用「同配方底色 +
    // 渐变描边」近似。底色 alpha 由 SoftGlassSpec 派生（清透），再按
    // 「无模糊时仍可读」提一档（scale）；玻璃开关关闭时整体退回不透明面。
    final spec = SoftGlassStore.state.value;
    final glass = GlassPreferences.enabled.value;
    Color flat(double scale) {
      if (!glass) return scheme.surfaceContainer;
      final isDark = brightness == Brightness.dark;
      final base = isDark ? const Color(0xFF000000) : const Color(0xFFFFFFFF);
      final alpha = (isDark ? spec.tintDark : spec.tintLight) * scale;
      final stained = Color.lerp(
        base,
        scheme.primary,
        spec.saturation.clamp(0.0, 1.0),
      )!;
      return stained.withValues(alpha: alpha.clamp(0.0, 1.0));
    }

    final glassEdge = glass
        ? SoftGlassTokens.edge(spec, brightness)
        : scheme.outlineVariant;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      // 全局页面转场：淡入 + 微缩放（motion.dart 令牌）。
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeScalePageTransitionsBuilder(),
          TargetPlatform.iOS: FadeScalePageTransitionsBuilder(),
          TargetPlatform.windows: FadeScalePageTransitionsBuilder(),
          TargetPlatform.linux: FadeScalePageTransitionsBuilder(),
          TargetPlatform.macOS: FadeScalePageTransitionsBuilder(),
        },
      ),
      // 顶栏透明沉浸化：与页面背景连成一体；核心滚动页用 SliverAppBar +
      // GlassSurface 让内容真正从顶栏后方穿过（透色玻璃）。
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        foregroundColor: scheme.onSurface,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        systemOverlayStyle: systemBars(brightness),
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant),
      // ── 柔光玻璃材质槽位（12 个）──────────────────────────────
      // card / listTile / bottomSheet / input / switch / checkbox /
      // radio / slider / tabBar / navBar / snackBar / tooltip。
      cardTheme: CardThemeData(
        color: flat(2.6),
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.32 : 0.10),
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: BorderSide(color: glassEdge),
        ),
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        textColor: scheme.onSurface,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        tileColor: flat(1.8),
        // 形态：**方形圆角矩形**（用户 2026-10-29「那些大胶囊换成方的」——
        // 整行宽扁列表项不做药丸），且**不描边**：满宽列表的描边会在屏幕上
        // 拉出一条条横线（用户反复提的"分界线"），行与行靠自身底色区分。
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: flat(3.2),
        modalBackgroundColor: flat(3.2),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        modalElevation: 0,
        showDragHandle: true,
        dragHandleColor: scheme.onSurfaceVariant.withValues(alpha: 0.45),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.onPrimary;
          return scheme.onSurfaceVariant;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return flat(2.2);
        }),
        trackOutlineColor: WidgetStatePropertyAll(glassEdge),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return Colors.transparent;
        }),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: BorderSide(color: glassEdge, width: 1.4),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return scheme.primary;
          return Colors.transparent;
        }),
        side: BorderSide(color: glassEdge, width: 1.4),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: scheme.primary,
        inactiveTrackColor: flat(2.4),
        thumbColor: scheme.primary,
        overlayColor: scheme.primary.withValues(alpha: 0.12),
        trackHeight: 4,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.primary,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: Colors.transparent,
        labelStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: flat(2.8),
        surfaceTintColor: Colors.transparent,
        indicatorColor: scheme.primary.withValues(alpha: 0.16),
        elevation: 0,
        labelTextStyle: WidgetStatePropertyAll(
          TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        elevation: 0,
        backgroundColor: dark
            ? const Color(0xFF23242B)
            : const Color(0xFF2B2A2E),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: glassEdge),
        ),
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: dark ? const Color(0xFF2A2B33) : const Color(0xFF3A3742),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: glassEdge),
        ),
        textStyle: const TextStyle(color: Colors.white, fontSize: 12),
        waitDuration: const Duration(milliseconds: 400),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: background,
        useIndicator: false,
        selectedIconTheme: IconThemeData(color: scheme.primary),
        unselectedIconTheme: IconThemeData(color: scheme.onSurfaceVariant),
        selectedLabelTextStyle: TextStyle(
          color: scheme.primary,
          fontWeight: FontWeight.w700,
        ),
        unselectedLabelTextStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: flat(2.4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: glassEdge),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: glassEdge),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: scheme.primary, width: 1.6),
        ),
      ),
      // 全 App 胶囊统一「双态玻璃胶囊」语言：与 GlassChip / GlassSurface
      // pill 档同一配方（GlassChipTokens.pill*），覆盖所有 Material Chip 系。
      chipTheme: ChipThemeData(
        backgroundColor: GlassChipTokens.pill(dark),
        selectedColor: GlassChipTokens.pillSelected(dark),
        disabledColor: scheme.surfaceContainer,
        side: BorderSide(color: GlassChipTokens.pillEdge(dark, selected: false)),
        shape: const StadiumBorder(),
        labelStyle: TextStyle(
          color: scheme.onSurface,
          fontWeight: FontWeight.w500,
        ),
        secondaryLabelStyle: TextStyle(
          color: GlassChipTokens.onSelected(dark),
          fontWeight: FontWeight.w700,
        ),
        showCheckmark: false,
        elevation: 0,
        pressElevation: 0,
        surfaceTintColor: Colors.transparent,
      ),
      // 操作按钮统一双态玻璃胶囊材质：主操作（FilledButton）=选中态
      // 深玻璃+白字，次操作（OutlinedButton）=未选白玻璃+深字+白描边。
      // 主题层只能给静态色（挂不了 BackdropFilter），半透胶囊色在页面
      // 底色上自成立，与玻璃开关无关。
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return scheme.onSurface.withValues(alpha: 0.12);
            }
            return GlassChipTokens.pillSelected(dark);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return scheme.onSurface.withValues(alpha: 0.38);
            }
            return GlassChipTokens.onSelected(dark);
          }),
          elevation: const WidgetStatePropertyAll(0),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return Colors.transparent;
            }
            return GlassChipTokens.pill(dark);
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return scheme.onSurface.withValues(alpha: 0.38);
            }
            return scheme.onSurface;
          }),
          side: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.disabled)) {
              return BorderSide(
                color: scheme.onSurface.withValues(alpha: 0.12),
              );
            }
            return BorderSide(
              color: GlassChipTokens.pillEdge(dark, selected: false),
            );
          }),
          elevation: const WidgetStatePropertyAll(0),
          shape: const WidgetStatePropertyAll(StadiumBorder()),
        ),
      ),
      // 弹窗背景透明化：玻璃质感由 GlassDialogShell（lib/glass.dart）接管，
      // 未包外壳的弹窗在深浅主题下仍由 barrier 提供对比度。
      dialogTheme: const DialogThemeData(backgroundColor: Colors.transparent),
      // 弹出菜单（含 DropdownButton）透色化：半透明玻璃同源色 +
      // 去 M3 染色，主界面菜单另由 showGlassMenu 提供真模糊。
      popupMenuTheme: PopupMenuThemeData(
        color: dark
            ? const Color(0xFF16171B).withValues(alpha: 0.88)
            : const Color(0xFFFAF8F6).withValues(alpha: 0.86),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: dark ? 0.40 : 0.18),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(
            color: Colors.white.withValues(alpha: dark ? 0.14 : 0.45),
          ),
        ),
      ),
    );
  }
}
