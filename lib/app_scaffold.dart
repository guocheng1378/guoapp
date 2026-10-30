import 'package:flutter/material.dart';

import 'app_layout.dart';
import 'glass.dart';
import 'soft_glass.dart';

/// 页面脚手架：次要页面（设置子页、下载、追剧、诊断、激活…）的统一骨架。
///
/// 收敛的重复实现：
/// - 顶栏（透明沉浸 + 顶栏雾面 `TopFog`）；
/// - 滚动体与统一内边距；
/// - 标题/副标题/操作位/底部条的挂载位。
///
/// 材质约定（与 `soft_glass.dart` 一致）：
/// - 大面积容器（卡片、面板）自带 `BackdropFilter`（真磨砂）；
/// - 卡片内部的行、输入框等子元素用 [SoftGlassSurface.inherit]——继承父级
///   磨砂，不再二次采样（同层单 backdrop，避免发灰）。
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    super.key,
    this.title = '',
    this.titleWidget,
    this.subtitle,
    this.leading,
    this.actions = const [],
    this.children = const [],
    this.body,
    this.scrollable = true,
    this.padding = const EdgeInsets.fromLTRB(16, 8, 16, 24),
    this.bottomBar,
    this.extendBody = false,
    this.backgroundColor,
  });

  /// 顶栏标题（与 [titleWidget] 二选一）。
  final String title;

  /// 自定义顶栏标题（优先于 [title]）。
  final Widget? titleWidget;

  /// 顶栏副标题（标题下方一行小字）。
  final String? subtitle;

  final Widget? leading;
  final List<Widget> actions;

  /// 滚动体内容（[scrollable] 为 true 时使用）。
  final List<Widget> children;

  /// 自定义内容（非滚动场景使用；给了它就忽略 [children]）。
  final Widget? body;

  /// 内容是否包滚动列表。
  final bool scrollable;

  /// 滚动体内边距。
  final EdgeInsetsGeometry padding;

  /// 底部条（如批量操作条）。
  final Widget? bottomBar;

  /// 内容是否延伸到顶栏后方（沉浸式）；默认 false＝内容从顶栏下方开始
  /// （与既有页面一致，顶栏雾面只盖顶栏自身高度）。
  final bool extendBody;

  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final television = AppLayout.isTelevision(context);
    final titleContent = titleWidget ??
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (title.isNotEmpty)
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            if (subtitle != null)
              Text(
                subtitle!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
          ],
        );
    return Scaffold(
      backgroundColor: backgroundColor,
      extendBodyBehindAppBar: extendBody && !television,
      appBar: AppBar(
        titleSpacing: 12,
        title: titleContent,
        leading: leading,
        actions: actions,
        // 顶栏雾面：手机端铺一条（内容穿顶时糊化），TV 端不做柔光。
        flexibleSpace: (!television) ? const TopFog() : null,
      ),
      body: _body(context),
      bottomNavigationBar: bottomBar,
    );
  }

  Widget? _body(BuildContext context) {
    if (body != null) return body;
    if (!scrollable) {
      return children.isEmpty ? null : Column(children: children);
    }
    return ListView(
      padding: padding,
      children: children,
    );
  }
}

/// 柔光玻璃卡片：大面积容器自带真磨砂（σ 由材质配方决定）。
class SoftGlassCard extends StatelessWidget {
  const SoftGlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 20,
    this.margin,
    this.elevated = false,
    this.onTap,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final EdgeInsetsGeometry? margin;
  final bool elevated;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 形态：**方形圆角矩形**（用户 2026-10-29「那些大胶囊换成方的」——容器级
    // 玻璃板不做药丸；药丸只留给紧凑小件）。
    final card = SoftGlassSurface(
      shape: SoftGlassShape.rounded,
      radius: radius,
      padding: padding,
      elevated: elevated,
      child: child,
    );
    final content = onTap == null
        ? card
        : SoftGlassPressHighlight(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              child: card,
            ),
          );
    if (margin == null) return content;
    return Padding(padding: margin!, child: content);
  }
}

