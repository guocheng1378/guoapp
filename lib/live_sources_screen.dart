import 'package:flutter/material.dart';

import 'app_scaffold.dart';
import 'core_bridge.dart';
import 'live_sources_pane.dart';
import 'local_store.dart';

/// 直播源管理独立页（2026-10-22）：增删自填 m3u/m3u8/txt 订阅 URL（设备级），
/// 与内置双列表合并；每次增删即时保存。
///
/// 管理 UI 已抽到 [LiveSourcesPane]，「内置站源」页的直播源分区共用同一份逻辑。
class LiveSourcesScreen extends StatelessWidget {
  const LiveSourcesScreen({
    super.key,
    required this.store,
    required this.repository,
  });
  final LocalStore store;
  final AppRepository repository;

  @override
  Widget build(BuildContext context) => AppScaffold(
    title: '直播源管理',
    body: SingleChildScrollView(
      child: LiveSourcesPane(store: store, repository: repository),
    ),
  );
}
