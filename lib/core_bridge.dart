import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'models.dart';
import 'custom_sources.dart';
import 'danmaku_models.dart';
import 'search_suggestion.dart';
import 'background_downloads.dart';
import 'local_store.dart';
import 'app_build.dart';
import 'source_status.dart';
import 'ranking_models.dart';
import 'home_feed_models.dart';
import 'live_models.dart';
import 'cover_decoder.dart';
import 'catalog_updates.dart';
import 'download_collections.dart';
import 'resource_settings.dart';

typedef _NativeRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _DartRequest = Pointer<Utf8> Function(Pointer<Utf8>);
typedef _NativeFree = Void Function(Pointer<Utf8>);
typedef _DartFree = void Function(Pointer<Utf8>);

String _nativeRequest(String body) {
  final DynamicLibrary library;
  if (Platform.isAndroid) {
    library = DynamicLibrary.open('libduanju_core.so');
  } else if (Platform.isWindows) {
    library = DynamicLibrary.open(
      path.join(path.dirname(Platform.resolvedExecutable), 'duanju_core.dll'),
    );
  } else if (Platform.isIOS) {
    library = DynamicLibrary.process();
  } else {
    throw UnsupportedError('当前首版支持 Android 手机和 Windows 电脑');
  }
  final request = library.lookupFunction<_NativeRequest, _DartRequest>(
    'DuanjuRequest',
  );
  final free = library.lookupFunction<_NativeFree, _DartFree>('DuanjuFree');
  final input = body.toNativeUtf8();
  Pointer<Utf8> output = nullptr;
  try {
    output = request(input);
    if (output == nullptr) {
      throw StateError('本地核心没有返回结果');
    }
    return output.toDartString();
  } finally {
    malloc.free(input);
    if (output != nullptr) {
      free(output);
    }
  }
}

/// 常驻 worker 的入口：一次请求进、一次结果出。
///
/// 只做「调用原生 + 原样回传」，不缓存任何业务状态；isolate 由
/// [_NativeCallPool] 复用，进程级存活。
void _nativeWorkerMain(SendPort reply) {
  final requests = ReceivePort();
  reply.send(requests.sendPort);
  requests.listen((dynamic message) {
    if (message is! String) return;
    try {
      reply.send(<Object?>[true, _nativeRequest(message)]);
    } on Object catch (error) {
      reply.send(<Object?>[false, error.toString()]);
    }
  });
}

class _NativeCallError implements Exception {
  _NativeCallError(this.message);
  final String message;
  @override
  String toString() => message;
}

class _NativeJob {
  _NativeJob(this.body, this.timeout);
  final String body;
  final Duration timeout;
  final Completer<String> _completer = Completer<String>();
  Timer? timer;

  Future<String> get future => _completer.future;

  bool get finished => _completer.isCompleted;

  void finish(List<Object?> message) {
    timer?.cancel();
    if (_completer.isCompleted) return;
    final bool ok = message.isNotEmpty && message.first == true;
    final String payload = message.length > 1 ? '${message[1]}' : '';
    if (ok) {
      _completer.complete(payload);
    } else {
      _completer.completeError(_NativeCallError(payload));
    }
  }

  void fail(Object error) {
    timer?.cancel();
    if (!_completer.isCompleted) _completer.completeError(error);
  }
}

class _NativeWorker {
  _NativeWorker(this._onIdle) : replies = ReceivePort() {
    replies.listen(_handle);
  }

  final void Function() _onIdle;
  final ReceivePort replies;
  final Completer<SendPort> _ready = Completer<SendPort>();
  Isolate? _isolate;
  SendPort? _port;
  _NativeJob? job;

  SendPort get port => _port!;

  static Future<_NativeWorker> start(void Function() onIdle) async {
    final worker = _NativeWorker(onIdle);
    try {
      worker._isolate = await Isolate.spawn<SendPort>(
        _nativeWorkerMain,
        worker.replies.sendPort,
        debugName: 'duanju-core',
      );
      worker._port = await worker._ready.future.timeout(
        const Duration(seconds: 10),
      );
      return worker;
    } on Object {
      worker.dispose();
      rethrow;
    }
  }

  void _handle(dynamic message) {
    if (message is SendPort) {
      if (!_ready.isCompleted) _ready.complete(message);
      return;
    }
    final _NativeJob? current = job;
    job = null;
    if (current == null) return;
    current.finish(message as List<Object?>);
    _onIdle();
  }

  void dispose() {
    replies.close();
    final Isolate? isolate = _isolate;
    _isolate = null;
    isolate?.kill(priority: Isolate.immediate);
  }
}

/// 常驻原生调用池（替代每请求一次 `Isolate.run`）。
///
/// 原生核心是 CGO 共享库，`DuanjuRequest` 内部本就按请求并发（Go 侧每个请求
/// 独立 goroutine）。此前每次调用都新建 isolate：封面、分页、详情这类高频短
/// 请求要付一次 isolate 创建 + 消息深拷贝 + 销毁的代价。这里改成按需扩容的
/// 常驻池——每个 worker 同一时刻只跑一个请求，满载才排队，既保留原有并发度
/// （长目录请求不会把封面堵死），又去掉每请求的 isolate 开销。
///
/// 原生调用无法被打断，因此超时的 worker 直接退役（kill 后由新 worker 顶上），
/// 迟到结果丢弃。超时语义与 `Future.timeout` 时代一致，且随后的 `cancelRead`
/// 会落在新 worker 上真正生效。
class _NativeCallPool {
  static const int limit = 6;

