import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import 'glass.dart';
import 'app_icons.dart';
import 'search_suggestion.dart';

class SearchInput extends StatefulWidget {
  const SearchInput({
    super.key,
    required this.controller,
    required this.hint,
    required this.onSearch,
    this.onChanged,
    this.suggestions,
    this.onSuggestionSelected,
    this.onCancel,
    this.autofocus = false,
  });
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onSearch;
  final ValueChanged<String>? onChanged;
  final Future<List<SearchSuggestion>> Function(String)? suggestions;
  /// 富建议点选（如真果·鉴直达播放）：优先走此回调；
  /// 为空时所有建议都按 submitText 填词搜索。
  final ValueChanged<SearchSuggestion>? onSuggestionSelected;
  final VoidCallback? onCancel;
  final bool autofocus;
  @override
  State<SearchInput> createState() => _SearchInputState();
}

class _SearchInputState extends State<SearchInput> {
  final _focus = FocusNode();
  Timer? _timer;
  Completer<Iterable<SearchSuggestion>>? _pending;
  int _generation = 0;
  bool _selected = false;
  final _cache = <String, List<SearchSuggestion>>{};

  void _cancel() {
    _timer?.cancel();
    widget.onCancel?.call();
    _generation++;
    if (_pending != null && !_pending!.isCompleted) {
      _pending!.complete(const []);
    }
  }