/// 柔光玻璃列表行：继承父级卡片磨砂（不自带 backdrop），仅画 tint + 描边。
class SoftGlassListTile extends StatelessWidget {
  const SoftGlassListTile({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final content = SoftGlassSurface.inherit(
      shape: SoftGlassShape.rounded,
      radius: 16,
      padding: padding,
      child: Row(
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 12)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
              ],
            ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );
    if (onTap == null) return content;
    return SoftGlassPressHighlight(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: content,
      ),
    );
  }
}

/// 柔光玻璃面板：弹层/区块容器（比卡片更实的底 + 更大的圆角）。
class SoftGlassPanel extends StatelessWidget {
  const SoftGlassPanel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(20),
    this.radius = 28,
    this.tintBoost = 1.8,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  /// 底色浓度倍率（面板类比胶囊类更实一档，保证可读）。
  final double tintBoost;

  @override
  Widget build(BuildContext context) {
    final spec = SoftGlassStore.state.value;
    final brightness = Theme.of(context).brightness;
    final base = SoftGlassTokens.tint(
      spec,
      brightness,
      primary: Theme.of(context).colorScheme.primary,
    );
    return SoftGlassSurface(
      shape: SoftGlassShape.rounded,
      radius: radius,
      padding: padding,
      // 面板底更实一档：清透玻璃做底板会读不清文字。
      tint: base.withValues(alpha: (base.a * tintBoost).clamp(0.0, 1.0)),
      child: child,
    );
  }
}

/// 柔光玻璃输入框：继承父级磨砂，聚焦时描边转主色。
class SoftGlassField extends StatelessWidget {
  const SoftGlassField({
    super.key,
    required this.controller,
    this.hintText,
    this.obscureText = false,
    this.enabled = true,
    this.keyboardType,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.autofocus = false,
    this.prefixIcon,
    this.suffix,
    this.maxLines = 1,
  });

  final TextEditingController controller;
  final String? hintText;
  final bool obscureText;
  final bool enabled;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final bool autofocus;
  final Widget? prefixIcon;
  final Widget? suffix;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SoftGlassSurface.inherit(
      shape: SoftGlassShape.rounded,
      radius: 16,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: TextField(
        controller: controller,
        obscureText: obscureText,
        enabled: enabled,
        keyboardType: keyboardType,
        textInputAction: textInputAction,
        autofocus: autofocus,
        maxLines: obscureText ? 1 : maxLines,
        onSubmitted: onSubmitted,
        onChanged: onChanged,
        style: theme.textTheme.bodyMedium,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          filled: false,
          hintText: hintText,
          hintStyle: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
          ),
          prefixIcon: prefixIcon,
          suffixIcon: suffix,
        ),
      ),
    );
  }
}

/// 顶栏图标按钮：统一成柔光玻璃圆岛（顶栏已有一条整条模糊，故继承不重复采样）。
class SoftGlassIconButton extends StatelessWidget {
  const SoftGlassIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.size = 40,
  });

  final Widget icon;
  final String tooltip;
  final VoidCallback? onPressed;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SoftGlassSurface.inherit(
        shape: SoftGlassShape.circle,
        constraints: BoxConstraints.tightFor(width: size, height: size),
        padding: EdgeInsets.zero,
        child: SoftGlassPressHighlight(
          child: IconButton(
            tooltip: tooltip,
            onPressed: onPressed,
            icon: icon,
            iconSize: size * 0.5,
            padding: EdgeInsets.zero,
            constraints: BoxConstraints.tightFor(width: size, height: size),
          ),
        ),
      ),
    );
  }
}

/// 页面内的柔光玻璃分组标题（弱化存在感，只做节奏分隔）。
class SoftGlassSectionTitle extends StatelessWidget {
  const SoftGlassSectionTitle({super.key, required this.text, this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
      child: Row(
        children: [
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.labelLarge?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}