  final List<_NativeWorker> _workers = <_NativeWorker>[];
  final List<_NativeJob> _pending = <_NativeJob>[];
  int _spawning = 0;
  bool _spawnBlocked = false;
  Object? _spawnError;

  Future<String> send(String body, Duration timeout) {
    final Object? blocked = _spawnError;
    if (_spawnBlocked && _workers.isEmpty && blocked != null) {
      return Future<String>.error(blocked);
    }
    final job = _NativeJob(body, timeout);
    _pending.add(job);
    _pump();
    return job.future;
  }

  void _pump() {
    while (_pending.isNotEmpty) {
      final _NativeWorker? worker = _idle();
      if (worker != null) {
        _dispatch(worker, _pending.removeAt(0));
        continue;
      }
      if (_spawnBlocked) {
        if (_workers.isNotEmpty) return; // 还有 worker 在场，等它空闲。
        final Object error = _spawnError ?? StateError('原生调用线程启动失败');
        final List<_NativeJob> jobs = List<_NativeJob>.of(_pending);
        _pending.clear();
        for (final _NativeJob job in jobs) {
          job.fail(error);
        }
        return;
      }
      if (_workers.length + _spawning >= limit) return;
      _spawn();
      return;
    }
  }

  _NativeWorker? _idle() {
    for (final _NativeWorker worker in _workers) {
      if (worker.job == null) return worker;
    }
    return null;
  }

  void _spawn() {
    _spawning++;
    _NativeWorker.start(_pump).then<void>((_NativeWorker worker) {
      _spawning--;
      _workers.add(worker);
      _pump();
    }, onError: (Object error) {
      _spawning--;
      _spawnBlocked = true;
      _spawnError = error;
      _pump();
    });
  }

  void _dispatch(_NativeWorker worker, _NativeJob job) {
    worker.job = job;
    job.timer = Timer(job.timeout, () {
      if (job.finished) return;
      _retire(worker);
      job.fail(TimeoutException('本地核心响应超时', job.timeout));
      _pump();
    });
    try {
      worker.port.send(job.body);
    } on Object catch (error) {
      _retire(worker);
      job.fail(error);
      _pump();
    }
  }

  void _retire(_NativeWorker worker) {
    _workers.remove(worker);
    worker.job = null;
    worker.dispose();
  }
}

final _NativeCallPool _nativeCallPool = _NativeCallPool();

/// 远程站源配置热更（config.source）：把 app_config.json 的 sourceConfig 段
/// 转发核心应用（黄果AI 镜像表 / 真果·鉴根地址）。核心侧权威校验（scheme、
/// 去重、上限），非法段整段拒绝并保持当前生效值；本调用静默尽力而为，桥
/// 不可用 / 超时 / 核心拒绝都不抛错，不影响启动链路。与用户态无关，不经
/// _call 的访问锁与 profileEpoch 检查。
Future<void> applyNativeSourceConfig(Map<String, dynamic> sourceConfig) async {
  try {
    final body = jsonEncode(<String, dynamic>{
      'action': 'config.source',
      'sourceConfig': sourceConfig,
    });
    final encoded = await _nativeCallPool.send(
      body,
      const Duration(seconds: 10),
    );
    final response = jsonDecode(encoded);
    // applied=false（核心校验拒绝）同样静默：保持内置兜底值即可。
    if (response is Map && response['ok'] != true) return;
  } on Object {
    // 尽力而为。
  }
}

/// 强制冲刷原生侧的剧库落盘合并窗。
///
/// 剧库落盘改成合并窗后，连续翻页只落盘一次；切后台/退出/切源前必须冲一次，
/// 否则窗口里待写的快照会随进程一起消失（重启后看不到最后一次变更）。
/// 与用户态无关、不经 _call 的访问锁与 profileEpoch 检查。
///
/// 返回核心是否确认落盘成功：桥不可用 / 超时 / 核心报错（磁盘满等）都算
/// 失败。核心侧对临时故障已有 5 秒退避重试，这里不二次重试，调用方按需
/// 决定后续动作（切后台/退出路径通常只能静默）。
Future<bool> flushNativeCatalogWrites() async {
  try {
    final body = jsonEncode(<String, dynamic>{'action': 'flush'});
    final encoded = await _nativeCallPool.send(
      body,
      const Duration(seconds: 10),
    );
    final response = jsonDecode(encoded);
    return response is Map && response['ok'] == true;
  } on Object {
    // 尽力而为：冲刷失败不打断切后台/退出流程。
    return false;
  }
}

class AppFailure implements Exception {
  AppFailure(this.message, {this.code = ''});
  final String message;
  final String code;
  @override
  String toString() => message;
}