  @override
  void didUpdateWidget(SearchInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.suggestions == null) _cancel();
  }

  @override
  void dispose() {
    _cancel();
    _focus.dispose();
    super.dispose();
  }

  Future<Iterable<SearchSuggestion>> _options(TextEditingValue value) async {
    _cancel();
    final query = value.text.trim();
    if (query.isEmpty ||
        query.length > 100 ||
        widget.suggestions == null ||
        !value.composing.isCollapsed) {
      return const [];
    }
    if (_cache.containsKey(query)) return _cache[query]!;
    final generation = _generation;
    final pending = Completer<Iterable<SearchSuggestion>>();
    _pending = pending;
    _suggestFailed = false;
    _timer = Timer(const Duration(milliseconds: 300), () async {
      try {
        final result = (await widget.suggestions!(
          query,
        )).where((s) => s.label.trim().isNotEmpty).take(10).toList();
        if (generation == _generation && mounted) {
          if (_cache.length >= 32) _cache.remove(_cache.keys.first);
          _cache[query] = result;
          _suggestFailed = false;
          if (!pending.isCompleted) pending.complete(result);
        }
      } catch (_) {
        // 不再静默吞掉：建议区展示「加载失败」一行。
        _suggestFailed = true;
      }
      if (!pending.isCompleted) pending.complete(const []);
    });
    return pending.future;
  }

  void _submit(String value) {
    _cancel();
    widget.controller.value = TextEditingValue(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
    );
    _focus.unfocus();
    widget.onSearch(value.trim());
  }

  /// 建议点选：可直达播放的走富回调，其余填词搜索。
  void _select(SearchSuggestion suggestion) {
    _cancel();
    final direct = widget.onSuggestionSelected;
    if (direct != null &&
        suggestion.directPlayable &&
        suggestion.variantId.isNotEmpty) {
      _focus.unfocus();
      direct(suggestion);
      return;
    }
    _submit(suggestion.submitText);
  }

  Widget _highlight(String value) {
    final query = widget.controller.text.trim().toLowerCase();
    final spans = <TextSpan>[];
    var start = 0;
    while (query.isNotEmpty) {
      final match = value.toLowerCase().indexOf(query, start);
      if (match < 0) break;
      if (match > start) {
        spans.add(TextSpan(text: value.substring(start, match)));
      }
      spans.add(
        TextSpan(
          text: value.substring(match, match + query.length),
          style: TextStyle(
            color: Theme.of(context).colorScheme.primary,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = match + query.length;
    }
    if (start < value.length) spans.add(TextSpan(text: value.substring(start)));
    return Text.rich(
      TextSpan(children: spans),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  bool _suggestFailed = false;

  @override
  Widget build(BuildContext context) => RawAutocomplete<SearchSuggestion>(
    textEditingController: widget.controller,
    focusNode: _focus,
    optionsBuilder: _options,
    onSelected: (suggestion) {
      _selected = true;
      _select(suggestion);
    },
    fieldViewBuilder: (context, controller, focus, submitted) =>
        GlassSurface(
      variant: GlassVariant.surface,
      radius: 28,
      // 形态：方形圆角矩形（用户 2026-10-29「那些大胶囊换成方的」——宽扁的
      // 搜索框不做药丸）。
      borderRadius: BorderRadius.circular(28),
      elevated: false,
      // 双态玻璃材质：与分类条/底栏同源（pill 档）。
      tint: GlassTint.pill,
      child: TextField(
        controller: controller,
        focusNode: focus,
        autofocus: widget.autofocus,
        textInputAction: TextInputAction.search,
        // 移动端 TextField 默认点在框外不收键盘：搜索态直接点结果卡，
        // 焦点仍留在输入框，键盘会跟着 opaque:false 浮层一路弹进播放器。
        // RawAutocomplete 把输入框与建议列表放在同一 TapRegion 组，
        // 点建议项不会被误判为「外部点击」。
        onTapOutside: (_) => focus.unfocus(),
        // 不再每次按键 setState 重建整个 RawAutocomplete：只有清空
        // 按钮的显隐依赖输入内容，交给局部的 ValueListenableBuilder。
        onChanged: (value) => widget.onChanged?.call(value),
        onSubmitted: (value) {
          _selected = false;
          submitted();
          if (!_selected) _submit(value);
        },
        decoration: InputDecoration(
          hintText: widget.hint,
          filled: false,
          prefixIcon: AppIcon(AppIcons.search),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: controller,
            builder: (context, value, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (value.text.isNotEmpty)
                  IconButton(
                    tooltip: '清空搜索',
                    icon: AppIcon(AppIcons.close),
                    onPressed: () {
                      _cancel();
                      controller.clear();
                      widget.onChanged?.call('');
                    },
                  ),
                IconButton(
                  tooltip: '搜索',
                  icon: AppIcon(AppIcons.arrowForward),
                  onPressed: () => _submit(controller.text),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
    optionsViewBuilder: (context, selected, options) {
      final values = options.toList();
      final available =
          MediaQuery.sizeOf(context).height -
          MediaQuery.viewInsetsOf(context).bottom;
      // 建议请求失败时给一行可见反馈，不再静默吞异常。
      if (values.isEmpty && _suggestFailed) {
        return Align(
          alignment: Alignment.topLeft,
          child: GlassSurface(
            variant: GlassVariant.surface,
            radius: GlassTokens.radiusChip,
            elevated: false,
            child: Material(
              type: MaterialType.transparency,
              child: SizedBox(
                width: MediaQuery.sizeOf(context).width,
                height: 48,
                child: ListTile(
                  leading: AppIcon(AppIcons.cloudOff, size: 18),
                  title: Text(
                    '搜索建议加载失败',
                    style: TextStyle(
                      fontSize: 13,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }
      return Align(
        alignment: Alignment.topLeft,
        child: GlassSurface(
          variant: GlassVariant.surface,
          radius: GlassTokens.radiusChip,
          elevated: false,
          // 统一滑动栏瓷面档：微透白瓷+白描边。
          child: Material(
            type: MaterialType.transparency,
            child: SizedBox(
              width: MediaQuery.sizeOf(context).width,
              height: min(
                min(300.0, max(96.0, available * .45)),
                values.length * 48.0,
              ),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                itemCount: values.length,
                itemBuilder: (context, index) {
                  final suggestion = values[index];
                  return ListTile(
                    key: ValueKey('search-suggestion-$index'),
                    selected:
                        AutocompleteHighlightedOption.of(context) == index,
                    leading: AppIcon(AppIcons.search, size: 18),
                    title: _highlight(suggestion.label),
                    subtitle: suggestion.subtitle.trim().isNotEmpty
                        ? Text(
                            suggestion.subtitle.trim(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(
                                context,
                              ).colorScheme.onSurfaceVariant,
                            ),
                          )
                        : null,
                    onTap: () => selected(suggestion),
                  );
                },
              ),
            ),
          ),
        ),
      );
    },
  );
}
