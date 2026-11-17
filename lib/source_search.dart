import 'package:flutter/material.dart';

import 'app_icons.dart';

/// 一次「按剧名换源」请求：把剧名交给首页，在**当前源所在分组**里搜一遍。
@immutable
class SourceSearchRequest {
  const SourceSearchRequest(this.query);

  final String query;
}

/// 跨页面通道：播放失败/详情不可用时写入请求，
/// 首页（根路由）消费后切回发现页并按剧名搜索。
///
/// 播放器、简介页与首页不在同一条回调链上（都是同级的独立路由），
/// 用一次性 ValueNotifier 传递比层层透传回调简单，也不会残留状态。
class SourceSearchBus {
  SourceSearchBus._();

  static final ValueNotifier<SourceSearchRequest?> pending =
      ValueNotifier<SourceSearchRequest?>(null);

  static void request(String query) {
    final title = query.trim();
    if (title.isEmpty) return;
    pending.value = SourceSearchRequest(title);
  }

  /// 取走并清空，避免同一请求被重复消费。
  static SourceSearchRequest? take() {
    final request = pending.value;
    if (request != null) pending.value = null;
    return request;
  }
}

/// 「换个源找」按钮：写完请求就回到首页等结果。
///
/// 播放失败时用——当前源没有可播地址，往往换个源的同名片就能放。
/// 搜索范围与首页默认搜索一致，**只限当前源所在分组**（短剧类/视频类
/// 等）：跨全部已启用站源搜要逐个等网络返回，实测慢到不可用。
class GroupSearchButton extends StatelessWidget {
  const GroupSearchButton({
    super.key,
    required this.title,
    this.enabled = true,
  });

  final String title;

  /// 分组内没有第二个源可换时入口没有意义——由调用方按站源情况关掉。
  final bool enabled;

  @override
  Widget build(BuildContext context) => !enabled
      ? const SizedBox.shrink()
      : TextButton.icon(
          onPressed: title.trim().isEmpty
              ? null
              : () {
                  // 先把整条栈收回首页再写请求：反序会在播放页仍是当前
                  // 路由时通知栈底首页 setState，build 期间改状态会抛
                  // 「setState() called during build」。
                  Navigator.of(context).popUntil((route) => route.isFirst);
                  SourceSearchBus.request(title);
                },
          icon: const AppIcon(AppIcons.search, size: 18),
          label: const Text('换个源找'),
        );
}
