import 'package:duanju_app/app_orientation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 锁屏的方向锁定：锁定期间旋转物理设备画面不得跟随，
/// 解锁（或交还播放权）后必须恢复跟随，否则整个 App 的方向会被锁死。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // SystemChrome.setPreferredOrientations 的参数是朝向名字列表
  // （portraitUp / landscapeLeft …）。
  late List<List<String>> calls;

  setUp(() {
    calls = <List<String>>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'SystemChrome.setPreferredOrientations') {
        calls.add(List<String>.from(call.arguments as List));
        // 该方法的返回值约定是 List<String>（被隐藏的系统 UI 模式），
        // 不能回 null，否则 decodeEnvelope 会抛类型错误。
        return <String>[];
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('锁屏把方向钉住，解锁后恢复跟随', () async {
    final controller = AppOrientationController(television: false);
    addTearDown(controller.dispose);

    await controller.setPlayback(
      'owner',
      fullscreen: true,
      aspectRatio: 1,
      forceLandscape: true,
    );
    expect(
      calls.last.map((e) => e.split('.').last),
      containsAll(<String>['landscapeLeft', 'landscapeRight']),
      reason: '横屏全屏时允许左右两个横屏朝向',
    );

    await controller.lockOrientations(const [DeviceOrientation.landscapeLeft]);
    expect(
      calls.last.map((e) => e.split('.').last),
      <String>['landscapeLeft'],
      reason: '锁定后只允许锁定的朝向，旋转设备画面不再跟随',
    );

    await controller.lockOrientations(null);
    expect(
      calls.last.map((e) => e.split('.').last),
      containsAll(<String>['landscapeLeft', 'landscapeRight']),
      reason: '解锁后恢复跟随',
    );
  });

  test('交还播放权时一并松开方向锁', () async {
    final controller = AppOrientationController(television: false);
    addTearDown(controller.dispose);

    await controller.setPlayback('owner', fullscreen: true, aspectRatio: 1);
    await controller.lockOrientations(const [DeviceOrientation.portraitUp]);
    await controller.releasePlayback('owner');

    expect(
      calls.last.map((e) => e.split('.').last),
      containsAll(<String>['portraitUp', 'portraitDown']),
      reason: '离开播放页不能把整个 App 的方向锁住',
    );
  });
}
