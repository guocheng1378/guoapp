import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'license_codec.dart';

/// 设备标识：Android 取 ANDROID_ID（同签名重装不变），Windows 取 MachineGuid。
/// 无平台标识时降级为本地随机码（首次生成后固定）。
class DeviceIdentity {
  const DeviceIdentity._(this._rawIdProvider);

  static const DeviceIdentity instance = DeviceIdentity._(null);

  factory DeviceIdentity({Future<String?> Function()? rawIdProvider}) =>
      DeviceIdentity._(rawIdProvider);

  static const _channel = MethodChannel('duanju/device');
  static const _fallbackKey = 'activation.device.fallback.v1';

  final Future<String?> Function()? _rawIdProvider;

  /// 平台原始设备标识；不可得返回 null。
  Future<String?> rawId() async {
    if (_rawIdProvider != null) {
      try {
        return await _rawIdProvider();
      } on Object {
        return null;
      }
    }
    try {
      if (Platform.isAndroid) {
        return await _channel.invokeMethod<String>('androidId');
      }
      if (Platform.isWindows) {
        final result = await Process.run('reg', [
          'query',
          r'HKLM\SOFTWARE\Microsoft\Cryptography',
          '/v',
          'MachineGuid',
        ]);
        if (result.exitCode == 0) {
          final match = RegExp(
            r'REG_SZ\s+(\S+)',
          ).firstMatch(result.stdout.toString());
          if (match != null) return match.group(1);
        }
      }
    } on Object {
      // 平台能力缺失时走随机兜底
    }
    return null;
  }

  /// 设备码：sha256('ZGJ-DEVICE-v1|' + rawId) 前 6 字节 → base32 10 位。
  Future<String> deviceCode() async {
    var raw = await rawId();
    if (raw == null || raw.isEmpty) raw = await _fallbackId();
    final digest = sha256.convert(utf8.encode('ZGJ-DEVICE-v1|$raw'));
    final encoded = LicenseCodec.base32Encode(digest.bytes.sublist(0, 6));
    return encoded.substring(0, LicenseCodec.deviceCodeLength);
  }

  Future<String> _fallbackId() async {
    final prefs = await SharedPreferences.getInstance();
    final existing = prefs.getString(_fallbackKey);
    if (existing != null) return existing;
    final random = List<int>.generate(16, (_) => Random.secure().nextInt(256));
    final id = LicenseCodec.base32Encode(random).substring(0, 20);
    await prefs.setString(_fallbackKey, id);
    return id;
  }
}
