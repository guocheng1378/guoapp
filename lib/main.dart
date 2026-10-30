import 'dart:io';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'core_bridge.dart';
import 'app_layout.dart';
import 'app_orientation.dart';
import 'app_theme.dart';
import 'glass_preferences.dart';
import 'fog_tuning.dart';
import 'soft_glass.dart';
import 'home_screen.dart';
import 'live_route_memory.dart';
import 'local_snapshot_files.dart';
import 'local_store.dart';
import 'profiles_screen.dart';
import 'media_library.dart';
import 'package_smoke.dart';
import 'lan_controller.dart';
import 'player_screen.dart';
import 'video_enhancement_assets.dart';
import 'app_icons.dart';
import 'remote_notice.dart';

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(AppTheme.systemBars(Brightness.dark));
  }
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
  }
  MediaKit.ensureInitialized();
  VideoEnhancementAssets.registerLicenses();
  if (Platform.isWindows && arguments.firstOrNull == '--package-smoke') {
    await runPackageSmoke(arguments);
    return;
  }
  // 设备探测（是否电视 / 安装包版本号）不再挡首帧：先把界面挂起来，探测在
  // bootstrap 内与偏好读取、原生核心初始化并行，回填后再重建（见 _refreshDevice）。
  runApp(const AppBootstrap());
}

