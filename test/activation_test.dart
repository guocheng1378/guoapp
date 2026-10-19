import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:duanju_app/activation/activation_flow.dart';
import 'package:duanju_app/activation/activation_gate.dart';
import 'package:duanju_app/activation/activation_screen.dart';
import 'package:duanju_app/activation/license.dart';
import 'package:duanju_app/activation/license_codec.dart';
import 'package:duanju_app/activation/qq_launch.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _device = 'ABCDE23456';
const _otherDevice = 'ZZZZZZZZZZ';

Future<(Ed25519, SimpleKeyPair, String)> _testKey() async {
  final algo = Ed25519();
  final pair = await algo.newKeyPairFromSeed(List<int>.filled(32, 7));
  final pub = await pair.extractPublicKey();
  return (algo, pair, base64Encode(pub.bytes));
}

/// 用测试私钥按与 Go 工具相同的格式签出授权码。
Future<String> _signCode(
  Ed25519 algo,
  SimpleKeyPair pair,
  String device,
  int days,
) async {
  final payload = LicenseCodec.buildPayload(device, days);
  final sig = await algo.sign(payload, keyPair: pair);
  return LicenseCodec.base32Encode([...payload, ...sig.bytes]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('LicenseCodec base32', () {
    test('RFC4648 known vectors', () {
      final vectors = <String, String>{
        '': '',
        'f': 'MY',
        'fo': 'MZXQ',
        'foo': 'MZXW6',
        'foob': 'MZXW6YQ',
        'fooba': 'MZXW6YTB',
        'foobar': 'MZXW6YTBOI',
      };
      vectors.forEach((input, want) {
        expect(LicenseCodec.base32Encode(utf8.encode(input)), want, reason: input);
        expect(utf8.decode(LicenseCodec.base32Decode(want)!), input, reason: want);
      });
    });

    test('roundtrip random bytes', () {
      final bytes = List<int>.generate(200, (i) => (i * 37 + 11) % 256);
      final decoded = LicenseCodec.base32Decode(LicenseCodec.base32Encode(bytes));
      expect(decoded, bytes);
    });

    test('decode rejects non-alphabet chars', () {
      expect(LicenseCodec.base32Decode('ABC0EFGH'), isNull);
      expect(LicenseCodec.base32Decode('ABC1EFGH'), isNull);
      expect(LicenseCodec.base32Decode('ABC8EFGH'), isNull);
      expect(LicenseCodec.base32Decode('ABC9EFGH'), isNull);
    });
  });

  group('LicenseCodec formatting', () {
    test('normalizeCode strips separators and lower case', () {
      expect(LicenseCodec.normalizeCode('abcd-efghi-jklmn '), 'ABCDEFGHIJKLMN');
    });

    test('formatCode groups by 5', () {
      expect(LicenseCodec.formatCode('abcdefghij'), 'ABCDE-FGHIJ');
      expect(LicenseCodec.formatCode('abcde-fghij-klmno'), 'ABCDE-FGHIJ-KLMNO');
      expect(LicenseCodec.formatCode('abcdef'), 'ABCDE-F');
    });

    test('formatDevice displays ZGJ prefix', () {
      expect(LicenseCodec.formatDevice(_device), 'ZGJ-ABCDE-23456');
      expect(LicenseCodec.formatDevice('SHORT'), 'SHORT');
    });

    test('parseDevice accepts display format and raw code', () {
      expect(LicenseCodec.parseDevice('ZGJ-ABCDE-23456'), _device);
      expect(LicenseCodec.parseDevice('abcde23456'), _device);
      expect(LicenseCodec.parseDevice('ABCDE2 3456'), _device);
      expect(LicenseCodec.parseDevice('ABC'), isNull);
      expect(LicenseCodec.parseDevice('ABC0EFGH2J'), isNull);
    });

    test('buildPayload format matches Go tool', () {
      expect(
        utf8.decode(LicenseCodec.buildPayload(_device, 0)),
        'ZGJV1|$_device|0',
      );
      expect(
        utf8.decode(LicenseCodec.buildPayload(_device, 365)),
        'ZGJV1|$_device|365',
      );
      expect(() => LicenseCodec.buildPayload('BAD', 1), throwsArgumentError);
      expect(() => LicenseCodec.buildPayload(_device, -1), throwsArgumentError);
    });

    test('splitCode rejects malformed input', () {
      expect(LicenseCodec.splitCode(''), isNull);
      expect(LicenseCodec.splitCode('ABC'), isNull);
      // 63 字节载荷 + 无签名 = 过短
      final tooShort = utf8.encode('ZGJV1|$_device|0');
      expect(LicenseCodec.splitCode(LicenseCodec.base32Encode(tooShort)), isNull);
    });

    test('parsePayload validates fields', () {
      final payload = utf8.encode('ZGJV1|$_device|90');
      final parsed = LicenseCodec.parsePayload(payload);
      expect(parsed?.device, _device);
      expect(parsed?.durationDays, 90);
      expect(parsed?.isPermanent, isFalse);
      expect(LicenseCodec.parsePayload(utf8.encode('XXXX|$_device|90')), isNull);
      expect(LicenseCodec.parsePayload(utf8.encode('ZGJV1|BAD|90')), isNull);
      expect(LicenseCodec.parsePayload(utf8.encode('ZGJV1|$_device|-3')), isNull);
    });
  });

  group('LicenseVerifier', () {
    test('verifies well-formed codes and rejects tampering', () async {
      final (algo, pair, pubB64) = await _testKey();
      final verifier = LicenseVerifier(publicKeyB64: pubB64);

      final code = await _signCode(algo, pair, _device, 30);
      final payload = await verifier.verify(code);
      expect(payload?.device, _device);
      expect(payload?.durationDays, 30);

      // 展示格式（连字符）同样可验
      expect((await verifier.verify(LicenseCodec.formatCode(code)))?.device,
          _device);

      // 篡改一个字符
      final tampered = code.replaceFirst(code[0], code[0] == 'A' ? 'B' : 'A');
      expect(await verifier.verify(tampered), isNull);

      // 错误公钥
      final wrongPair = await algo.newKeyPairFromSeed(List<int>.filled(32, 9));
      final wrongPub = await wrongPair.extractPublicKey();
      final wrongVerifier =
          LicenseVerifier(publicKeyB64: base64Encode(wrongPub.bytes));
      expect(await wrongVerifier.verify(code), isNull);

      // 空输入与空公钥
      expect(await verifier.verify(''), isNull);
      expect(await LicenseVerifier(publicKeyB64: '').verify(code), isNull);
    });
  });

  group('evaluateActivation', () {
    final verified =
        const LicensePayload(device: _device, durationDays: 365);
    final activated = DateTime.utc(2026, 1, 1, 12);
    final record = ActivationRecord(
      code: 'CODE',
      device: _device,
      durationDays: 365,
      activatedAtMs: activated.millisecondsSinceEpoch,
      expiresAtMs: activated.millisecondsSinceEpoch +
          365 * Duration.millisecondsPerDay,
    );

    test('no record -> notActivated', () {
      expect(
        evaluateActivation(
          record: null,
          verified: verified,
          currentDevice: _device,
          now: activated,
        ),
        ActivationStatus.notActivated,
      );
    });

    test('verification failure -> tampered', () {
      expect(
        evaluateActivation(
          record: record,
          verified: null,
          currentDevice: _device,
          now: activated,
        ),
        ActivationStatus.tampered,
      );
    });

    test('foreign device -> deviceMismatch', () {
      expect(
        evaluateActivation(
          record: record,
          verified: verified,
          currentDevice: _otherDevice,
          now: activated,
        ),
        ActivationStatus.deviceMismatch,
      );
    });

    test('record/payload mismatch -> tampered', () {
      expect(
        evaluateActivation(
          record: record,
          verified: const LicensePayload(device: _device, durationDays: 30),
          currentDevice: _device,
          now: activated,
        ),
        ActivationStatus.tampered,
      );
    });

    test('permanent -> active', () {
      const permanent = LicensePayload(device: _device, durationDays: 0);
      final permanentRecord = ActivationRecord(
        code: 'CODE',
        device: _device,
        durationDays: 0,
        activatedAtMs: activated.millisecondsSinceEpoch,
        expiresAtMs: 0,
      );
      expect(
        evaluateActivation(
          record: permanentRecord,
          verified: permanent,
          currentDevice: _device,
          now: activated.add(const Duration(days: 100 * 365)),
        ),
        ActivationStatus.active,
      );
    });

    test('time card without expiry -> tampered', () {
      final broken = ActivationRecord(
        code: 'CODE',
        device: _device,
        durationDays: 365,
        activatedAtMs: activated.millisecondsSinceEpoch,
        expiresAtMs: 0,
      );
      expect(
        evaluateActivation(
          record: broken,
          verified: verified,
          currentDevice: _device,
          now: activated,
        ),
        ActivationStatus.tampered,
      );
    });

    test('clock rollback beyond tolerance -> clockRollback', () {
      expect(
        evaluateActivation(
          record: record,
          verified: verified,
          currentDevice: _device,
          now: activated.subtract(const Duration(days: 3)),
        ),
        ActivationStatus.clockRollback,
      );
      // 容忍窗口内（例如重启时钟漂移）不误伤
      expect(
        evaluateActivation(
          record: record,
          verified: verified,
          currentDevice: _device,
          now: activated.subtract(const Duration(hours: 24)),
        ),
        ActivationStatus.active,
      );
    });

    test('expiry boundary -> expired then active just before', () {
      final expiresAt = DateTime.fromMillisecondsSinceEpoch(
        record.expiresAtMs,
      );
      expect(
        evaluateActivation(
          record: record,
          verified: verified,
          currentDevice: _device,
          now: expiresAt.subtract(const Duration(minutes: 1)),
        ),
        ActivationStatus.active,
      );
      expect(
        evaluateActivation(
          record: record,
          verified: verified,
          currentDevice: _device,
          now: expiresAt.add(const Duration(minutes: 1)),
        ),
        ActivationStatus.expired,
      );
    });
  });

  group('ActivationRecord serialization', () {
    test('json roundtrip', () {
      final record = ActivationRecord(
        code: 'CODE',
        device: _device,
        durationDays: 30,
        activatedAtMs: 1000,
        expiresAtMs: 86,
      );
      final restored = ActivationRecord.fromJson(record.toJson());
      expect(restored?.code, 'CODE');
      expect(restored?.device, _device);
      expect(restored?.durationDays, 30);
      expect(restored?.activatedAtMs, 1000);
      expect(restored?.expiresAtMs, 86);
    });

    test('rejects malformed json', () {
      expect(ActivationRecord.fromJson(null), isNull);
      expect(ActivationRecord.fromJson('str'), isNull);
      expect(ActivationRecord.fromJson({'code': 'C'}), isNull);
      expect(
        ActivationRecord.fromJson({
          'code': 'C',
          'device': _device,
          'duration': -1,
          'activatedAt': 1,
          'expiresAt': 2,
        }),
        isNull,
      );
      expect(
        ActivationRecord.fromJson({
          'code': 'C',
          'device': _device,
          'duration': 30,
          'activatedAt': 1,
          'expiresAt': 0,
        }),
        isNull,
      );
    });
  });

  group('ActivationStore', () {
    test('save/load/clear', () async {
      SharedPreferences.setMockInitialValues({});
      final store = ActivationStore(await SharedPreferences.getInstance());
      expect(store.load(), isNull);
      final record = ActivationRecord(
        code: 'CODE',
        device: _device,
        durationDays: 0,
        activatedAtMs: 1000,
        expiresAtMs: 0,
      );
      await store.save(record);
      expect(store.load()?.code, 'CODE');
      await store.clear();
      expect(store.load(), isNull);
    });
  });

  group('activateWithCode', () {
    test('builds permanent and timed records', () async {
      final (algo, pair, pubB64) = await _testKey();
      final verifier = LicenseVerifier(publicKeyB64: pubB64);
      final now = DateTime.utc(2026, 10, 19, 8);

      final permanentCode = await _signCode(algo, pair, _device, 0);
      final permanent =
          await activateWithCode(code: permanentCode, currentDevice: _device, now: now, verifier: verifier);
      expect(permanent.record?.expiresAtMs, 0);
      expect(permanent.error, isNull);

      final timedCode = await _signCode(algo, pair, _device, 30);
      final timed =
          await activateWithCode(code: timedCode, currentDevice: _device, now: now, verifier: verifier);
      expect(
        timed.record?.expiresAtMs,
        now.millisecondsSinceEpoch + 30 * Duration.millisecondsPerDay,
      );

      final foreignCode = await _signCode(algo, pair, _otherDevice, 0);
      final foreign =
          await activateWithCode(code: foreignCode, currentDevice: _device, now: now, verifier: verifier);
      expect(foreign.record, isNull);
      expect(foreign.error, contains('其他设备'));

      final bad =
          await activateWithCode(code: 'NOT-A-CODE', currentDevice: _device, now: now, verifier: verifier);
      expect(bad.record, isNull);
      expect(bad.error, isNotNull);
    });
  });

  group('remainingDays', () {
    test('permanent is null; timed counts up and clamps at 0', () {
      final record = ActivationRecord(
        code: 'C',
        device: _device,
        durationDays: 10,
        activatedAtMs: 0,
        expiresAtMs: 10 * Duration.millisecondsPerDay,
      );
      expect(record.isPermanent, isFalse);
      expect(record.remainingDays(DateTime.fromMillisecondsSinceEpoch(0)), 10);
      expect(
        record.remainingDays(
          DateTime.fromMillisecondsSinceEpoch(
            10 * Duration.millisecondsPerDay + 1,
          ),
        ),
        0,
      );
      final permanent = ActivationRecord(
        code: 'C',
        device: _device,
        durationDays: 0,
        activatedAtMs: 0,
        expiresAtMs: 0,
      );
      expect(permanent.isPermanent, isTrue);
      expect(permanent.remainingDays(DateTime.now()), isNull);
    });
  });

  group('ActivationScreen seller contact', () {
    const deviceChannel = MethodChannel('duanju/device');

    test('kSellerContact filled with QQ number', () {
      expect(kSellerContact, contains('963484350'));
      expect(qqNumberFrom(kSellerContact), '963484350');
    });

    testWidgets('tap opens QQ via device channel', (tester) async {
      debugIsWindows = false; // 测试主机是 Windows，强制走通道分支
      addTearDown(() => debugIsWindows = null);
      Object? uin;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        deviceChannel,
        (call) async {
          if (call.method == 'openQQ') {
            uin = (call.arguments as Map)['uin'];
            return true;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceChannel, null),
      );

      await tester.pumpWidget(
        const MaterialApp(home: ActivationScreen(deviceCode: _device)),
      );

      await tester.tap(find.text(kSellerContact));
      await tester.pump();

      expect(uin, '963484350');
      expect(find.text('正在打开 QQ...'), findsOneWidget);
    });

    testWidgets('tap falls back to copy when QQ unavailable', (tester) async {
      debugIsWindows = false;
      addTearDown(() => debugIsWindows = null);
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        deviceChannel,
        (call) async => false,
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceChannel, null),
      );

      await tester.pumpWidget(
        const MaterialApp(home: ActivationScreen(deviceCode: _device)),
      );

      await tester.tap(find.text(kSellerContact));
      await tester.pump();

      // 复制分支的专属提示（剪贴板内容即 sellerContact，代码直接传值）
      expect(find.text('未检测到 QQ，已复制联系方式'), findsOneWidget);
    });

    testWidgets('copy button copies without launching QQ', (tester) async {
      debugIsWindows = false;
      addTearDown(() => debugIsWindows = null);
      var openQQCalled = false;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        deviceChannel,
        (call) async {
          if (call.method == 'openQQ') openQQCalled = true;
          return false;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger
            .setMockMethodCallHandler(deviceChannel, null),
      );

      await tester.pumpWidget(
        const MaterialApp(home: ActivationScreen(deviceCode: _device)),
      );

      await tester.tap(
        find.descendant(
          of: find.byType(ListTile),
          matching: find.byIcon(Icons.copy),
        ),
      );
      await tester.pump();

      expect(openQQCalled, isFalse);
      expect(find.text('联系方式已复制'), findsOneWidget);
    });

    testWidgets('hidden when contact empty', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: ActivationScreen(deviceCode: _device, sellerContact: ''),
        ),
      );

      expect(find.byType(ListTile), findsNothing);
    });
  });

  group('ActivationGate widget', () {
    testWidgets('locks without record, unlocks with valid code', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (algo, pair, pubB64) = await _testKey();
      final code = await _signCode(algo, pair, _device, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: ActivationGate(
            debugDeviceCode: _device,
            debugVerifier: LicenseVerifier(publicKeyB64: pubB64),
            debugStore: SharedPreferences.getInstance(),
            child: const Text('UNLOCKED-HOME'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // 未激活：显示激活页，主页不可见
      expect(find.text('UNLOCKED-HOME'), findsNothing);
      expect(find.byType(TextField), findsOneWidget);

      // 输入展示格式授权码并激活
      await tester.enterText(find.byType(TextField), LicenseCodec.formatCode(code));
      await tester.tap(find.text('激活'));
      await tester.pumpAndSettle();

      expect(find.text('UNLOCKED-HOME'), findsOneWidget);
    });

    testWidgets('shows device-mismatch error and stays locked', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (algo, pair, pubB64) = await _testKey();
      final code = await _signCode(algo, pair, _otherDevice, 0);

      await tester.pumpWidget(
        MaterialApp(
          home: ActivationGate(
            debugDeviceCode: _device,
            debugVerifier: LicenseVerifier(publicKeyB64: pubB64),
            debugStore: SharedPreferences.getInstance(),
            child: const Text('UNLOCKED-HOME'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), code);
      await tester.tap(find.text('激活'));
      await tester.pumpAndSettle();

      expect(find.text('该授权码绑定的是其他设备'), findsOneWidget);
      expect(find.text('UNLOCKED-HOME'), findsNothing);
    });

    testWidgets('rejects invalid code and stays locked', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final (_, _, pubB64) = await _testKey();

      await tester.pumpWidget(
        MaterialApp(
          home: ActivationGate(
            debugDeviceCode: _device,
            debugVerifier: LicenseVerifier(publicKeyB64: pubB64),
            debugStore: SharedPreferences.getInstance(),
            child: const Text('UNLOCKED-HOME'),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'AAAAA-BBBBB-CCCCC');
      await tester.tap(find.text('激活'));
      await tester.pumpAndSettle();

      expect(find.text('授权码无效，请核对后重试'), findsOneWidget);
      expect(find.text('UNLOCKED-HOME'), findsNothing);
    });
  });

  group('activation flow helpers', () {
    test('activationActive reflects stored record state', () async {
      SharedPreferences.setMockInitialValues({});
      final (algo, pair, pubB64) = await _testKey();
      final verifier = LicenseVerifier(publicKeyB64: pubB64);
      final code = await _signCode(algo, pair, _device, 30);
      final prefs = await SharedPreferences.getInstance();

      Future<bool> check() => activationActive(
            debugDeviceCode: _device,
            debugVerifier: verifier,
            debugStore: SharedPreferences.getInstance(),
          );

      // 无记录 → 未激活
      expect(await check(), isFalse);

      // 有效记录（30 天未到期）→ 已激活
      final now = DateTime.now();
      await ActivationStore(prefs).save(ActivationRecord(
        code: code,
        device: _device,
        durationDays: 30,
        activatedAtMs: now.millisecondsSinceEpoch,
        expiresAtMs:
            now.millisecondsSinceEpoch + 30 * Duration.millisecondsPerDay,
      ));
      expect(await check(), isTrue);

      // 已过期（激活时间前移使 expiresAt 落在过去）→ 未激活
      await ActivationStore(prefs).save(ActivationRecord(
        code: code,
        device: _device,
        durationDays: 30,
        activatedAtMs:
            now.millisecondsSinceEpoch - 40 * Duration.millisecondsPerDay,
        expiresAtMs:
            now.millisecondsSinceEpoch - 10 * Duration.millisecondsPerDay,
      ));
      expect(await check(), isFalse);

      // 其他设备签发的码 → 未激活（deviceMismatch）
      final otherCode = await _signCode(algo, pair, _otherDevice, 0);
      await ActivationStore(prefs).save(ActivationRecord(
        code: otherCode,
        device: _otherDevice,
        durationDays: 0,
        activatedAtMs: now.millisecondsSinceEpoch,
        expiresAtMs: 0,
      ));
      expect(await check(), isFalse);
    });

    testWidgets(
      'showActivationPage persists record and reports activation',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final (algo, pair, pubB64) = await _testKey();
        final code = await _signCode(algo, pair, _device, 0);
        var hostStatus = '';

        // 宿主用状态文本而非 SnackBar：fake-async 下 SnackBar 的
        // 4 秒消失 timer 永不触发，后续 SnackBar 会被排队不显示。
        await tester.pumpWidget(
          MaterialApp(
            home: StatefulBuilder(
              builder: (context, setState) => Scaffold(
                body: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      FilledButton(
                        onPressed: () async {
                          final activated = await showActivationPage(
                            context,
                            debugDeviceCode: _device,
                            debugVerifier:
                                LicenseVerifier(publicKeyB64: pubB64),
                          );
                          setState(() {
                            hostStatus =
                                activated ? 'ACTIVATED' : 'NOT-ACTIVATED';
                          });
                        },
                        child: const Text('open'),
                      ),
                      Text(hostStatus),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );

        // 打开激活页，直接返回 → 未激活、无记录落盘。
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        expect(find.byType(ActivationScreen), findsOneWidget);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('NOT-ACTIVATED'), findsOneWidget);
        final prefs = await SharedPreferences.getInstance();
        expect(ActivationStore(prefs).load(), isNull);

        // 再次打开，输入有效授权码 → 激活成功、记录落盘、返回值 true。
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), code);
        await tester.tap(find.text('激活'));
        await tester.pumpAndSettle();
        expect(find.text('授权码无效，请核对后重试'), findsNothing);
        final prefs2 = await SharedPreferences.getInstance();
        expect(ActivationStore(prefs2).load()?.device, _device);
        await tester.pageBack();
        await tester.pumpAndSettle();
        expect(find.text('ACTIVATED'), findsOneWidget);
      },
    );
  });
}
