import 'dart:convert';
import 'dart:io' show Platform;

import 'package:crypto/crypto.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_build.dart';
import 'app_layout.dart' show appVersion;
import 'core_bridge.dart';
import 'lan_sync_models.dart';
import 'local_store.dart';

/// 云备份默认地址（坚果云 WebDAV，上传前会自动创建目录）。
const cloudBackupDefaultUrl =
    'https://dav.jianguoyun.com/dav/duanju_backup/backup.json';

/// 自动备份最小间隔：切后台触发，但至少间隔这么久才会上传。
const cloudBackupAutoInterval = Duration(hours: 12);

/// WebDAV 云备份配置。
///
/// 凭据与备份进度只存本机独立键（[configKey]），不在 LocalSnapshot 的
/// 管辖范围内——备份内容不会包含它，恢复备份也不会覆盖它。
class CloudBackupConfig {
  final String url;
  final String username;
  final String password;
  final String backupPassword;
  final bool autoBackup;
  final DateTime? lastBackupAt;
  final String? lastBackupHash;

  const CloudBackupConfig({
    this.url = '',
    this.username = '',
    this.password = '',
    this.backupPassword = '',
    this.autoBackup = false,
    this.lastBackupAt,
    this.lastBackupHash,
  });

  bool get ready =>
      url.startsWith('http') &&
      url.contains('/dav/') &&
      username.isNotEmpty &&
      password.isNotEmpty &&
      backupPassword.isNotEmpty;

  CloudBackupConfig copyWith({
    String? url,
    String? username,
    String? password,
    String? backupPassword,
    bool? autoBackup,
    DateTime? lastBackupAt,
    String? lastBackupHash,
  }) => CloudBackupConfig(
    url: url ?? this.url,
    username: username ?? this.username,
    password: password ?? this.password,
    backupPassword: backupPassword ?? this.backupPassword,
    autoBackup: autoBackup ?? this.autoBackup,
    lastBackupAt: lastBackupAt ?? this.lastBackupAt,
    lastBackupHash: lastBackupHash ?? this.lastBackupHash,
  );

  factory CloudBackupConfig.fromJson(Object? value) {
    if (value is! Map) return const CloudBackupConfig();
    DateTime? parseTime(Object? raw) {
      if (raw is! String || raw.isEmpty) return null;
      return DateTime.tryParse(raw)?.toLocal();
    }

    return CloudBackupConfig(
      url: value['url'] is String ? value['url'] as String : '',
      username: value['username'] is String ? value['username'] as String : '',
      password: value['password'] is String ? value['password'] as String : '',
      backupPassword: value['backupPassword'] is String
          ? value['backupPassword'] as String
          : '',
      autoBackup: value['autoBackup'] == true,
      lastBackupAt: parseTime(value['lastBackupAt']),
      lastBackupHash: value['lastBackupHash'] is String
          ? value['lastBackupHash'] as String
          : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'url': url,
    'username': username,
    'password': password,
    'backupPassword': backupPassword,
    'autoBackup': autoBackup,
    if (lastBackupAt != null)
      'lastBackupAt': lastBackupAt!.toUtc().toIso8601String(),
    if (lastBackupHash != null) 'lastBackupHash': lastBackupHash,
  };
}

/// 备份文件携带的说明信息（不参与恢复校验）。
class CloudBackupMeta {
  final DateTime? exportedAt;
  final String platform;
  final String version;

  const CloudBackupMeta({
    this.exportedAt,
    this.platform = '',
    this.version = '',
  });

  factory CloudBackupMeta.fromJson(Object? value) {
    if (value is! Map) return const CloudBackupMeta();
    final raw = value['exportedAt'];
    return CloudBackupMeta(
      exportedAt: raw is String && raw.isNotEmpty
          ? DateTime.tryParse(raw)?.toLocal()
          : null,
      platform: value['platform'] is String ? value['platform'] as String : '',
      version: value['version'] is String ? value['version'] as String : '',
    );
  }
}

/// 一次待上传的备份体：content 为写入云端的 JSON 文本，hash 为内容指纹
/// （不含 meta，内容不变则 hash 不变，自动备份据此跳过重复上传）。
class CloudBackupBuilt {
  final String content;
  final String hash;
  final int profiles;
  final int size;

  const CloudBackupBuilt({
    required this.content,
    required this.hash,
    required this.profiles,
    required this.size,
  });
}

/// 从云端拉到的备份：meta 用于恢复前预览，data 是通过 validateBackup 的备份体。
class CloudBackupRemote {
  final CloudBackupMeta meta;
  final Map<String, dynamic> data;
  final int size;

  const CloudBackupRemote({
    required this.meta,
    required this.data,
    required this.size,
  });
}

/// 云备份服务：导出（exportBackup）→ Go 侧加密（PBKDF2 + AES-256-GCM）→
/// WebDAV 上传；下载 → 解密 → 覆盖恢复或仅合并当前用户追剧。
class CloudBackup {
  CloudBackup(this._preferences, this._repository);

  static const configKey = 'cloudBackupConfig.v1';

  final SharedPreferences _preferences;
  final AppRepository _repository;

