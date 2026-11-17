import 'package:duanju_app/player_interactions.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'player_fixtures.dart';

/// 竖屏全屏竖滑切集的「跟手」契约：拖动全程画面位移跟着手指走、不碰
/// 播放器状态；松手跨阈值才切一次集，松手后画面回正。
void main() {
  test('竖滑切集：拖动跟手不切集，松手才切一次且画面回正', () {
    final player = Player(platformPlayer: ScriptedPlayer());
    var switches = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onEpisode: (direction) {
        switches++;
        return direction > 0 ? '下一集' : '上一集';
      },
    );
    addTearDown(interactions.dispose);

    interactions.pointerDown(
      const PointerDownEvent(
        pointer: 1,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        position: Offset(200, 400),
      ),
      swipeEnabled: true,
      width: 400,
      height: 800,
    );

    // 小幅上滑：还没到切集阈值，画面就已经跟着手指移动。
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(200, 340)),
    );
    final small = interactions.episodeDrag.value;
    expect(small, greaterThan(0), reason: '拖动中画面必须跟手');
    expect(switches, 0, reason: '拖动中换集会打断手势、画面当场弹回');

    // 继续上滑越过 20% 屏高：位移继续增大，但仍不提前切集。
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(200, 180)),
    );
    final large = interactions.episodeDrag.value;
    expect(large, greaterThan(small));
    expect(switches, 0);

    // 同一次手势内继续滑：位移被阻尼上限夹住，仍不连跳。
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 1, position: Offset(200, 80)),
    );
    expect(interactions.episodeDrag.value, greaterThanOrEqualTo(large));
    expect(switches, 0, reason: '一次手势只允许切一次集');

    interactions.pointerUp(
      const PointerUpEvent(pointer: 1, position: Offset(200, 80)),
    );
    expect(switches, 1, reason: '松手跨阈值才提交换集');
    expect(interactions.episodeDrag.value, 0, reason: '松手后画面回正');
  });

  test('没滑够阈值：松手不切集', () {
    final player = Player(platformPlayer: ScriptedPlayer());
    var switches = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onEpisode: (direction) {
        switches++;
        return '下一集';
      },
    );
    addTearDown(interactions.dispose);

    interactions.pointerDown(
      const PointerDownEvent(
        pointer: 3,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        position: Offset(200, 400),
      ),
      swipeEnabled: true,
      width: 400,
      height: 800,
    );
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 3, position: Offset(200, 330)),
    );
    expect(interactions.episodeDrag.value, greaterThan(0));
    interactions.pointerUp(
      const PointerUpEvent(pointer: 3, position: Offset(200, 330)),
    );
    expect(switches, 0);
    expect(interactions.episodeDrag.value, 0);
  });

  test('边界竖滑改橡皮筋：位移被压到 8% 屏高以内且不切集', () {
    final player = Player(platformPlayer: ScriptedPlayer());
    var switches = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      episodeAvailable: (direction) => false,
      onEpisode: (direction) {
        switches++;
        return '已经是最后一集';
      },
    );
    addTearDown(interactions.dispose);

    interactions.pointerDown(
      const PointerDownEvent(
        pointer: 2,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        position: Offset(200, 400),
      ),
      swipeEnabled: true,
      width: 400,
      height: 800,
    );
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 2, position: Offset(200, 100)),
    );
    expect(interactions.episodeDrag.value, greaterThan(0));
    expect(interactions.episodeDrag.value, lessThanOrEqualTo(800 * 0.08));
    interactions.pointerUp(
      const PointerUpEvent(pointer: 2, position: Offset(200, 100)),
    );
    expect(switches, 0);
    expect(interactions.episodeDrag.value, 0);
  });

  test('拖动中反向回拖：方向锁不翻转，松手也不误切上一集', () {
    final player = Player(platformPlayer: ScriptedPlayer());
    var switches = 0;
    final interactions = PlayerInteractions(
      player: player,
      available: () => true,
      baseSpeed: () => 1,
      onTogglePlayback: () {},
      onEpisode: (direction) {
        switches++;
        return direction > 0 ? '下一集' : '上一集';
      },
    );
    addTearDown(interactions.dispose);

    interactions.pointerDown(
      const PointerDownEvent(
        pointer: 4,
        kind: PointerDeviceKind.touch,
        buttons: kPrimaryButton,
        position: Offset(200, 400),
      ),
      swipeEnabled: true,
      width: 400,
      height: 800,
    );
    // 先上滑锁定「下一集」，再一路回拖到起点以下。
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 4, position: Offset(200, 200)),
    );
    expect(interactions.episodeDrag.value, greaterThan(0));
    interactions.pointerMove(
      const PointerMoveEvent(pointer: 4, position: Offset(200, 520)),
    );
    expect(interactions.episodeDrag.value, 0, reason: '回拖只收位移，不翻方向');
    interactions.pointerUp(
      const PointerUpEvent(pointer: 4, position: Offset(200, 520)),
    );
    expect(switches, 0);
  });
}