class AppBootstrap extends StatefulWidget {
  const AppBootstrap({super.key, this.device = const AppDevice()});
  final AppDevice device;
  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap>
    with WidgetsBindingObserver {
  final repository = NativeRepository();
  final navigator = GlobalKey<NavigatorState>();
  LocalStore? store;
  Object? error;
  late AppDevice device = widget.device;
  Future<void>? _deviceProbe;

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    LanController.current?.dispose();
    LanController.current = null;
    MediaLibrary.current?.dispose();
    MediaLibrary.current = null;
    store?.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 探测先跑起来，_initialize 只 await 这个已发起的 Future，不额外多等一段。
    _deviceProbe = _refreshDevice();
    _initialize();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && Platform.isAndroid) {
      unawaited(_refreshDevice());
    }
    // 剧库落盘走合并窗（连续翻页只落盘一次）：切后台/退出前冲一次，
    // 别让窗口里待写的快照随进程一起消失。
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      unawaited(flushNativeCatalogWrites());
    }
    if (!Platform.isIOS) return;
    final library = MediaLibrary.current;
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      if (library != null) {
        library.suspended = true;
        unawaited(library.cancel());
      }
      unawaited(
        NativeRepository(
          background: true,
        ).controlDownloads('pauseAll').catchError((Object _) {}),
      );
    } else if (state == AppLifecycleState.resumed) {
      if (library != null) library.suspended = false;
    }
  }

  Future<void> _refreshDevice() async {
    final AppDevice detected;
    try {
      detected = await AppDevice.detect(fallback: device);
    } on Object {
      // 探测失败保持当前值：默认非电视 + 编译期版本，功能不受影响。
      return;
    }
    if (!mounted ||
        (device.television == detected.television &&
            device.version == detected.version)) {
      return;
    }
    setState(() => device = detected);
  }

  Future<void> _initialize() async {
    setState(() {
      error = null;
    });
    try {
      // 启动三件互不依赖的事并行跑：偏好读取、设备探测、原生核心初始化。
      // 串行时首屏要多等「平台通道往返 + 核心 initialize」两段（项 6）。
      final Future<void> deviceReady = _deviceProbe ??= _refreshDevice();
      final List<Object?> bootstrap = await Future.wait<Object?>([
        SharedPreferences.getInstance(),
        deviceReady,
        repository.initialize(),
        // 剧库重键文件层（library/*.json.gz）所在目录，一并并行解析。
        getApplicationSupportDirectory(),
      ]);
      final preferences = bootstrap.first as SharedPreferences;
      final libraryDirectory = bootstrap[3] as Directory;
      // 四个偏好集合各自读不同 key，互不依赖，一并并行。
      await Future.wait<void>([
        GlassPreferences.load(preferences),
        FogTuningStore.load(preferences),
        SoftGlassStore.load(preferences),
        LiveRouteMemory.load(preferences),
      ]);
      // 顶栏渐变档与形态开关整档已删除（2026-10-29），清掉盘上遗留键，
      // 免得旧值留在 prefs 里没人知道它是干嘛的。
      await preferences.remove('top_gradient.v1');
      await preferences.remove('top_bar_style.v1');
      if (mounted) {
        setState(() {
          store = LocalStore(
            preferences,
            files: DirectorySnapshotFiles(directory: libraryDirectory),
          );
          repository.access = store;
          // 核心侧默认「官方优先 + 三方兜底」，这里把设备上存的选择同步下去。
          unawaited(
            repository.setDongpiandiOfficialOnly(
              store!.dongpiandiOfficialOnly,
            ),
          );
          // 本机自定义站源（设备级）启动时全量下发 Go 核心。
          unawaited(repository.setCustomSources(store!.customSources));
          MediaLibrary.attach(repository, store!);
          LanController.current?.dispose();
          final link = LanController(
            repository,
            store!,
            kind: device.television
                ? 'tv'
                : Platform.isWindows
                ? 'computer'
                : 'phone',
          );
          LanController.current = link;
          LanController.currentLink.value = link;
          link.openPlayback = (request) async {
            final epoch = request.profileEpoch;
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                !link.receiving ||
                store!.profileEpoch != epoch ||
                !store!.allowsSource(request.detail.drama.source)) {
              throw StateError('当前用户不能接收播放');
            }
            await link.playbackHost?.stop();
            if (request.cancelled ||
                !mounted ||
                store!.locked ||
                store!.profileEpoch != epoch ||
                !link.receiving) {
              throw StateError('播放接收已取消');
            }
            final navigation = navigator.currentState;
            if (navigation == null) throw StateError('接收设备界面尚未就绪');
            unawaited(
              navigation.pushAndRemoveUntil<void>(
                MaterialPageRoute<void>(
                  builder: (_) => PlayerScreen(
                    detail: request.detail,
                    initialIndex: request.index,
                    initialPosition: request.position,
                    repository: repository,
                    store: store!,
                    handoff: request,
                  ),
                ),
                (route) => route.isFirst,
              ),
            );
          };
        });
      }
    } catch (failure) {
      if (mounted) {
        setState(() {
          error = failure;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => DuanjuApp(
    repository: repository,
    store: store,
    bootstrapError: error?.toString(),
    onRetry: _initialize,
    television: device.television,
    version: device.version,
    navigatorKey: navigator,
  );
}

class DuanjuApp extends StatelessWidget {
  const DuanjuApp({
    super.key,
    required this.repository,
    this.store,
    this.bootstrapError,
    this.onRetry,
    this.television = false,
    this.version = appVersion,
    this.navigatorKey,
  });
  final AppRepository repository;
  final LocalStore? store;
  final String? bootstrapError;
  final VoidCallback? onRetry;
  final bool television;
  final String version;
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    // 材质定稿（SoftGlassStore.revision）与玻璃开关变化都要求重建主题：
    // 主题层挂不了 BackdropFilter，只能用材质色近似，故需整壳刷新。
    animation: Listenable.merge([
      store,
      SoftGlassStore.revision,
      GlassPreferences.enabled,
    ]),
    builder: (_, _) => _application(),
  );

  Widget _application() => MaterialApp(
    navigatorKey: navigatorKey,
    title: appName,
    debugShowCheckedModeBanner: false,
    locale: const Locale('zh', 'CN'),
    supportedLocales: const [Locale('zh', 'CN')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    theme: AppTheme.light,
    darkTheme: AppTheme.dark,
    themeMode: AppTheme.mode(store?.themeMode ?? 'system'),
    builder: (context, child) {
      final mode = store?.displayMode ?? 'auto';
      final tv = mode == 'television' || mode == 'auto' && television;
      final theme = Theme.of(context);
      return AnnotatedRegion<SystemUiOverlayStyle>(
        value: AppTheme.systemBars(theme.brightness),
        child: ColoredBox(
          color: theme.scaffoldBackgroundColor,
          child: AppOrientationScope(
            television: tv,
            child: AppLayout(
              television: tv,
              version: version,
              child: Theme(
                data: tv ? televisionTheme(theme) : theme,
                child: Shortcuts(
                  shortcuts: const {
                    SingleActivator(
                      LogicalKeyboardKey.select,
                      includeRepeats: false,
                    ): ActivateIntent(),
                    SingleActivator(
                      LogicalKeyboardKey.gameButtonA,
                      includeRepeats: false,
                    ): ActivateIntent(),
                    SingleActivator(LogicalKeyboardKey.goBack): DismissIntent(),
                  },
                  child: FocusTraversalGroup(child: child!),
                ),
              ),
            ),
          ),
        ),
      );
    },
    home: store != null
        ? (store!.locked
            ? ProfilesScreen(store: store!, locked: true)
            : RemoteNoticeTrigger(
                version: version,
                child: HomeScreen(
                  key: ValueKey(
                    'profile-${store!.profile.id}-${store!.profileEpoch}',
                  ),
                  repository: repository,
                  store: store!,
                ),
              ))
        : Scaffold(
            body: Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppIcon(AppIcons.playCircleFilled, size: 72, color: Color(0xFFFF765F)),
                    const SizedBox(height: 24),
                    Text(
                      bootstrapError ?? '正在打开$appName',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 18),
                    ),
                    const SizedBox(height: 24),
                    if (bootstrapError == null)
                      const CircularProgressIndicator()
                    else
                      FilledButton(
                        onPressed: onRetry,
                        child: const Text('重新打开'),
                      ),
                  ],
                ),
              ),
            ),
          ),
  );
}