abstract class AppRepository {
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) async => throw AppFailure('当前环境不支持设备互联');
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => preload(drama, episode, quality: quality);
  Future<void> cancelHandoff() async {}
  Future<ResourceSettings> resourceSettings() async => const ResourceSettings();
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async => throw AppFailure('当前环境不支持资源设置');
  final catalogUpdates = CatalogUpdates();

  /// 详情内存缓存：进过一次的剧二次点按零网络直进；配合 prefetchDetails
  /// 在目录首页加载后预取首屏剧，首次点按也能命中。带 TTL 与在途去重。
  final Map<String, DramaDetail> _detailCache = {};
  final Map<String, DateTime> _detailCacheAt = {};
  final Map<String, Future<DramaDetail>> _detailPending = {};
  static const Duration _detailTtl = Duration(minutes: 30);
  static const int _detailCacheLimit = 64;

  String _detailKey(Drama drama) => '${drama.source}|${drama.id}';

  /// 子类用包壳方式接入缓存：命中/在途复用，否则走 [fetch] 并落缓存，
  /// 失败不缓存。测试 fake 直接覆写 detail() 即可完全绕开缓存。
  Future<DramaDetail> detailCached(
    Drama drama,
    Future<DramaDetail> Function() fetch,
  ) {
    final key = _detailKey(drama);
    final at = _detailCacheAt[key];
    if (at != null) {
      if (DateTime.now().difference(at) >= _detailTtl) {
        _detailCache.remove(key);
        _detailCacheAt.remove(key);
      } else {
        return Future.value(_detailCache[key]!);
      }
    }
    final pending = _detailPending[key];
    if (pending != null) return pending;
    final future = fetch().then((result) {
      _detailCache[key] = result;
      _detailCacheAt[key] = DateTime.now();
      if (_detailCache.length > _detailCacheLimit) {
        final oldest =
            (_detailCacheAt.entries.toList()
                  ..sort((a, b) => a.value.compareTo(b.value)))
                .first
                .key;
        _detailCache.remove(oldest);
        _detailCacheAt.remove(oldest);
      }
      return result;
    });
    _detailPending[key] = future;
    return future.whenComplete(() => _detailPending.remove(key));
  }

  /// 后台预取详情（尽力而为，失败静默）。基类 no-op，由有网络的实现覆写。
  void prefetchDetail(Drama drama) {}
  void prefetchDetails(Iterable<Drama> dramas) {}
  Future<void> cancelPreload() async {}
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => null;
  Future<void> cancelDanmaku() async {}
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async => throw AppFailure('当前环境不支持弹幕');
  Future<void> cancelCatalog() async {}
  Future<void> cancelSuggestions() async {}
  Future<void> cancelRecommendations() async {}
  Future<void> cancelHomeFeed() async {}

  /// 远端主页板块：整份板块清单来自站点，App 不内置。不支持的源直接抛错，
  /// UI 侧据此降级（退回原有本地浏览）。
  Future<HomeFeed> homeFeed(
    String source, {
    bool force = false,
  }) async =>
      throw AppFailure('当前环境不支持主页板块');

  /// 板块完整榜单（点分类进入）：翻页参数由站点 browse 描述驱动。
  Future<CatalogPage> homeSection(
    String source,
    String sectionId, {
    int page = 1,
    bool force = false,
  }) async =>
      throw AppFailure('当前环境不支持主页板块');

  /// 追剧周表（「本周追剧」）：站点 /v1/watch-calendar，按天分组。
  Future<WatchCalendar> watchCalendar(
    String source, {
    bool force = false,
  }) async =>
      throw AppFailure('当前环境不支持追剧周表');
  Future<Drama?> supplementMetadata(Drama drama) async => null;
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持红果推荐');
  Future<List<RankingBoard>> rankingBoards() async => const [];
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => throw AppFailure('当前环境不支持榜单');
  Future<LivePage> liveChannels({
    String listId = '',
    List<String> liveUrls = const [],
    bool force = false,
  }) async => throw AppFailure('当前环境不支持直播');
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async => const [CatalogCategory.all];
  bool get supportsSourceManagement => false;

  /// 真果·鉴「仅官方线路」策略下发（见 LocalStore.dongpiandiOfficialOnly）。
  Future<void> setDongpiandiOfficialOnly(bool value) async {}

  /// 全量下发本机自定义站源到 Go 核心（config.source 的 customSources 段）。
  Future<void> setCustomSources(List<CustomSourceSpec> sources) async {}

  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson({'source': source});
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async => throw AppFailure('当前环境不支持站源管理');
  Future<SourceStatus> cancelSourceJob(String source) async =>
      throw AppFailure('当前环境不支持站源管理');
  Future<List<SearchSuggestion>> suggestions(
    String query, {
    String source = '',
  }) async => const [];
  Future<Map<String, dynamic>> storage() async => {};
  Future<String> downloadDirectory() async =>
      (await storage())['directory'] as String? ?? '';
  Future<void> moveDownloads(String directory) async =>
      throw AppFailure('当前环境不支持迁移');
  Future<int> workLease(String id, String command) async => 0;
  bool get supportsDownloads => false;
  Future<List<DownloadJob>> downloads() async => [];
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async => throw AppFailure('当前环境不支持下载');
  Future<void> controlDownloads(String command, {String id = ''}) async {}
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    if (expectedVersions.isNotEmpty) throw AppFailure('当前环境不支持校验后清理原分集');
    final completed = <String>[], failures = <String, String>{};
    for (final id in ids.toSet()) {
      try {
        await controlDownloads(command, id: id);
        completed.add(id);
      } catch (error) {
        failures[id] = error.toString();
      }
    }
    return DownloadBatchResult(completed: completed, failures: failures);
  }

  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) => enqueueDownloads(detail, episodes, quality: quality);
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async =>
      null;
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) => resolve(drama, episode, quality: quality);
  Future<void> initialize();
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  });
  Future<CatalogPage> cached(String source, {String category = ''});
  Future<String> cover(Drama drama, {bool force = false});
  Future<DramaDetail> detail(Drama drama);
  Future<PlaybackPlan> resolve(Drama drama, Episode episode, {int quality = 0});
  Future<PlaybackPlan> fallback(PlaybackPlan current);
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route);
  Future<void> cancelPlayback();
  Future<void> release(String session);
}

