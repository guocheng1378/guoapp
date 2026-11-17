import 'package:flutter/material.dart';

import 'floating_card.dart';

/// 敏感操作的管理员口令输入（覆盖恢复 / 损坏态导出 / 云端覆盖）。
///
/// 返回 null 表示用户取消。与 profiles_screen 的登录弹窗同语义，但独立成
/// 公共入口，避免设置页/云备份页各自复制一份。
Future<String?> showAdminPinDialog(
  BuildContext context, {
  String title = '需要管理员密码',
  String message = '',
}) {
  final controller = TextEditingController();
  final future = showFloatingDialog<String>(
    context: context,
    barrierLabel: title,
    title: Text(title),
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (message.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(message, style: const TextStyle(fontSize: 12)),
          ),
        TextField(
          key: const ValueKey('admin-pin-input'),
          controller: controller,
          obscureText: true,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '管理员密码',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (value) => Navigator.pop(context, value),
        ),
      ],
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        key: const ValueKey('admin-pin-confirm'),
        onPressed: () => Navigator.pop(context, controller.text),
        child: const Text('确认'),
      ),
    ],
  );
  // 关闭动画期间 TextField 还在树上，controller 必须等动画结束再释放。
  future.whenComplete(
    () => Future<void>.delayed(
      const Duration(milliseconds: 400),
      controller.dispose,
    ),
  );
  return future;
}
