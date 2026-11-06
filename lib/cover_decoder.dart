import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as path;

import 'core_bridge.dart';
import 'media_pipeline.dart';

class CoverDecoder {
  CoverDecoder({MediaExecutor Function()? createExecutor})
    : _createExecutor = createExecutor ?? FFmpegExecutor.new;
  final MediaExecutor Function() _createExecutor;
  final _pending = <String, Future<String>>{};

  /// HEIC 转码并发上限：单线程 ffmpeg 进程开销小，但串行会让排队的
  /// 屏幕内海报等满前面所有任务；3 路并发足够摊平积压又不挤爆低端机。
  static const _maxActive = 3;
  var _active = 0;
  final _waiting = <_DecodeTask>[];

  Future<String> convert(
    String original,
    Future<Map<String, dynamic>> Function() prepare, {
    bool force = false,
    bool priority = false,
  }) async {
    final stat = await File(original).stat();
    if (stat.type != FileSystemEntityType.file || stat.size <= 0) {
      throw AppFailure('海报缓存已失效，请重试');
    }
    final directory = Directory(
      path.join(path.dirname(original), 'compatible-v1'),
    );
    final key =
        '${path.basenameWithoutExtension(original)}-${stat.modified.microsecondsSinceEpoch}-${stat.size}';
    final target = File(path.join(directory.path, '$key.jpg'));
    if (!force && await _isJPEG(target)) {
      await target.setLastModified(DateTime.now());
      return target.path;
    }
    if (_pending.containsKey(key)) return _pending[key]!;
    if (_pending.length >= 96) throw AppFailure('海报正在处理，请稍后重试');
    final completer = Completer<String>();
    final task = _DecodeTask(key, original, target, prepare, completer);
    // 屏幕内的海报（priority）插到未启动队列最前，后台预取排尾
    if (priority) {
      _waiting.insert(0, task);
    } else {
      _waiting.add(task);
    }
    _pending[key] = completer.future;
    _pump();
    try {
      return await completer.future;
    } finally {
      if (identical(_pending[key], completer.future)) _pending.remove(key);
    }
  }

  void _pump() {
    while (_active < _maxActive && _waiting.isNotEmpty) {
      final task = _waiting.removeAt(0);
      _active++;
      unawaited(
        () async {
          try {
            task.completer.complete(await _convert(task.original, task.target, task.prepare));
          } catch (error, stack) {
            task.completer.completeError(error, stack);
          } finally {
            _active--;
            _pump();
          }
        }(),
      );
    }
  }

  Future<bool> _isJPEG(File file) async {
    try {
      final length = await file.length();
      if (length < 4 || length > 4 * 1024 * 1024) return false;
      final handle = await file.open();
      try {
        final header = await handle.read(3);
        return header.length == 3 &&
            header[0] == 255 &&
            header[1] == 216 &&
            header[2] == 255;
      } finally {
        await handle.close();
      }
    } on FileSystemException {
      return false;
    }
  }

  Future<String> _convert(
    String original,
    File target,
    Future<Map<String, dynamic>> Function() prepare,
  ) async {
    final prepared = await prepare();
    if (prepared['heic'] != true) {
      return prepared['path'] as String? ?? original;
    }
    final input = prepared['input'] as String? ?? '';
    if (input.isEmpty) throw AppFailure('海报格式转换失败，请重试');
    final intermediate = File('${target.path}.part');
    final executor = _createExecutor();
    Future<void>? work;
    try {
      await target.parent.create(recursive: true);
      final orientation = prepared['filters'] as String? ?? '';
      final filters = [
        if (orientation.isNotEmpty) orientation,
        "scale=w='min(800,iw)':h='min(800,ih)':force_original_aspect_ratio=decrease",
      ].join(',');
      work = executor.run([
        '-max_alloc',
        '67108864',
        '-threads',
        '1',
        '-f',
        'hevc',
        '-i',
        input,
        '-frames:v',
        '1',
        '-an',
        '-sn',
        '-vf',
        filters,
        '-filter_threads',
        '1',
        '-threads',
        '1',
        '-c:v',
        'mjpeg',
        '-pix_fmt',
        'yuvj420p',
        '-q:v',
        '3',
        '-f',
        'image2',
        intermediate.path,
      ]);
      await work.timeout(const Duration(seconds: 12));
      if (!await _isJPEG(intermediate)) throw AppFailure('海报转换未生成有效图片');
      if (await target.exists()) await target.delete();
      await intermediate.rename(target.path);
      await _prune(target.parent, target.path);
      return target.path;
    } on TimeoutException {
      await executor.cancel();
      try {
        await work?.timeout(const Duration(seconds: 5));
      } catch (_) {}
      throw AppFailure('海报转换超时，请重试');
    } finally {
      for (final file in [if (input != original) File(input), intermediate]) {
        try {
          if (await file.exists()) await file.delete();
        } on FileSystemException {
          continue;
        }
      }
    }
  }

  Future<void> _prune(Directory directory, String keep) async {
    final entries = <(File, FileStat)>[];
    var size = 0;
    await for (final entry in directory.list(followLinks: false)) {
      if (entry is! File) continue;
      final stat = await entry.stat();
      if (entry.path.endsWith('.part')) {
        if (DateTime.now().difference(stat.modified) >
            const Duration(minutes: 1)) {
          await entry.delete();
        }
      } else if (entry.path.endsWith('.jpg')) {
        entries.add((entry, stat));
        size += stat.size;
      }
    }
    entries.sort((a, b) => a.$2.modified.compareTo(b.$2.modified));
    var count = entries.length;
    for (final entry in entries) {
      if (count <= 128 && size <= 64 * 1024 * 1024) break;
      if (entry.$1.path == keep) continue;
      await entry.$1.delete();
      count--;
      size -= entry.$2.size;
    }
  }
}

class _DecodeTask {
  _DecodeTask(
    this.key,
    this.original,
    this.target,
    this.prepare,
    this.completer,
  );
  final String key;
  final String original;
  final File target;
  final Future<Map<String, dynamic>> Function() prepare;
  final Completer<String> completer;
}