/// 豆瓣图床 img1-9.doubanio.com 是腾讯 EdgeOne 且开 Bot 管理：Go 引擎
/// （tls-client Chrome 指纹）在手机端被判定为爬虫，返回 ~1KB 的
/// EO_Bot_Ssid JS 挑战页（HTTP 200）而非海报。Dart dart:io HttpClient
/// 是 BoringSSL 指纹（与手机 curl 同族，实测 img9 放行），因此豆瓣条目
/// 的封面在 Dart 侧直接下载，失败再回落 Go 原路兜底。
class DoubanCoverLoader {
  static const _minImageBytes = 4096;
  static final _pending = <String, Future<String>>{};
  static final _failed = <String>{};
  static Directory? _dir;

  static bool handles(String cover) => cover.contains('.doubanio.com');

  static Future<String> load(Drama drama, {bool force = false}) async {
    final url = drama.cover;
    if (!handles(url)) return '';
    if (!force && _failed.contains(url)) return '';
    final existing = _pending[url];
    if (existing != null) return existing;
    final future = _download(url, force: force);
    _pending[url] = future;
    try {
      final result = await future;
      if (result.isEmpty && !force) _failed.add(url);
      return result;
    } finally {
      _pending.remove(url);
    }
  }

  static Future<Directory> _ensureDir() async {
    final cached = _dir;
    if (cached != null) return cached;
    final base = await getTemporaryDirectory();
    final dir = Directory(path.join(base.path, 'douban_covers'));
    if (!await dir.exists()) await dir.create(recursive: true);
    return _dir = dir;
  }

  static Future<String> _download(String url, {bool force = false}) async {
    final file = File(
      path.join((await _ensureDir()).path,
          'db_${url.hashCode.toUnsigned(0x7fffffff)}.jpg'),
    );
    if (!force && await file.exists()) {
      final stat = await file.stat();
      if (stat.size > _minImageBytes) return file.path;
      await file.delete();
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 10);
    try {
      final request = await client.getUrl(Uri.parse(url));
      request.headers.set(
        HttpHeaders.userAgentHeader,
        'Mozilla/5.0 (Linux; Android 15) AppleWebKit/537.36 (KHTML, like Gecko) '
            'Chrome/150.0.0.0 Mobile Safari/537.36',
      );
      request.headers
          .set(HttpHeaders.refererHeader, 'https://movie.douban.com/');
      final response = await request.close().timeout(
            const Duration(seconds: 15),
          );
      if (response.statusCode != 200) return '';
      final bytes = await response
          .fold<List<int>>([], (acc, chunk) => acc..addAll(chunk))
          .timeout(const Duration(seconds: 20));
      // 挑战页/空体防御：真海报是几十 KB 的 JPEG（FFD8 开头）
      if (bytes.length < _minImageBytes ||
          bytes.length < 2 ||
          bytes[0] != 0xFF ||
          bytes[1] != 0xD8) {
        return '';
      }
      await file.writeAsBytes(bytes, flush: true);
      return file.path;
    } catch (_) {
      return '';
    } finally {
      client.close(force: true);
    }
  }
}

class NativeRepository extends AppRepository {
  static final _coverDecoder = CoverDecoder();
  NativeRepository({this.background = false});
  final bool background;
  LocalStore? access;
  final _readOwner = DateTime.now().microsecondsSinceEpoch.toString();
  int _readSequence = 0;
  final _activeReads = <String, int>{};

  @override
  Future<Map<String, dynamic>> lan(
    String command,
    Map<String, dynamic> payload,
  ) => _call({'action': 'lan', 'command': command, 'lan': payload});

