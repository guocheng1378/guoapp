import 'dart:async';

import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'follow_state.dart';
import 'glass.dart';
import 'local_store.dart';
import 'models.dart';
import 'player_screen.dart';
import 'widgets.dart';
import 'app_icons.dart';

/// 点剧卡进播放：立即推透明启动浮层——底下首页保持可见，只在中央淡入
/// 一个小转圈（无整页白底）；详情解析、续播集计算、VIP 确认都在浮层内
/// 完成，成功后 pushReplacement 进播放器，失败浮出错误卡可重试。
/// 不要在推路由前 await 网络/落盘，否则点按后长时间无响应。
Future<void> openPlaybackDirectly(
  BuildContext context, {
  required Drama drama,
  required AppRepository repository,
  required LocalStore store,
}) {
  // 兜底：搜索建议直达 / 追剧卡 / 以后新增的入口都不经过搜索框的
  // onTapOutside，起播前统一释放文本焦点——否则键盘会跟着 opaque:false
  // 浮层一路弹进播放器。电视模式不动遥控焦点。
  if (!AppLayout.isTelevision(context)) {
    FocusManager.instance.primaryFocus?.unfocus();
  }
  return Navigator.of(context).push(
    PageRouteBuilder<void>(
      // opaque:false：转场与加载期间底下页面不被遮挡，浮层只是叠加。
      opaque: false,
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 150),
      pageBuilder: (_, __, ___) => PlaybackLaunchScreen(
        drama: drama,
        repository: repository,
        store: store,
      ),
      transitionsBuilder: (_, animation, __, child) =>
          FadeTransition(opacity: animation, child: child),
    ),
  );
}

class PlaybackLaunchScreen extends StatefulWidget {
  const PlaybackLaunchScreen({
    super.key,
    required this.drama,
    required this.repository,
    required this.store,
  });

  final Drama drama;
  final AppRepository repository;
  final LocalStore store;

  @override
  State<PlaybackLaunchScreen> createState() => _PlaybackLaunchScreenState();
}

class _PlaybackLaunchScreenState extends State<PlaybackLaunchScreen> {
  late final int _profileEpoch;
  int _generation = 0;
  String? _error;
  bool _awaitingVip = false;

  @override
  void initState() {
    super.initState();
    _profileEpoch = widget.store.profileEpoch;
    unawaited(_load());
  }

  @override
  void dispose() {
    _generation++;
    super.dispose();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    setState(() => _error = null);
    try {
      // 超时兜底：解析链挂起时不再无限转圈，20s 后浮错误卡可重试
      // （底层请求不取消，重试期间原请求若完成也只作废）。
      final detail = await widget.repository
          .detail(widget.drama)
          .timeout(const Duration(seconds: 20));
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      final drama = widget.repository.catalogUpdates
          .current(widget.drama)
          .merge(detail.drama);
      final merged = DramaDetail(
        drama,
        detail.episodes,
        warning: detail.warning,
      );
      widget.repository.catalogUpdates.publish(drama, retryCover: true);
      // 落盘只是缓存剧档案，不参与播放：不等待，别挡 pushReplacement。
      unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      if (merged.episodes.isEmpty) {
        setState(() => _error = '暂时没有可播放的集数');
        return;
      }
      final watched = widget.store.watched(drama.id);
      final index = resumeEpisodeIndex(merged.episodes, watched);
      final episode = merged.episodes[index];
      if (episode.vip) {
        if (!mounted) return;
        // VIP 确认期间停掉底下的转圈：对话框盖着转圈是纯噪音，
        // 且测试环境的 pumpAndSettle 会因这个永续动画永远等不到收敛。
        setState(() => _awaitingVip = true);
        final accepted = await showDialog<bool>(
          context: context,
          builder: (context) => GlassDialogShell(
            child: AlertDialog(
              title: const Text('这是一集 VIP 内容'),
              content: const Text('站源可能只提供试看或限制播放。'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: const Text('尝试播放'),
                ),
              ],
            ),
          ),
        );
        if (accepted != true) {
          if (mounted) {
            setState(() => _awaitingVip = false);
            Navigator.of(context).maybePop();
          }
          return;
        }
        if (!mounted) {
          return;
        }
        setState(() => _awaitingVip = false);
      }
      final position =
          watched?.episode == episode.number && watched?.finished == false
          ? watched!.position
          : 0.0;
      if (!mounted ||
          generation != _generation ||
          _profileEpoch != widget.store.profileEpoch) {
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute<void>(
          builder: (_) => PlayerScreen(
            detail: merged,
            initialIndex: index,
            initialPosition: position,
            repository: widget.repository,
            store: widget.store,
          ),
        ),
      );
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() => _error = friendlyError(error));
      widget.repository.catalogUpdates.publish(
        widget.repository.catalogUpdates.current(widget.drama),
        retryCover: true,
      );
    }
  }

  /// 加载中的白瓷圆片 + 来源名标注。
  Widget _buildLoadingCard() {
    final sourceName =
        SourceSite.byId(widget.drama.source)?.name ??
        (widget.drama.source.isEmpty ? null : widget.drama.source);
    return GlassSurface(
      radius: 28,
      tint: GlassTint.pill,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 30,
            height: 30,
            child: CircularProgressIndicator(strokeWidth: 3),
          ),
          if (sourceName != null) ...[
            const SizedBox(height: 10),
            Text(
              '正在加载 · $sourceName',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      // 透明背景浮层：底下首页可见，只有中央小圆片/错误卡叠加。
      backgroundColor: Colors.transparent,
      body: SafeArea(
        top: false,
        child: error == null
            ? (_awaitingVip
                  // VIP 确认对话框打开期间不渲染任何东西：底下首页可见，
                  // 对话框盖着转圈是纯噪音，永续动画还会让测试等不到收敛。
                  ? const SizedBox.shrink()
                  : Center(
                      // 白瓷面小圆片：亮色海报上转圈仍可辨，无整页底色。
                      // 下方标注加载中的来源，用户知道在等谁。
                      child: _buildLoadingCard(),
                    ))
            : Center(
                // 错误卡：连续文字面用实底档，保证可读；可返回可重试。
                child: GlassSurface(
                  radius: 24,
                  tint: GlassTint.card,
                  constraints: const BoxConstraints(maxWidth: 280),
                  padding: const EdgeInsets.fromLTRB(20, 22, 20, 10),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppIcon(AppIcons.playDisabled, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 10),
                      Text(
                        '暂时无法播放',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        error,
                        maxLines: 4,
                        overflow: TextOverflow.ellipsis,
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: Theme.of(
                            context,
                          ).colorScheme.onSurface.withValues(alpha: 0.65),
                        ),
                      ),
                      const SizedBox(height: 14),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton(
                            onPressed: () => Navigator.of(context).maybePop(),
                            child: const Text('返回'),
                          ),
                          const SizedBox(width: 4),
                          FilledButton(
                            onPressed: _load,
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}
