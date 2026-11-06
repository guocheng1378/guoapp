import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 只关闭系统输入法，不动焦点树。
///
/// 播放页自身有一个非文本的 `Focus(autofocus: true)`（遥控器/键盘导航要用），
/// 首帧兜底收键盘时不能 unfocus，否则会把播放页自己的焦点一起移走。
/// MIUI 上 `TextInput.hide` 偶发与转场帧内的 `TextInput.show` 乱序，故加
/// 超时兜底：即便平台通道没回包也不阻塞起播。
Future<void> hideTextInput() async {
  try {
    await SystemChannels.textInput
        .invokeMethod<void>('TextInput.hide')
        .timeout(const Duration(milliseconds: 300));
  } catch (_) {
    // 平台通道不可达（测试宿主/部分 ROM）：忽略，焦点清理仍是主路径。
  }
}

/// 起播前释放文本焦点并硬断编辑连接。
///
/// 搜索框 `autofocus: true` 常驻在栈底：薄壳 `opaque:false` 被
/// `pushReplacement` 弹掉时，FocusScope 会把焦点还给搜索框并再次
/// `TextInput.show`。因此「打开薄壳」与「真正进播放页」两个时机都要收口。
Future<void> dismissPlaybackTextInput({bool television = false}) async {
  if (television) return;
  FocusManager.instance.primaryFocus?.unfocus();
  await hideTextInput();
}