  @override
  Future<PlaybackPlan?> prepareHandoff(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async {
    final data = await _read('handoff', {
      'action': 'prepareHandoff',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': access != null && !access!.canDownload,
    });
    return PlaybackPlan.fromJson(data);
  }

  @override
  Future<void> cancelHandoff() => _cancelReads('handoff');

  void _adminPermission() {
    if (access != null && (access!.locked || !access!.profile.admin)) {
      throw AppFailure('仅管理员可修改本机资源设置');
    }
  }

  @override
  Future<ResourceSettings> resourceSettings() async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({'action': 'resourceSettings'}),
    );
  }

  @override
  Future<ResourceSettings> saveResourceSettings(
    ResourceSettings settings,
  ) async {
    _adminPermission();
    return ResourceSettings.fromJson(
      await _call({
        'action': 'saveResourceSettings',
        'settings': settings.toJson(),
      }),
    );
  }

  Future<Map<String, dynamic>> _read(
    String scope,
    Map<String, dynamic> input,
  ) async {
    final sequence = ++_readSequence;
    _activeReads[scope] = sequence;
    try {
      return await _call({
        ...input,
        'session': '$_readOwner:$scope',
        'sequence': sequence,
      });
    } finally {
      if (_activeReads[scope] == sequence) _activeReads.remove(scope);
    }
  }

  Future<void> _cancelReads(String prefix) async {
    final reads = _activeReads.entries
        .where((entry) => entry.key.startsWith(prefix))
        .toList();
    await Future.wait(
      reads.map((entry) async {
        try {
          await _call({
            'action': 'cancelRead',
            'session': '$_readOwner:${entry.key}',
            'sequence': entry.value,
          });
        } catch (_) {}
      }),
    );
  }

  @override
  Future<void> cancelDanmaku() => _cancelReads('danmaku');

  @override
  Future<void> cancelPreload() => _cancelReads('preload');

  @override
  Future<PlaybackPlan?> preload(
    Drama drama,
    Episode episode, {
    int quality = 0,
    bool online = false,
  }) async => PlaybackPlan.fromJson(
    await _read('preload', {
      'action': 'preload',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': online || access?.canDownload == false,
    }),
  );

  @override
  Future<DanmakuPage> danmaku(
    PlaybackPlan plan, {
    required int startMs,
    required int durationMs,
  }) async {
    _authorize('hongguo');
    if (plan.local || plan.session.isEmpty || plan.danmakuId.isEmpty) {
      throw AppFailure('本集暂不支持弹幕');
    }
    return DanmakuPage.fromJson(
      await _read('danmaku', {
        'action': 'danmaku',
        'playbackSession': plan.session,
        'startMs': startMs,
        'durationMs': durationMs,
      }),
      episodeId: plan.danmakuId,
      startMs: startMs,
      durationMs: durationMs,
    );
  }

  @override
  Future<void> cancelCatalog() => _cancelReads('catalog-');
  @override
  Future<void> cancelSuggestions() => _cancelReads('suggest');
  @override
  Future<void> cancelRecommendations() => _cancelReads('recommendations-');
  @override
  Future<void> cancelHomeFeed() async {
    await _cancelReads('homeFeed-');
    await _cancelReads('homeCalendar-');
  }

  @override
  Future<HomeFeed> homeFeed(String source, {bool force = false}) async {
    final json = await _read('homeFeed-$source', {
      'action': 'homeFeed',
      'source': source,
      'force': force,
    });
    final feed = HomeFeed.fromJson(json);
    if (feed.sections.isNotEmpty) {
      prefetchDetails(feed.sections.first.items.take(12));
    }
    return feed;
  }

  @override
  Future<CatalogPage> homeSection(
    String source,
    String sectionId, {
    int page = 1,
    bool force = false,
  }) async {
    final result = CatalogPage.fromJson(
      await _read('homeSection-$sectionId-$page', {
        'action': 'homeSection',
        'source': source,
        'category': sectionId,
        'page': page,
        'force': force,
      }),
    );
    if (page == 1 && result.items.isNotEmpty) {
      prefetchDetails(result.items.take(12));
    }
    return result;
  }

  @override
  Future<WatchCalendar> watchCalendar(
    String source, {
    bool force = false,
  }) async =>
      WatchCalendar.fromJson(
        await _read('homeCalendar-$source', {
          'action': 'homeCalendar',
          'source': source,
          'force': force,
        }),
      );

  @override
  Future<CatalogPage> recommendations(
    String genre, {
    bool more = false,
    bool force = false,
  }) async {
    _authorize('hongguo');
    final result = CatalogPage.fromJson(
      await _read('recommendations-$genre', {
        'action': 'recommendations',
        'category': genre,
        'command': more ? 'more' : '',
        'force': force,
      }),
    );
    // 推荐首屏同理预取详情：点卡零网络等待。
    if (!more && result.items.isNotEmpty) {
      _prefetchQueue.clear();
      prefetchDetails(result.items.take(12));
    }
    return result;
  }

  @override
  Future<Drama?> supplementMetadata(Drama drama) async {
    if (!(drama.source == 'hongguo' && drama.onlineDate.isEmpty ||
        drama.source == 'huangdou' &&
            (drama.heat.isEmpty || drama.vipStatus == null))) {
      return null;
    }
    final result = await _read('metadata', {
      'action': 'metadata',
      'drama': drama.toJson(),
    });
    return Drama.fromJson(Map<String, dynamic>.from(result['drama'] as Map));
  }

  @override
  bool get supportsSourceManagement => true;

  @override
  Future<void> setDongpiandiOfficialOnly(bool value) async {
    await _call({'action': 'dongpiandi.officialOnly', 'officialOnly': value});
  }

  @override
  Future<void> setCustomSources(List<CustomSourceSpec> sources) async {
    await applyNativeSourceConfig({
      'customSources': [for (final source in sources) source.toPayload()],
    });
  }

  @override
  Future<List<RankingBoard>> rankingBoards() async {
    final result = await _call({'action': 'rankingBoards'});
    return [
          for (final row in result['items'] as List? ?? [])
            RankingBoard.fromJson(Map<String, dynamic>.from(row as Map)),
        ]
        .where(
          (board) =>
              SourceSite.isRankingOnly(board.source) ||
              SourceSite.isAvailable(board.source),
        )
        .toList();
  }

  @override
  Future<RankingPage> rankings(
    String board, {
    int page = 1,
    bool force = false,
  }) async => RankingPage.fromJson(
    await _call({
      'action': 'rankings',
      'board': board,
      'page': page,
      'force': force,
    }),
  );

  @override
  Future<LivePage> liveChannels({
    String listId = '',
    List<String> liveUrls = const [],
    bool force = false,
  }) async => LivePage.fromJson(
    await _call({
      'action': 'live.channels',
      'listId': listId,
      'liveUrls': liveUrls,
      'force': force,
    }),
  );

  @override
  Future<SourceStatus> sourceStatus(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'sourceStatus', 'source': source}),
      );

  @override
  Future<SourceStatus> startSourceJob(
    String source,
    String operation, {
    Drama? drama,
  }) async {
    _authorize(source);
    if (drama != null && drama.source != source) throw AppFailure('站源与剧集不匹配');
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return SourceStatus.fromJson(
      await _call({
        'action': 'sourceJob',
        'source': source,
        'command': operation,
        if (drama != null) 'drama': drama.toJson(),
      }),
    );
  }

  @override
  Future<SourceStatus> cancelSourceJob(String source) async =>
      SourceStatus.fromJson(
        await _call({'action': 'cancelSourceJob', 'source': source}),
      );

  void _authorize(String source, {bool download = false}) {
    // 豆瓣是榜单专用源：不注册 provider、不进站源菜单，因此
    // SourceSite.isAvailable('douban') 恒为 false。榜单封面（cover）等
    // 只读请求必须在此放行，否则豆瓣条目恒抛「当前版本不包含此站源」，
    // 榜单与首页轮播的豆瓣卡全部落到失败态（只显示重试图标）。
    // 豆瓣没有播放/下载链路（点击走同名搜索），无需校验用户源权限。
    if (SourceSite.isRankingOnly(source)) return;
    if (!SourceSite.authorized(source)) {
      throw AppFailure('当前版本不包含此站源');
    }
    if (access == null) return;
    if (access!.locked ||
        !access!.allowsSource(source) ||
        download && !access!.canDownload) {
      throw AppFailure('当前用户没有此操作权限');
    }
  }

  void _downloadPermission() {
    if (access != null && (access!.locked || !access!.canDownload)) {
      throw AppFailure('当前用户仅支持在线观看');
    }
  }

  @override
  Future<List<SearchSuggestion>> suggestions(
    String query, {
    String source = '',
  }) async {
    if (source == 'dongpiandi') {
      // 真果·鉴站内搜索建议（/v1/suggest，带直达播放目标）。
      final result = await _read('suggest', {
        'action': 'suggest',
        'source': source,
        'query': query,
      });
      return (result['items'] as List? ?? [])
          .whereType<Map>()
          .map(
            (item) => SearchSuggestion.fromJson(
              item.map(
                (key, value) => MapEntry(key.toString(), value),
              ),
            ),
          )
          .toList();
    }
    _authorize('hongguo');
    final result = await _read('suggestions', {
      'action': 'suggestions',
      'query': query,
    });
    return (result['items'] as List? ?? [])
        .whereType<String>()
        .map((label) => SearchSuggestion(label: label))
        .toList();
  }

  @override
  Future<String> downloadDirectory() async {
    _downloadPermission();
    return (await _call({'action': 'downloadDirectory'}))['directory']
            as String? ??
        '';
  }

  @override
  Future<Map<String, dynamic>> storage() async {
    _downloadPermission();
    return _call({'action': 'storage'});
  }

  @override
  Future<void> moveDownloads(String directory) async {
    _downloadPermission();
    if (access != null && !access!.profile.admin) {
      throw AppFailure('仅管理员可更改下载目录');
    }
    await BackgroundDownloads.ensureStarted();
    await workLease('storage', 'start');
    try {
      await _call({'action': 'moveDownloads', 'directory': directory});
    } finally {
      await workLease('storage', 'end');
    }
  }

  @override
  Future<int> workLease(String id, String command) async => intValue(
    (await _call({
      'action': 'workLease',
      'jobId': id,
      'command': command,
    }))['count'],
  );
  int _playbackSequence = DateTime.now().microsecondsSinceEpoch;

  Future<Map<String, dynamic>> _call(Map<String, dynamic> input) async {
    try {
      final action = input['action'] as String;
      final unrestricted =
          {
            'initialize',
            'release',
            'cancelPlayback',
            'cancelRead',
            'updateSystemProxy',
          }.contains(action) ||
          action == 'workLease' && input['command'] == 'end' ||
          action == 'lan' &&
              {
                'stop',
                'respond',
                'cancel',
                'disconnect',
              }.contains(input['command']);
      final epoch = access?.profileEpoch;
      if (!unrestricted && access?.locked == true) throw AppFailure('请先解锁当前用户');
      if (action == 'rankings') {
        final source = RankingBoard.sourceForID(input['board'] as String);
        // 榜单专用源（豆瓣）只读参考数据：榜单读取放行，不受站源可用性
        // 约束，但跟随访问锁；其余站源照常 _authorize。
        if (SourceSite.isRankingOnly(source)) {
          if (access?.locked ?? false) {
            throw AppFailure('当前用户没有此操作权限');
          }
        } else {
          _authorize(source);
        }
      }
      if (action == 'recommendations' ||
          action == 'cachedRecommendations' ||
          action == 'suggestions' ||
          action == 'danmaku') {
        _authorize('hongguo');
      }
      if ({
        'catalog',
        'cached',
        'categories',
        'sourceStatus',
        'sourceJob',
        'cancelSourceJob',
      }.contains(action)) {
        _authorize(input['source'] as String);
      }
      if ({
        'cover',
        'prepareCover',
        'detail',
        'metadata',
        'resolve',
        'preload',
        'prepareHandoff',
        'enqueueDownloads',
        'localPlayback',
      }.contains(action)) {
        _authorize(
          (input['drama'] as Map)['source'] as String,
          download: action == 'enqueueDownloads' || action == 'localPlayback',
        );
      }
      if (!unrestricted &&
          {
            'downloads',
            'controlDownloads',
            'controlDownloadBatch',
            'storage',
            'downloadDirectory',
            'moveDownloads',
            'workLease',
          }.contains(action)) {
        _downloadPermission();
      }
      if (action == 'resolve' && access != null && !access!.canDownload) {
        input['force'] = true;
      }
      final body = jsonEncode(input);
      final encoded = await _nativeCallPool.send(
        body,
        Duration(
          seconds: action == 'moveDownloads'
              ? 620
              : action == 'danmaku'
              ? 15
              : action == 'preload'
              ? 20
              : 70,
        ),
      );
      final response = jsonDecode(encoded) as Map<String, dynamic>;
      if (response['ok'] != true) {
        throw AppFailure(
          response['error'] as String? ?? '读取失败，请重试',
          code: response['code'] as String? ?? '',
        );
      }
      final data = response['data'];
      if (!unrestricted && epoch != access?.profileEpoch) {
        if (data is Map && data['session'] is String) {
          await release(data['session'] as String);
        }
        if (action == 'workLease' && input['command'] == 'start') {
          await workLease(input['jobId'] as String, 'end');
        }
        throw AppFailure('用户已切换，请重新操作');
      }
      return data is Map ? Map<String, dynamic>.from(data) : {};
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      if (input['session'] is String &&
          input['sequence'] is int &&
          {
            'catalog',
            'categories',
            'suggestions',
            'recommendations',
            'metadata',
            'danmaku',
            'preload',
            'prepareHandoff',
          }.contains(input['action'])) {
        unawaited(
          _call({
            'action': 'cancelRead',
            'session': input['session'],
            'sequence': input['sequence'],
          }).catchError((Object _) => <String, dynamic>{}),
        );
      }
      throw AppFailure('站源响应超时，请重试');
    } catch (error) {
      throw AppFailure('本地核心加载失败，请使用完整安装包重新安装（$error）');
    }
  }

  @override
  Future<void> initialize() async {
    final directory = await getApplicationSupportDirectory();
    final build = await _call({
      'action': 'initialize',
      'directory': directory.path,
    });
    if (build['allSources'] != allSourcesEnabled) {
      throw AppFailure('应用与原生核心的站源版本不一致，请使用完整安装包重新安装');
    }
    if (!background) await BackgroundDownloads.prepare();
    if (!background) {
      SystemProxyMonitor.start((value) async {
        await _call({'action': 'updateSystemProxy', 'systemProxy': value});
      });
    }
  }

  @override
  Future<List<CatalogCategory>> categories(
    String source, {
    bool force = false,
  }) async {
    final result = await _read('categories-$source', {
      'action': 'categories',
      'source': source,
      'force': force,
    });
    return [
      for (final row in result['items'] as List? ?? const [])
        CatalogCategory.fromJson(Map<String, dynamic>.from(row as Map)),
    ];
  }

  @override
  Future<CatalogPage> cached(String source, {String category = ''}) async {
    final result = CatalogPage.fromJson(
      await _call({
        'action': 'cached',
        'source': source,
        'category': category,
      }),
    );
    // 冷启动/切分类常走磁盘缓存直显（catalog() 不会被调），
    // 这里同样预取首屏剧详情，保证点卡零网络等待。
    if (result.items.isNotEmpty) {
      _prefetchQueue.clear();
      prefetchDetails(result.items.take(12));
    }
    return result;
  }
  @override
  Future<String> cover(Drama drama, {bool force = false}) async {
    final epoch = access?.profileEpoch;
    // 豆瓣条目：Dart 直下（EdgeOne 对 Go 指纹不友好），失败回落 Go 原路。
    if (DoubanCoverLoader.handles(drama.cover)) {
      final doubanPath = await DoubanCoverLoader.load(drama, force: force);
      if (doubanPath.isNotEmpty) {
        _authorize(drama.source);
        if (epoch != access?.profileEpoch) {
          throw AppFailure('用户已切换，请重新操作');
        }
        return doubanPath;
      }
    }
    final result = await _call({
      'action': 'cover',
      'drama': drama.toJson(),
      'force': force,
    });
    final file = result['path'] as String? ?? '';
    if (file.isEmpty) throw AppFailure('海报暂不可用');
    if (result['heic'] != true) return file;
    final converted = await _coverDecoder.convert(
      file,
      () => _call({'action': 'prepareCover', 'drama': drama.toJson()}),
      force: force,
    );
    _authorize(drama.source);
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return converted;
  }

  @override
  Future<DramaDetail> detail(Drama drama) => detailCached(
    drama,
    () async => DramaDetail.fromJson(
      await _call({'action': 'detail', 'drama': drama.toJson()}),
    ),
  );

  final _prefetchQueue = <Drama>[];
  bool _prefetchPumping = false;

  @override
  void prefetchDetail(Drama drama) => prefetchDetails([drama]);

  @override
  void prefetchDetails(Iterable<Drama> dramas) {
    for (final drama in dramas) {
      final key = _detailKey(drama);
      if (_detailCache.containsKey(key) || _detailPending.containsKey(key)) {
        continue;
      }
      _prefetchQueue.add(drama);
    }
    _pumpPrefetch();
  }

  /// 串行预取队列：不打爆桥与上游站源；失败静默，
  /// 真点按时启动页会正常走网络并给出错误 UI。
  void _pumpPrefetch() {
    if (_prefetchPumping) return;
    _prefetchPumping = true;
    unawaited(() async {
      try {
        while (_prefetchQueue.isNotEmpty) {
          final drama = _prefetchQueue.removeAt(0);
          try {
            await detail(drama);
          } catch (_) {}
        }
      } finally {
        _prefetchPumping = false;
      }
    }());
  }

  @override
  Future<CatalogPage> catalog(
    String source, {
    int page = 1,
    String query = '',
    String category = '',
    String sort = '',
    bool force = false,
  }) async {
    final result = CatalogPage.fromJson(
      await _read('catalog-$source', {
        'action': 'catalog',
        'source': source,
        'page': page,
        'query': query,
        'category': category,
        'sort': sort,
        'force': force,
      }),
    );
    // 目录首页加载完即预取首屏剧详情（搜索结果不预取）：
    // 用户点卡时详情大概率已在缓存，进播放零网络等待。
    if (page == 1 && query.isEmpty && result.items.isNotEmpty) {
      _prefetchQueue.clear();
      prefetchDetails(result.items.take(12));
    }
    return result;
  }
  @override
  Future<PlaybackPlan> resolve(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'sequence': ++_playbackSequence,
    }),
  );
  @override
  Future<PlaybackPlan> fallback(PlaybackPlan current) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'fallback',
          'session': current.session,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<PlaybackPlan> selectPlayback(PlaybackPlan current, int route) async =>
      PlaybackPlan.fromJson(
        await _call({
          'action': 'selectPlayback',
          'session': current.session,
          'route': route,
          'sequence': ++_playbackSequence,
        }),
      );
  @override
  Future<void> cancelPlayback() async {
    await _call({'action': 'cancelPlayback', 'sequence': ++_playbackSequence});
  }

  @override
  bool get supportsDownloads => access?.canDownload ?? true;

  @override
  Future<List<DownloadJob>> downloads() async {
    final result = await _call({'action': 'downloads'});
    return (result['jobs'] as List? ?? [])
        .whereType<Map>()
        .map((value) => DownloadJob.fromJson(Map<String, dynamic>.from(value)))
        .where(
          (job) =>
              SourceSite.isAvailable(job.drama.source) &&
              (access == null || access!.allowsSource(job.drama.source)),
        )
        .toList();
  }

  @override
  Future<int> enqueueDownloads(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<int> updateDownloadCollection(
    DramaDetail detail,
    List<Episode> episodes, {
    int quality = 0,
  }) async {
    _authorize(detail.drama.source, download: true);
    final epoch = access?.profileEpoch;
    await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    final result = await _call({
      'action': 'enqueueDownloads',
      'force': true,
      'drama': detail.drama.toJson(),
      'quality': quality,
      'entries': episodes
          .map((episode) => {'chapter': episode.raw, 'index': episode.number})
          .toList(),
    });
    return intValue(result['added']);
  }

  @override
  Future<DownloadBatchResult> controlDownloadBatch(
    String command,
    List<String> ids, {
    Map<String, String> expectedVersions = const {},
  }) async {
    _downloadPermission();
    final epoch = access?.profileEpoch;
    if (ids.isEmpty || ids.length > 500) throw AppFailure('每批请选择 1 至 500 个任务');
    final visible = (await downloads()).map((job) => job.id).toSet();
    if (ids.any((id) => !visible.contains(id))) {
      throw AppFailure('部分任务已删除或当前用户无权操作，请刷新');
    }
    if (command == 'resume') await BackgroundDownloads.ensureStarted();
    if (epoch != access?.profileEpoch) throw AppFailure('用户已切换，请重新操作');
    return DownloadBatchResult.fromJson(
      await _call({
        'action': 'controlDownloadBatch',
        'command': command,
        'jobIds': ids,
        if (expectedVersions.isNotEmpty) 'expectedVersions': expectedVersions,
      }),
    );
  }

  @override
  Future<void> controlDownloads(String command, {String id = ''}) async {
    _downloadPermission();
    if (command == 'resume' || command == 'resumeAll') {
      await BackgroundDownloads.ensureStarted();
    }
    if (access != null && !access!.profile.admin) {
      final visible = await downloads();
      if (command == 'pauseAll' || command == 'resumeAll') {
        for (final job in visible.where(
          (job) => command == 'pauseAll' ? job.active : job.resumable,
        )) {
          await _call({
            'action': 'controlDownloads',
            'command': command == 'pauseAll' ? 'pause' : 'resume',
            'jobId': job.id,
          });
        }
        return;
      }
      if (!visible.any((job) => job.id == id)) {
        throw AppFailure('当前用户没有此下载任务权限');
      }
    }
    await _call({
      'action': 'controlDownloads',
      'command': command,
      'jobId': id,
    });
  }

  @override
  Future<PlaybackPlan?> localPlayback(Drama drama, Episode episode) async {
    final result = await _call({
      'action': 'localPlayback',
      'drama': drama.toJson(),
      'index': episode.number,
    });
    if ((result['url'] as String? ?? '').isEmpty) return null;
    return PlaybackPlan.fromJson(result);
  }

  @override
  Future<PlaybackPlan> resolveOnline(
    Drama drama,
    Episode episode, {
    int quality = 0,
  }) async => PlaybackPlan.fromJson(
    await _call({
      'action': 'resolve',
      'drama': drama.toJson(),
      'chapter': episode.raw,
      'index': episode.number,
      'quality': quality,
      'force': true,
      'sequence': ++_playbackSequence,
    }),
  );

  @override
  Future<void> release(String session) async {
    if (session.isEmpty) {
      return;
    }
    try {
      await _call({'action': 'release', 'session': session});
    } catch (_) {}
  }
}
