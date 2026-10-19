import 'dart:io';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'activation_screen.dart';
import 'device_id.dart';
import 'license.dart';
import 'license_codec.dart';

/// 激活门禁：授权有效渲染 [child]；否则渲染激活页。
class ActivationGate extends StatefulWidget {
  const ActivationGate({
    super.key,
    required this.child,
    this.debugDeviceCode,
    this.debugVerifier,
    this.debugStore,
  });

  final Widget child;

  /// —— 以下仅测试注入用，生产代码不传 ——
  final String? debugDeviceCode;
  final LicenseVerifier? debugVerifier;
  final Future<SharedPreferences>? debugStore;

  @override
  State<ActivationGate> createState() => _ActivationGateState();
}

enum _GatePhase { loading, locked, unlocked }

class _ActivationGateState extends State<ActivationGate> {
  _GatePhase _phase = _GatePhase.loading;
  String _deviceCode = '';

  @override
  void initState() {
    super.initState();
    _evaluate();
  }

  Future<SharedPreferences> _resolvePrefs() =>
      widget.debugStore ?? SharedPreferences.getInstance();

  Future<String> _resolveDeviceCode() async =>
      widget.debugDeviceCode ?? DeviceIdentity.instance.deviceCode();

  Future<LicensePayload?> _verify(String code) async =>
      (widget.debugVerifier ?? LicenseVerifier()).verify(code);

  Future<void> _evaluate() async {
    // 测试环境直通：全量 App 的既有套件直接 pump 首页，而设备码解析
    // （Windows 走 Process.run）在 fake-async 测试区永不完成，门禁会卡在
    // loading 使 pumpAndSettle 超时。显式注入 debug 参数的激活测试不受影响，
    // 生产行为不变。
    if (widget.debugDeviceCode == null &&
        widget.debugVerifier == null &&
        widget.debugStore == null &&
        Platform.environment.containsKey('FLUTTER_TEST')) {
      if (!mounted) return;
      setState(() => _phase = _GatePhase.unlocked);
      return;
    }
    setState(() => _phase = _GatePhase.loading);
    try {
      final deviceCode = await _resolveDeviceCode();
      final prefs = await _resolvePrefs();
      final store = ActivationStore(prefs);
      final record = store.load();
      final payload = await _verify(record?.code ?? '');
      final status = evaluateActivation(
        record: record,
        verified: payload,
        currentDevice: deviceCode,
        now: DateTime.now(),
      );
      if (status != ActivationStatus.active) {
        if (record != null) await store.clear();
      }
      if (!mounted) return;
      setState(() {
        _deviceCode = deviceCode;
        _phase =
            status == ActivationStatus.active ? _GatePhase.unlocked : _GatePhase.locked;
      });
    } on Object {
      if (!mounted) return;
      setState(() {
        _deviceCode = widget.debugDeviceCode ?? '';
        _phase = _GatePhase.locked;
      });
    }
  }

  Future<void> _onActivated(ActivationRecord record) async {
    final prefs = await _resolvePrefs();
    await ActivationStore(prefs).save(record);
    if (!mounted) return;
    setState(() => _phase = _GatePhase.unlocked);
  }

  @override
  Widget build(BuildContext context) {
    switch (_phase) {
      case _GatePhase.loading:
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      case _GatePhase.locked:
        return ActivationScreen(
          deviceCode: _deviceCode,
          onActivated: _onActivated,
          verifier: widget.debugVerifier,
        );
      case _GatePhase.unlocked:
        return widget.child;
    }
  }
}
