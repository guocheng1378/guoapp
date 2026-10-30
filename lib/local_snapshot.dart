import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'local_snapshot_files.dart';

class LocalSnapshot {
  LocalSnapshot(this.preferences, {SnapshotFiles? files})
    : files = files ?? createDefaultSnapshotFiles() {
    reloadValues();
  }
  LocalSnapshot.empty(this.preferences, {SnapshotFiles? files})
    : files = files ?? createDefaultSnapshotFiles() {
    // 损坏恢复路径只登记既有重键文件（供 replace 提交时清理孤儿文件），
    // 不读 blob——blob 已确认损坏。注意用 this.files 取字段：
    // 参数名在构造体内会遮蔽字段。
    final snapshotFiles = this.files;
    if (snapshotFiles.isReady) {
      _fileKeys.addAll(
        snapshotFiles.loadAll().keys.where(
          (key) => owns(key) && isHeavyKey(key),
        ),
      );
    }
  }

  static const storageKey = 'localSnapshot.v1';
  static const libraryKeys = {
    'history',
    'favorites',
    'followStates',
    'followChecks',
    'seriesCandidates',
    'mediaHistory',
    'source',
    'hideVip',
    'playback',
    'downloadPreferences',
    'catalogView',
    'recentSearches',
    'lanRecords',
    'lanSettings',
    'lanReceipts',
    'skipMarks',
  };

  /// 迁出为本地文件的大块剧库键（默认档为顶层键，其余档为
  /// `profile.<id>.<键名>`）。剩余轻键与全局键继续留在 blob。
  static const heavyLibraryKeys = {
    'history',
    'favorites',
    'followStates',
    'followChecks',
    'seriesCandidates',
    'mediaHistory',
    'lanRecords',
    'lanReceipts',
    'skipMarks',
  };

  static const globalKeys = {
    'profiles',
    'activeProfile',
    'displayMode',
    'themeMode',
    'autoExport',
    'exportPosters',
    'forceLogin',
    'restrictedUnlocked',
    'dongpiandiOfficialOnly',
    'sourceSwitches',
    'liveSources',
    'customSources',
  };
  final SharedPreferences preferences;
  final SnapshotFiles files;
  Map<String, Object> _values = {};

  /// 权威内容落在文件层的重键集合（与文件系统对齐，随加载/提交维护）。
  final Set<String> _fileKeys = {};

  static bool owns(String key) =>
      globalKeys.contains(key) ||
      libraryKeys.contains(key) ||
      RegExp(
        r'^profile\.[a-zA-Z0-9_-]{1,64}\.(history|favorites|followStates|followChecks|seriesCandidates|mediaHistory|source|hideVip|playback|downloadPreferences|catalogView|recentSearches|lanRecords|lanSettings|lanReceipts|skipMarks)$',
      ).hasMatch(key);

  /// 是否为需要落文件的重键（默认档顶层键或 profile 档键）。
  static bool isHeavyKey(String key) {
    if (heavyLibraryKeys.contains(key)) return true;
    if (!key.startsWith('profile.')) return false;
    final dot = key.lastIndexOf('.');
    return dot > 'profile.'.length &&
        heavyLibraryKeys.contains(key.substring(dot + 1));
  }

  Map<String, Object> get values => Map.of(_values);
  String? getString(String key) => _values[key] as String?;
  bool? getBool(String key) => _values[key] as bool?;

  void reloadValues() {
    final raw = preferences.getString(storageKey);
    if (raw == null) {
      final values = {
        for (final key in preferences.getKeys().where(owns))
          key: preferences.get(key)!,
      };
      _mergeFileLayer(values);
      _validate(values);
      _values = values;
      return;
    }
    final decoded = jsonDecode(raw) as Map;
    if (decoded['version'] != 1 || decoded['values'] is! Map) {
      throw const FormatException('本地配置快照无效');
    }
    final values = Map<String, Object>.from(decoded['values'] as Map);
    if (!values.containsKey('profiles')) {
      throw const FormatException('本地配置快照无效');
    }
    _mergeFileLayer(values);
    _validate(values);
    _values = values;
  }

  /// 文件层合并：同键文件优先于 blob（文件是重键的权威存储）。
  /// 文件层未就绪（目录尚未解析）时跳过——此时保持纯 blob 的旧语义，
  /// 提交路径会把重键继续留在 blob，待就绪后由下一次提交迁移。
  void _mergeFileLayer(Map<String, Object> values) {
    _fileKeys.clear();
    if (!files.isReady) return;
    final loaded = files.loadAll();
    for (final entry in loaded.entries) {
      if (!owns(entry.key) || !isHeavyKey(entry.key)) continue;
      values[entry.key] = entry.value;
    }
    _fileKeys.addAll(loaded.keys.where((key) => owns(key) && isHeavyKey(key)));
  }

