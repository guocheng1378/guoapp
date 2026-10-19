import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activation_screen.dart';
import 'device_id.dart';
import 'license.dart';

/// 设备码解析：测试注入优先；FLUTTER_TEST 且未注入时返回占位码——
/// Windows 的真实解析走 Process.run，在 fake-async 测试区永不完成
/// （与 ActivationGate 的测试直通同一坑），占位码让全量 App 测试
/// 也能走到激活页 UI。
Future<String> _resolveDeviceCode(String? debugDeviceCode) async {
  if (debugDeviceCode != null) return debugDeviceCode;
  if (Platform.environment.containsKey('FLUTTER_TEST')) {
    return 'FLUTTERTEST';
  }
  return DeviceIdentity.instance.deviceCode();
}

Future<SharedPreferences> _resolvePrefs(
  Future<SharedPreferences>? debugStore,
) => debugStore ?? SharedPreferences.getInstance();

/// 设备当前是否处于有效激活状态：读本地记录并重新验签（与门禁同判定）。
/// [debugDeviceCode]/[debugVerifier]/[debugStore] 仅测试注入用。
Future<bool> activationActive({
  String? debugDeviceCode,
  LicenseVerifier? debugVerifier,
  Future<SharedPreferences>? debugStore,
}) async {
  try {
    final prefs = await _resolvePrefs(debugStore);
    final record = ActivationStore(prefs).load();
    if (record == null) return false;
    final payload =
        await (debugVerifier ?? LicenseVerifier()).verify(record.code);
    final deviceCode = await _resolveDeviceCode(debugDeviceCode);
    return evaluateActivation(
          record: record,
          verified: payload,
          currentDevice: deviceCode,
          now: DateTime.now(),
        ) ==
        ActivationStatus.active;
  } on Object {
    return false;
  }
}

/// 弹出激活页（不做状态判断，调用方自行决定是否先查激活态）。
/// 返回本次访问中是否完成了新的激活。
///
/// 记录由本函数落盘——激活页自身不持久化，此前只有门禁会保存；
/// 门禁移除后这里是主要激活路径，不落盘等于重启即丢激活。
/// [onActivated] 在验签通过当下回调。
/// [debugDeviceCode]/[debugVerifier]/[debugStore] 仅测试注入用。
Future<bool> showActivationPage(
  BuildContext context, {
  ValueChanged<ActivationRecord>? onActivated,
  String? debugDeviceCode,
  LicenseVerifier? debugVerifier,
  Future<SharedPreferences>? debugStore,
}) async {
  final prefs = await _resolvePrefs(debugStore);
  final record = ActivationStore(prefs).load();
  final deviceCode = await _resolveDeviceCode(debugDeviceCode);
  if (!context.mounted) return false;
  var activated = false;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => ActivationScreen(
        deviceCode: deviceCode,
        record: record,
        onActivated: (record) {
          activated = true;
          unawaited(_persist(record, debugStore));
          onActivated?.call(record);
        },
        verifier: debugVerifier,
      ),
    ),
  );
  return activated;
}

Future<void> _persist(
  ActivationRecord record,
  Future<SharedPreferences>? debugStore,
) async {
  try {
    final prefs = await _resolvePrefs(debugStore);
    await ActivationStore(prefs).save(record);
  } on Object {
    // 落盘失败不阻断激活 UI；记录仍在当次会话内生效。
  }
}
