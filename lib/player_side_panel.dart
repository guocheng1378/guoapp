import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'app_icons.dart';

/// 右侧面板底色：近不透明深色（不跟主题走，画面优先的影院 HUD 语言）。
const Color sidePanelBackground = Color(0xF20E0F12);

/// 右侧滑出面板的市场宽度：横屏最多 420 / 38%，竖屏最多 320 / 78%。
double sidePanelWidth(Size size) {
  final landscape = size.width > size.height;
  return landscape
      ? math.min(420, size.width * .38)
      : math.min(320, size.width * .78);
}

/// 统一入口：从右侧滑出的一块不透明深色面板，180ms easeOutCubic。
///
/// 播放源/倍速/选集/画面比例四类二级功能共用这一个壳，替代原来四种不同的
/// 居中玻璃弹窗。[builder] 里用 `Navigator.pop(context, value)` 回传结果。
Future<T?> showPlayerSidePanel<T>({
  required BuildContext context,
  required String title,
  required WidgetBuilder builder,
  Widget? trailing,
  double? width,
}) {
  final size = MediaQuery.sizeOf(context);
  final panelWidth = width ?? sidePanelWidth(size);
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: true,
    barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
    // 只做很轻的压暗：面板本身不透明，压太黑会让「画面还在播」的感觉消失。
    barrierColor: Colors.black.withValues(alpha: .18),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (dialogContext, animation, secondaryAnimation) {
      final media = MediaQuery.of(dialogContext);
      return Align(
        alignment: Alignment.centerRight,
        child: Material(
          key: const ValueKey('player-side-panel'),
          color: sidePanelBackground,
          child: SizedBox(
            width: panelWidth,
            height: media.size.height,
            child: SafeArea(
              left: false,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _SidePanelHeader(title: title, trailing: trailing),
                  Expanded(child: Builder(builder: builder)),
                ],
              ),
            ),
          ),
        ),
      );
    },
    transitionBuilder: (context, animation, secondaryAnimation, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: Curves.easeOutCubic,
        reverseCurve: Curves.easeInCubic,
      );
      return SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(1, 0),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      );
    },
  );
}

class _SidePanelHeader extends StatelessWidget {
  const _SidePanelHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      padding: const EdgeInsets.only(left: 18, right: 4),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: .08)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          trailing ?? const SizedBox.shrink(),
          IconButton(
            // 与原来的播放菜单保持同一个 tooltip：侧面板就是「菜单」的新形态。
            tooltip: '关闭菜单',
            constraints: const BoxConstraints.tightFor(width: 44, height: 44),
            padding: EdgeInsets.zero,
            onPressed: () => Navigator.pop(context),
            icon: AppIcon(
              AppIcons.close,
              size: 20,
              color: Colors.white.withValues(alpha: .8),
            ),
          ),
        ],
      ),
    );
  }
}

/// 面板里一个可选项。key 用于回传，label 是展示文案。
class SideChoice {
  const SideChoice(this.key, this.label, {this.note = ''});

  final Object key;
  final String label;
  final String note;
}

/// 三列网格：倍速、画面比例这类短文案用它（照参考截图 88×48 的格子）。
class SideChoiceGrid extends StatelessWidget {
  const SideChoiceGrid({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelect,
    this.keyPrefix = 'side-choice',
    this.columns = 3,
    this.padding = const EdgeInsets.fromLTRB(18, 16, 18, 16),
  });

