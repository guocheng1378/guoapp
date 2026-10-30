import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// 剧库重键（收藏/历史/追剧状态等大块数据）的本地文件读写缝。
///
/// 重键自 SharedPreferences 单一大 blob（localSnapshot.v1）迁出为独立文件后，
/// LocalSnapshot 通过此抽象读写文件；测试可注入 [MemorySnapshotFiles] 或
/// 指向临时目录的 [DirectorySnapshotFiles]。
abstract class SnapshotFiles {
  const SnapshotFiles();

  /// 文件层是否已就绪。未就绪时 LocalSnapshot 走纯 blob 的降级路径
  /// （与旧版行为一致，重键暂留 blob），避免加载竞态丢数据。
  bool get isReady => true;

  /// 同步加载全部重键：键名 -> 值字符串（JSON 文本，已解压）。
  ///
  /// 目录不存在返回空表；单个文件损坏时跳过该文件（不抛出、不阻塞应用），
  /// 该键回落为 blob 中的旧值。
  Map<String, String> loadAll();

  /// gzip 压缩 + 原子写单个重键（临时文件 + rename）。
  Future<void> write(String key, String json);

  /// 删除重键文件（profile 删除 / 备份恢复 replace 路径）。
  Future<void> delete(String key);
}

const String kSnapshotFileSuffix = '.json.gz';
const List<int> _kGzipMagic = [0x1f, 0x8b];

/// 键文件内容解码：gzip 魔数（1F 8B）则解压，否则按明文 UTF-8 回退
/// （兼容迁移窗口期可能落盘的未压缩写入）。
String decodeSnapshotFileBytes(List<int> bytes) {
  if (bytes.length >= 2 &&
      bytes[0] == _kGzipMagic[0] &&
      bytes[1] == _kGzipMagic[1]) {
    return utf8.decode(gzip.decode(bytes));
  }
  return utf8.decode(bytes);
}

String snapshotFileName(String key) => '$key$kSnapshotFileSuffix';

/// 真实文件实现：`<应用支持目录>/library/<完整键名>.json.gz`。
///
/// 支持目录建议在构造 LocalStore 前解析好：
/// - 直接传 [directory]（main.dart / 后台下载 isolate 构造点）；
/// - 或对默认实例调用 [warmUp] 预取。
/// 未就绪时 [isReady] 为 false，LocalSnapshot 自动降级走纯 blob。
class DirectorySnapshotFiles extends SnapshotFiles {
  DirectorySnapshotFiles({Directory? directory})
      : _override = directory,
        _resolved = directory == null ? null : _withLibrary(directory);

  static Directory _withLibrary(Directory base) =>
      Directory('${base.path}${Platform.pathSeparator}library');

  final Directory? _override;
  Directory? _resolved;
  Future<void>? _warming;

  @override
  bool get isReady => _resolved != null;

  /// 解析并缓存存储目录。幂等；解析失败不抛出（保持未就绪，下次重试）。
  Future<void> warmUp({Directory? directory}) {
    if (_resolved != null) return Future.value();
    final dir = directory ?? _override;
    if (dir != null) {
      _resolved = _withLibrary(dir);
      return Future.value();
    }
    return _warming ??= getApplicationSupportDirectory().then((support) {
      _resolved = _withLibrary(support);
    }).catchError((Object _) {
      _warming = null; // 解析失败：保持未就绪，下次再试
    });
  }

  @override
  Map<String, String> loadAll() {
    final dir = _resolved;
    if (dir == null) return const {};
    if (!dir.existsSync()) return const {};
    final result = <String, String>{};
    for (final entity in dir.listSync()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (!name.endsWith(kSnapshotFileSuffix)) continue;
      final key = name.substring(0, name.length - kSnapshotFileSuffix.length);
      if (key.isEmpty) continue;
      try {
        result[key] = decodeSnapshotFileBytes(entity.readAsBytesSync());
      } catch (_) {
        // 单个文件损坏：跳过，不让一个文件拖垮整个应用。
      }
    }
    return result;
  }

  @override
  Future<void> write(String key, String json) async {
    final dir = await _ensureDirectory();
    final file = File('${dir.path}${Platform.pathSeparator}${snapshotFileName(key)}');
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(gzip.encode(utf8.encode(json)), flush: true);
    try {
      await tmp.rename(file.path);
    } catch (_) {
      try {
        await tmp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> delete(String key) async {
    final dir = _resolved;
    if (dir == null) return;
    final file = File('${dir.path}${Platform.pathSeparator}${snapshotFileName(key)}');
    if (await file.exists()) {
      await file.delete();
    }
  }

  Future<Directory> _ensureDirectory() async {
    var dir = _resolved;
    if (dir == null) {
      await warmUp();
      dir = _resolved;
    }
    if (dir == null) throw StateError('本地存储目录不可用');
    if (!dir.existsSync()) {
      await dir.create(recursive: true);
    }
    return dir;
  }
}

/// 内存实现：测试注入用；需要跨 LocalStore 实例（模拟重启）持久时，
/// 由测试持有同一实例分别传入。
class MemorySnapshotFiles extends SnapshotFiles {
  MemorySnapshotFiles({Map<String, String>? initial})
      : _data = Map.of(initial ?? const {});

  final Map<String, String> _data;

  int get length => _data.length;
  bool containsKey(String key) => _data.containsKey(key);

  @override
  Map<String, String> loadAll() => Map.of(_data);

  @override
  Future<void> write(String key, String json) async {
    _data[key] = json;
  }

  @override
  Future<void> delete(String key) async {
    _data.remove(key);
  }
}

/// 默认文件实现：测试环境（flutter test）一律用内存实现，
/// 避免测试触碰真实存储；生产环境用目录实现（惰性解析，需 warmUp）。
SnapshotFiles createDefaultSnapshotFiles({Directory? directory}) {
  if (directory == null && Platform.environment.containsKey('FLUTTER_TEST')) {
    return MemorySnapshotFiles();
  }
  return DirectorySnapshotFiles(directory: directory);
}
