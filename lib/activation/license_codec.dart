import 'dart:convert';
import 'dart:typed_data';

/// 授权码编解码与载荷格式（与 tools/licensegen Go 工具保持一致）。
///
/// 载荷: `ZGJV1|{设备码10位}|{天数0=永久}`
/// 授权码: base32(payload字节 || ed25519签名64字节)，展示时每 5 字符一组连字符分隔。
class LicenseCodec {
  LicenseCodec._();

  static const payloadVersion = 'ZGJV1';
  static const signatureBytes = 64;
  static const deviceCodeLength = 10;
  static const _alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';

  static final RegExp _deviceRe = RegExp(r'^[A-Z2-7]{10}$');

  /// 清洗授权码：去连字符/空白、转大写。
  static String normalizeCode(String input) {
    final buffer = StringBuffer();
    for (final rune in input.toUpperCase().runes) {
      final ch = String.fromCharCode(rune);
      if (_alphabet.contains(ch)) buffer.write(ch);
    }
    return buffer.toString();
  }

  /// 展示格式：每 5 字符一组连字符分隔。
  static String formatCode(String code) {
    final clean = normalizeCode(code);
    final groups = <String>[];
    for (var i = 0; i < clean.length; i += 5) {
      groups.add(clean.substring(i, i + 5 > clean.length ? clean.length : i + 5));
    }
    return groups.join('-');
  }

  /// 设备码展示格式: ZGJ-XXXXX-XXXXX
  static String formatDevice(String deviceCode) {
    if (deviceCode.length != deviceCodeLength) return deviceCode;
    return 'ZGJ-${deviceCode.substring(0, 5)}-${deviceCode.substring(5)}';
  }

  /// 从任意粘贴内容解析设备码：去连字符/前缀，校验 10 位。
  static String? parseDevice(String input) {
    var clean = normalizeCode(input);
    if (clean.length == 13 && clean.startsWith('ZGJ')) {
      clean = clean.substring(3);
    }
    if (!_deviceRe.hasMatch(clean)) return null;
    return clean;
  }

  /// 构造待签载荷。
  static Uint8List buildPayload(String deviceCode, int durationDays) {
    if (!_deviceRe.hasMatch(deviceCode)) {
      throw ArgumentError.value(deviceCode, 'deviceCode', '设备码须为 10 位 base32');
    }
    if (durationDays < 0) {
      throw ArgumentError.value(durationDays, 'durationDays', '天数不能为负');
    }
    return utf8.encode('$payloadVersion|$deviceCode|$durationDays');
  }

  /// 拆分授权码为 载荷 + 签名；编码非法返回 null。
  static (Uint8List, Uint8List)? splitCode(String code) {
    final raw = base32Decode(normalizeCode(code));
    if (raw == null || raw.length <= signatureBytes) return null;
    final split = raw.length - signatureBytes;
    return (
      Uint8List.sublistView(raw, 0, split),
      Uint8List.sublistView(raw, split),
    );
  }

  /// 解析载荷文本；版本/格式不识别返回 null。
  static LicensePayload? parsePayload(List<int> bytes) {
    final text = utf8.decode(bytes, allowMalformed: false);
    final parts = text.split('|');
    if (parts.length != 3 || parts[0] != payloadVersion) return null;
    if (!_deviceRe.hasMatch(parts[1])) return null;
    final days = int.tryParse(parts[2]);
    if (days == null || days < 0) return null;
    return LicensePayload(device: parts[1], durationDays: days);
  }

  /// base32（RFC4648 A-Z2-7 无 padding）编码；输入非表内字符返回 null。
  static Uint8List? base32Decode(String input) {
    var bits = 0;
    var value = 0;
    final out = BytesBuilder();
    for (final rune in input.runes) {
      final ch = String.fromCharCode(rune);
      final index = _alphabet.indexOf(ch);
      if (index < 0) return null;
      value = (value << 5) | index;
      bits += 5;
      if (bits >= 8) {
        out.addByte((value >> (bits - 8)) & 0xff);
        bits -= 8;
      }
    }
    return out.toBytes();
  }

  static String base32Encode(List<int> bytes) {
    var bits = 0;
    var value = 0;
    final out = StringBuffer();
    for (final byte in bytes) {
      value = (value << 8) | (byte & 0xff);
      bits += 8;
      while (bits >= 5) {
        out.write(_alphabet[(value >> (bits - 5)) & 31]);
        bits -= 5;
      }
    }
    if (bits > 0) out.write(_alphabet[(value << (5 - bits)) & 31]);
    return out.toString();
  }
}

/// 授权码载荷中的业务字段。
class LicensePayload {
  const LicensePayload({required this.device, required this.durationDays});

  /// 设备码（10 位 base32）。
  final String device;

  /// 授权天数，0 = 永久。
  final int durationDays;

  bool get isPermanent => durationDays == 0;
}