  final List<SideChoice> choices;
  final Object? selected;
  final ValueChanged<SideChoice> onSelect;
  final String keyPrefix;
  final int columns;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final panel = sidePanelWidth(MediaQuery.sizeOf(context));
    final cellWidth =
        (panel - padding.horizontal - 8 * (columns - 1)) / columns;
    return SingleChildScrollView(
      padding: padding,
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (final choice in choices)
            SizedBox(
              width: cellWidth,
              height: 48,
              child: GestureDetector(
                key: ValueKey('$keyPrefix-${choice.key}'),
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(choice),
                child: Container(
                  decoration: BoxDecoration(
                    color: choice.key == selected
                        ? Colors.white
                        : Colors.white.withValues(alpha: .1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    choice.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: choice.key == selected ? Colors.black : Colors.white,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 单列列表：播放源、清晰度这类需要完整文案的用它（行高 52，选中带勾）。
class SideChoiceList extends StatelessWidget {

  const SideChoiceList({
    super.key,
    required this.choices,
    required this.selected,
    required this.onSelect,
    this.keyPrefix = 'side-row',
    this.shrinkWrap = false,
    this.physics,
  });

  final List<SideChoice> choices;
  final Object? selected;
  final ValueChanged<SideChoice> onSelect;
  final String keyPrefix;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    return ListView.builder(
      shrinkWrap: shrinkWrap,
      physics: physics,
      padding: const EdgeInsets.symmetric(vertical: 6),
      itemCount: choices.length,
      itemBuilder: (context, index) {
        final choice = choices[index];
        final active = choice.key == selected;
        return InkWell(
          key: ValueKey('$keyPrefix-${choice.key}'),
          onTap: () => onSelect(choice),
          child: SizedBox(
            height: 52,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          choice.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: active ? FontWeight.w600 : null,
                            color: active
                                ? primary
                                : Colors.white.withValues(alpha: .8),
                          ),
                        ),
                        if (choice.note.isNotEmpty)
                          Text(
                            choice.note,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: Colors.white.withValues(alpha: .45),
                            ),
                          ),
                      ],
                    ),
                  ),
                  if (active)
                    AppIcon(AppIcons.check, size: 18, color: primary),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// 面板底部的一条滑条（音量/亮度）：左端图标 + 轨道 + 右端百分比。
class SideSliderRow extends StatelessWidget {
  const SideSliderRow({
    super.key,
    required this.icon,
    required this.value,
    required this.onChanged,
    required this.sliderKey,
    this.min = 0,
    this.max = 100,
    this.divisions = 20,
    this.label,
  });

  final String icon;
  final double value;
  final ValueChanged<double> onChanged;
  final Key sliderKey;
  final double min;
  final double max;
  final int? divisions;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        AppIcon(icon, size: 20, color: Colors.white.withValues(alpha: .8)),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              activeTrackColor: Theme.of(context).colorScheme.primary,
              inactiveTrackColor: Colors.white.withValues(alpha: .24),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              key: sliderKey,
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: onChanged,
            ),
          ),
        ),
        SizedBox(
          width: 40,
          child: Text(
            label ?? '${value.round()}%',
            textAlign: TextAlign.end,
            style: TextStyle(
              fontSize: 12,
              color: Colors.white.withValues(alpha: .7),
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }
}

/// 播放源列表：官方线平铺，第三方线折叠成一条入口（面板内原地展开，
/// 不再像旧版那样关一个玻璃菜单再开第二个）。一集常带 20~30 条三方线，
/// 全平铺会把 1~5 条官方线淹没在长列表里。
class SideRouteList extends StatefulWidget {
  const SideRouteList({
    super.key,
    required this.labels,
    required this.current,
    required this.official,
    required this.thirdParty,
    required this.onSelected,
  });

  final List<String> labels;
  final int current;
  final List<int> official;
  final List<int> thirdParty;
  final ValueChanged<int> onSelected;

  @override
  State<SideRouteList> createState() => _SideRouteListState();
}

class _SideRouteListState extends State<SideRouteList> {
  bool _thirdPartyOpen = false;

  @override
  void initState() {
    super.initState();
    // 当前正在播第三方线时直接展开，省得用户以为自己的线路没了。
    _thirdPartyOpen =
        widget.official.isNotEmpty &&
        widget.thirdParty.isNotEmpty &&
        !widget.official.contains(widget.current);
  }

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (widget.official.isEmpty) {
      for (var index = 0; index < widget.labels.length; index++) {
        rows.add(_row(index, widget.labels[index], indent: 0));
      }
    } else {
      rows.add(_header('官方源 · ${widget.official.length} 条'));
      for (final index in widget.official) {
        rows.add(_row(index, _labelOf(index), indent: 0));
      }
      if (widget.thirdParty.isNotEmpty) {
        rows.add(
          InkWell(
            key: const ValueKey('side-route-third-party'),
            onTap: () => setState(() => _thirdPartyOpen = !_thirdPartyOpen),
            child: SizedBox(
              height: 52,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '第三方源 · ${widget.thirdParty.length} 条',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: .8),
                        ),
                      ),
                    ),
                    AppIcon(
                      _thirdPartyOpen ? AppIcons.expandLess : AppIcons.expandMore,
                      size: 18,
                      color: Colors.white.withValues(alpha: .6),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        if (_thirdPartyOpen) {
          for (final index in widget.thirdParty) {
            rows.add(_row(index, _labelOf(index), indent: 12));
          }
        }
      }
    }
    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 6),
      children: rows,
    );
  }

  String _labelOf(int index) {
    if (index < 0 || index >= widget.labels.length) return '线路 ${index + 1}';
    final label = widget.labels[index].trim();
    return label.isEmpty ? '线路 ${index + 1}' : label;
  }

  Widget _header(String text) => Padding(
    padding: const EdgeInsets.fromLTRB(18, 12, 18, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: Colors.white.withValues(alpha: .5),
      ),
    ),
  );

  Widget _row(int index, String label, {required double indent}) {
    final active = index == widget.current;
    final primary = Theme.of(context).colorScheme.primary;
    return InkWell(
      key: ValueKey('side-route-$index'),
      onTap: () => widget.onSelected(index),
      child: SizedBox(
        height: 52,
        child: Padding(
          padding: EdgeInsets.only(left: 18 + indent, right: 18),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: active ? FontWeight.w600 : null,
                    color: active ? primary : Colors.white.withValues(alpha: .8),
                  ),
                ),
              ),
              if (active) AppIcon(AppIcons.check, size: 18, color: primary),
            ],
          ),
        ),
      ),
    );
  }
}