  CloudBackupConfig load() {
    final raw = _preferences.getString(configKey);
    if (raw == null || raw.isEmpty) return const CloudBackupConfig();
    try {
      return CloudBackupConfig.fromJson(jsonDecode(raw));
    } on FormatException {
      return const CloudBackupConfig();
    }
  }

  Future<void> save(CloudBackupConfig config) =>
      _preferences.setString(configKey, jsonEncode(config.toJson()));

  Map<String, dynamic> _payload(CloudBackupConfig config, [String? data]) => {
    'url': config.url,
    'username': config.username,
    'password': config.password,
    'backupPassword': config.backupPassword,
    'data': ?data,
  };

  /// 探测服务器可达性与云端备份是否存在（不解密）。
  Future<Map<String, dynamic>> test(CloudBackupConfig config) =>
      _repository.webdav('test', _payload(config));

  Map<String, dynamic> _meta() => {
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'platform': Platform.operatingSystem,
    'version': '$appVersion${allSourcesEnabled ? '（全源）' : ''}',
  };

  /// 构建全量备份体：LocalStore.exportBackup（全部用户、追剧、历史与设置）
  /// 外加 meta。hash 基于不含 meta 的原始备份体计算。
  Future<CloudBackupBuilt> build(LocalStore store) async {
    final base = await store.exportBackup();
    final data = store.validateBackup(base);
    final profiles = data['profiles'] is List
        ? (data['profiles'] as List).length
        : 0;
    data['meta'] = _meta();
    final content = jsonEncode(data);
    return CloudBackupBuilt(
      content: content,
      hash: sha256.convert(utf8.encode(base)).toString(),
      profiles: profiles,
      size: content.length,
    );
  }

  /// 立即备份（无条件上传）。
  Future<CloudBackupBuilt> backupNow(
    LocalStore store, {
    CloudBackupConfig? config,
  }) async {
    final target = config ?? load();
    if (!target.ready) throw AppFailure('请先填写服务器地址与账号');
    final built = await build(store);
    final result = await _repository.webdav('upload', _payload(target, built.content));
    if (result['ok'] != true) throw AppFailure('上传失败，请检查网络后重试');
    await save(
      target.copyWith(lastBackupAt: DateTime.now(), lastBackupHash: built.hash),
    );
    return built;
  }

  /// 自动备份：默认关闭；切后台触发；内容无变化或间隔不足 12 小时则跳过。
  /// 失败静默——后台动作不弹错打扰用户。
  Future<bool> maybeAutoBackup(LocalStore store) async {
    try {
      final config = load();
      if (!config.autoBackup || !config.ready) return false;
      if (store.locked) return false;
      final base = await store.exportBackup();
      final hash = sha256.convert(utf8.encode(base)).toString();
      if (config.lastBackupHash == hash) return false;
      final last = config.lastBackupAt;
      if (last != null &&
          DateTime.now().difference(last) < cloudBackupAutoInterval) {
        return false;
      }
      final data = store.validateBackup(base);
      data['meta'] = _meta();
      final result = await _repository.webdav(
        'upload',
        _payload(config, jsonEncode(data)),
      );
      if (result['ok'] != true) return false;
      await save(
        config.copyWith(lastBackupAt: DateTime.now(), lastBackupHash: hash),
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 拉取并解密云端备份。云端还没有备份时返回 null。
  Future<CloudBackupRemote?> fetch(
    CloudBackupConfig config,
    LocalStore store,
  ) async {
    final result = await _repository.webdav('download', _payload(config));
    if (result['exists'] != true) return null;
    final content = result['data'];
    if (content is! String || content.isEmpty) {
      throw AppFailure('云端备份内容为空');
    }
    Object? raw;
    try {
      raw = jsonDecode(content);
    } on FormatException {
      throw AppFailure('云端备份格式无效');
    }
    if (raw is! Map) throw AppFailure('云端备份格式无效');
    final meta = CloudBackupMeta.fromJson(raw.remove('meta'));
    final data = store.validateBackup(jsonEncode(raw));
    return CloudBackupRemote(meta: meta, data: data, size: content.length);
  }

  /// 覆盖本机：云端备份整体恢复（全部用户、追剧、历史与设置）。
  Future<void> restoreReplace(LocalStore store, CloudBackupRemote remote) =>
      store.importBackup(jsonEncode(remote.data));

  /// 合并追剧：仅把云端记录与当前用户按 LAN 同款字段级三向语义合并，
  /// 云端记录里本机不允许的源会被跳过，其他用户的档不受影响。
  Future<LanChangeCount> restoreMergeFollow(
    LocalStore store,
    CloudBackupRemote remote,
  ) {
    final libraries = remote.data['libraries'];
    final profile = libraries is Map
        ? libraries[store.profile.id]
        : null;
    final sync = profile is Map ? profile['followSync'] : null;
    final records = <LanRecord>[];
    if (sync is List) {
      for (final row in sync) {
        try {
          records.add(LanRecord.fromJson(row));
        } catch (_) {
          // 单条无效记录跳过，不阻断整体恢复。
        }
      }
    }
    return store.mergeCloudRecords(records);
  }
}
