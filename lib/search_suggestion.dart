/// 站内搜索建议（真果·鉴 /v1/suggest）。
///
/// 两种建议：
/// - [directPlayable] 且 [variantId] 非空：点选直达该剧播放（intent=play）；
/// - 其余：点选按 [label] 或 [prompt] 走普通搜索（intent=filter/similar/search）。
library;

class SearchSuggestion {
  const SearchSuggestion({
    required this.label,
    this.subtitle = '',
    this.intent = '',
    this.variantId = '',
    this.directPlayable = false,
    this.prompt = '',
  });

  final String label;
  final String subtitle;
  final String intent;
  final String variantId;
  final bool directPlayable;
  final String prompt;

  /// 点选后提交给搜索框的文本：优先 prompt（站点意图词），回退 label。
  String get submitText => prompt.trim().isNotEmpty ? prompt.trim() : label;

  static SearchSuggestion fromJson(Map<String, dynamic> json) =>
      SearchSuggestion(
        label: json['label']?.toString() ?? '',
        subtitle: json['subtitle']?.toString() ?? '',
        intent: json['intent']?.toString() ?? '',
        variantId: json['variantId']?.toString() ?? '',
        directPlayable: json['directPlayable'] == true,
        prompt: json['prompt']?.toString() ?? '',
      );

  Map<String, dynamic> toJson() => {
    'label': label,
    'subtitle': subtitle,
    'intent': intent,
    'variantId': variantId,
    'directPlayable': directPlayable,
    'prompt': prompt,
  };
}