  void _validate(Map<String, Object> values) {
    for (final entry in values.entries) {
      final boolean = {
        'hideVip',
        'autoExport',
        'exportPosters',
        'forceLogin',
        'restrictedUnlocked',
        'dongpiandiOfficialOnly',
      }.contains(entry.key.split('.').last);
      if (!owns(entry.key) ||
          (boolean ? entry.value is! bool : entry.value is! String)) {
        throw const FormatException('本地配置字段无效');
      }
    }
  }

  Future<bool> _restore(Object? value) => switch (value) {
    null => preferences.remove(storageKey),
    String value => preferences.setString(storageKey, value),
    bool value => preferences.setBool(storageKey, value),
    int value => preferences.setInt(storageKey, value),
    double value => preferences.setDouble(storageKey, value),
    List<String> value => preferences.setStringList(storageKey, value),
    _ => Future.value(false),
  };

  Future<void> commit(Map<String, Object> values) async {
    if (values.keys.any((key) => !owns(key))) throw StateError('无效的本地配置字段');
    final ready = files.isReady;

    // 重键 diff（values 为完整期望状态：新增/变更/删除/replace 全覆盖）。
    final fileWrites = <String, String>{};
    final fileDeletes = <String>{};
    if (ready) {
      for (final entry in values.entries) {
        if (!isHeavyKey(entry.key)) continue;
        if (_values[entry.key] == entry.value) continue;
        fileWrites[entry.key] = entry.value as String;
      }
      // 权威内容已不在期望状态里的重键 → 删文件（profile 删除、备份恢复、
      // 记录清空共用此路径）。
      for (final key in _fileKeys) {
        if (!values.containsKey(key)) fileDeletes.add(key);
      }
      // 迁移：仍在 blob/内存但尚未落文件的重键，随本次提交一并迁出
      // （幂等——已在文件层的键不会重复写）。
      for (final entry in _values.entries) {
        if (!isHeavyKey(entry.key) || !values.containsKey(entry.key)) continue;
        if (fileWrites.containsKey(entry.key) || _fileKeys.contains(entry.key)) {
          continue;
        }
        fileWrites[entry.key] = entry.value as String;
      }
    }

    // blob 只装轻键与全局键；文件层未就绪时保持旧语义（重键随 blob 落盘）。
    final blobValues = ready
        ? {
            for (final entry in values.entries)
              if (!isHeavyKey(entry.key)) entry.key: entry.value,
          }
        : values;
    final content = jsonEncode({'version': 1, 'values': blobValues});
    final limit = ready ? 2 * 1024 * 1024 : 16 * 1024 * 1024;
    if (utf8.encode(content).length > limit) {
      throw StateError('本地记录超过保存上限，请先导出备份并清理记录');
    }

    final previous = preferences.get(storageKey);
    final doneWrites = <String>[];
    final doneDeletes = <String>[];
    try {
      // 先文件后 blob：文件写失败时 blob 未动；blob 写失败时文件可回滚。
      for (final entry in fileWrites.entries) {
        await files.write(entry.key, entry.value);
        doneWrites.add(entry.key);
      }
      for (final key in fileDeletes) {
        await files.delete(key);
        doneDeletes.add(key);
      }
      if (!await preferences.setString(storageKey, content)) {
        throw StateError('本地配置未能保存');
      }
    } catch (_) {
      await _rollbackFiles(doneWrites, doneDeletes);
      try {
        await preferences.reload();
        if (preferences.get(storageKey) != previous) {
          final restored = await _restore(previous);
          if (!restored) throw StateError('无法恢复原配置');
          await preferences.reload();
          if (preferences.get(storageKey) != previous) {
            throw StateError('无法恢复原配置');
          }
        }
      } catch (_) {
        throw const SnapshotRecoveryRequired();
      }
      throw StateError('未能保存，原有记录已保留；请检查存储空间和权限后重试');
    }
    _values = Map.of(values);
    if (ready) {
      _fileKeys.removeAll(fileDeletes);
      _fileKeys.addAll(fileWrites.keys);
    }
  }

  /// 把本批已执行的文件操作恢复到提交前状态；恢复失败静默吞掉
  /// （上层按 blob 回滚结果决定是否抛 SnapshotRecoveryRequired）。
  Future<void> _rollbackFiles(
    List<String> doneWrites,
    List<String> doneDeletes,
  ) async {
    for (final key in doneWrites) {
      try {
        final previousValue = _fileKeys.contains(key)
            ? _values[key]
            : null;
        if (previousValue is String) {
          await files.write(key, previousValue);
        } else {
          await files.delete(key);
        }
      } catch (_) {}
    }
    for (final key in doneDeletes) {
      try {
        final previousValue = _values[key];
        if (previousValue is String) await files.write(key, previousValue);
      } catch (_) {}
    }
  }
}

class SnapshotRecoveryRequired implements Exception {
  const SnapshotRecoveryRequired();
  @override
  String toString() => '无法确认本地配置保存结果，已锁定访问；请重新读取配置或恢复备份';
}
