import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_codec.dart';
import 'license_pubkey.dart';

/// 授权判定结果。
enum ActivationStatus {
  /// 未激活（无本地记录）。
  notActivated,

  /// 授权码验签失败或本地记录与签名不符（记录已清除）。
  tampered,

  /// 授权码不属于当前设备（记录已清除）。
  deviceMismatch,

  /// 时间卡到期。
  expired,

  /// 检测到系统时间倒流（记录已清除）。
  clockRollback,

  /// 授权有效。
  active,
}

/// 本地存储的激活记录。
class ActivationRecord {
  const ActivationRecord({
    required this.code,
    required this.device,
    required this.durationDays,
    required this.activatedAtMs,
    required this.expiresAtMs,
  });

  /// 授权码（normalize 后）。
  final String code;

  /// 激活时设备码（10 位）。
  final String device;

  /// 授权天数，0 = 永久。
  final int durationDays;

  /// 激活时刻（毫秒 epoch，本地钟）。
  final int activatedAtMs;

  /// 到期时刻（毫秒 epoch），永久 = 0。
  final int expiresAtMs;

  Map<String, Object?> toJson() => {
        'code': code,
        'device': device,
        'duration': durationDays,
        'activatedAt': activatedAtMs,
        'expiresAt': expiresAtMs,
      };

  static ActivationRecord? fromJson(Object? data) {
    if (data is! Map) return null;
    final code = data['code'];
    final device = data['device'];
    final duration = data['duration'];
    final activatedAt = data['activatedAt'];
    final expiresAt = data['expiresAt'];
    if (code is! String ||
        device is! String ||
        duration is! int ||
        activatedAt is! int ||
        expiresAt is! int) {
      return null;
    }
    if (duration < 0 || activatedAt <= 0 || (duration > 0 && expiresAt <= 0)) {
      return null;
    }
    return ActivationRecord(
      code: code,
      device: device,
      durationDays: duration,
      activatedAtMs: activatedAt,
      expiresAtMs: expiresAt,
    );
  }
}

/// Ed25519 验签器。公钥默认取 license_pubkey.dart 常量，测试可注入。
class LicenseVerifier {
  LicenseVerifier({String? publicKeyB64})
      : publicKeyB64 = publicKeyB64 ?? licensePublicKeyB64;

  final String publicKeyB64;

  static final Ed25519 _algo = Ed25519();

  /// 验签并解析载荷；非法返回 null。
  Future<LicensePayload?> verify(String normalizedCode) async {
    if (publicKeyB64.isEmpty || normalizedCode.isEmpty) return null;
    final parts = LicenseCodec.splitCode(normalizedCode);
    if (parts == null) return null;
    final (payloadBytes, sigBytes) = parts;
    try {
      final pubBytes = base64Decode(publicKeyB64);
      final ok = await _algo.verify(
        payloadBytes,
        signature: Signature(
          sigBytes,
          publicKey: SimplePublicKey(pubBytes, type: KeyPairType.ed25519),
        ),
      );
      if (!ok) return null;
      return LicenseCodec.parsePayload(payloadBytes);
    } on Object {
      return null;
    }
  }
}

/// 本地授权记录存取（独立于 LocalStore 配置体系：清配置不清授权）。
class ActivationStore {
  ActivationStore(this._prefs);

  static const _key = 'activation.license.v1';

  final SharedPreferences _prefs;

  ActivationRecord? load() {
    try {
      final raw = _prefs.getString(_key);
      if (raw == null) return null;
      return ActivationRecord.fromJson(jsonDecode(raw));
    } on Object {
      return null;
    }
  }

  Future<void> save(ActivationRecord record) =>
      _prefs.setString(_key, jsonEncode(record.toJson()));

  Future<void> clear() => _prefs.remove(_key);
}

/// 系统时间倒流容忍窗口：早于激活时刻超过该值视为改表。
const clockRollbackTolerance = Duration(hours: 48);

/// 纯判定逻辑：本地记录 + 验签结果 + 当前设备码 → 状态。
ActivationStatus evaluateActivation({
  required ActivationRecord? record,
  required LicensePayload? verified,
  required String currentDevice,
  required DateTime now,
}) {
  if (record == null) return ActivationStatus.notActivated;
  if (verified == null) return ActivationStatus.tampered;
  if (verified.device != currentDevice) return ActivationStatus.deviceMismatch;
  if (record.device != verified.device ||
      record.durationDays != verified.durationDays) {
    return ActivationStatus.tampered;
  }
  if (verified.isPermanent) return ActivationStatus.active;
  final expiresAtMs = record.expiresAtMs;
  if (expiresAtMs <= 0) return ActivationStatus.tampered;
  final nowMs = now.millisecondsSinceEpoch;
  if (nowMs < record.activatedAtMs - clockRollbackTolerance.inMilliseconds) {
    return ActivationStatus.clockRollback;
  }
  if (nowMs > expiresAtMs) return ActivationStatus.expired;
  return ActivationStatus.active;
}

/// 激活尝试结果：record 非 null 即成功；error 为面向用户的失败原因。
class ActivationAttempt {
  const ActivationAttempt({this.record, this.error});

  final ActivationRecord? record;
  final String? error;
}

/// 激活校验入口：验签 + 设备比对 + 建立本地记录。供激活页与门禁共用。
Future<ActivationAttempt> activateWithCode({
  required String code,
  required String currentDevice,
  required DateTime now,
  LicenseVerifier? verifier,
}) async {
  final payload = await (verifier ?? LicenseVerifier()).verify(code);
  if (payload == null) {
    return const ActivationAttempt(error: '授权码无效，请核对后重试');
  }
  if (payload.device != currentDevice) {
    return const ActivationAttempt(error: '该授权码绑定的是其他设备');
  }
  final activatedAtMs = now.millisecondsSinceEpoch;
  final expiresAtMs = payload.isPermanent
      ? 0
      : activatedAtMs + payload.durationDays * Duration.millisecondsPerDay;
  return ActivationAttempt(
    record: ActivationRecord(
      code: code,
      device: currentDevice,
      durationDays: payload.durationDays,
      activatedAtMs: activatedAtMs,
      expiresAtMs: expiresAtMs,
    ),
  );
}

/// 已激活记录的展示辅助。
extension ActivationRecordX on ActivationRecord {
  bool get isPermanent => durationDays == 0;

  /// 剩余天数（向上取整）；永久返回 null。
  int? remainingDays(DateTime now) {
    if (isPermanent) return null;
    final remain =
        expiresAtMs - now.millisecondsSinceEpoch;
    if (remain <= 0) return 0;
    return (remain / Duration.millisecondsPerDay).ceil();
  }
}
