import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

/// 真果鉴自绘图标库资产名。
///
/// 设计语言：24dp 网格、2px 圆角描边、圆头线帽；线性为默认形态，
/// 导航/强语义场景提供 `_filled` 面性变体（文件名 `<name>_filled.svg`）。
/// 全部单体纯黑绘制，由 [AppIcon] 按 IconTheme 染色，深浅主题同源。
///
/// 新增图标：在 assets/icons 放入 `<name>.svg` 并在此登记常量。
/// Material fallback 名单（无自绘等价物，保留 Icons.*，禁止扩散）：
/// 截至 0.2.95 —— 无。
///
/// 注意：面性变体文件名为连字符风格 `<name>-filled.svg`（资产目录既有
/// 命名如 bookmark-filled.svg），[AppIcon] 的 filled 参数按此拼接。
class AppIcons {
  AppIcons._();

  // 导航与方向
  static const String arrowBack = 'arrow-back';
  static const String arrowForward = 'arrow-forward';
  static const String chevronLeft = 'chevron-left';
  static const String chevronRight = 'chevron-right';
  static const String expandLess = 'expand-less';
  static const String expandMore = 'expand-more';
  static const String close = 'close';
  static const String check = 'check';
  static const String checkCircle = 'check-circle';
  static const String checkCircleFilled = 'check-circle-filled';
  static const String radioChecked = 'radio-checked';
  static const String radioUnchecked = 'radio-unchecked';
  static const String add = 'add';
  static const String moreHoriz = 'more-horiz';
  static const String moreVert = 'more-vert';
  static const String dragHandle = 'drag-handle';

  // 发现与搜索
  static const String search = 'search';
  static const String searchOff = 'search-off';
  static const String explore = 'explore';
  static const String fiberNew = 'new-badge';
  static const String autoAwesome = 'auto-awesome';

  // 播放器
  static const String play = 'play';
  static const String playCircle = 'play-circle';
  static const String playCircleFilled = 'play-circle-filled';
  static const String playDisabled = 'play-disabled';
  static const String pause = 'pause';
  static const String stop = 'stop';
  static const String skipNext = 'skip-next';
  static const String skipPrevious = 'skip-previous';
  static const String fastForward = 'fast-forward';
  static const String fastRewind = 'fast-rewind';
  static const String fullscreen = 'fullscreen';
  static const String fullscreenExit = 'fullscreen-exit';
  static const String pip = 'pip';
  static const String screenRotate = 'screen-rotate';
  static const String volumeUp = 'volume-up';
  static const String volumeOff = 'volume-off';
  static const String brightness = 'brightness';
  static const String keyboard = 'keyboard';

  // 影视与设备
  static const String movie = 'movie';
  static const String movieFilter = 'movie-filter';
  static const String videoLibrary = 'video-library';
  static const String smartDisplay = 'smart-display';
  static const String gridView = 'grid-view';
  static const String tv = 'tv';
  static const String computer = 'computer';
  static const String smartphone = 'smartphone';
  static const String devices = 'devices';
  static const String cast = 'cast';
  static const String castConnected = 'cast-connected';

  // 追剧与个人
  static const String history = 'history';
  static const String historyToggle = 'history-toggle';
  static const String bookmark = 'bookmark';
  static const String bookmarkFilled = 'bookmark-filled';
  static const String bookmarkAdd = 'bookmark-add';
  static const String people = 'people';
  static const String person = 'person';
  static const String personAdd = 'person-add';
  static const String premium = 'premium';
  static const String pin = 'pin';
  static const String offlinePin = 'offline-pin';

  // 下载与文件
  static const String download = 'download';
  static const String downloading = 'downloading';
  static const String cloudDownload = 'cloud-download';
  static const String cloud = 'cloud';
  static const String cloudOff = 'cloud-off';
  static const String folder = 'folder';
  static const String folderOpen = 'folder-open';
  static const String archive = 'archive';
  static const String unarchive = 'unarchive';
  static const String fileMove = 'file-move';
  static const String delete = 'delete';
  static const String edit = 'edit';
  static const String save = 'save';
  static const String copy = 'copy';
  static const String output = 'output';
  static const String merge = 'merge';
  static const String compare = 'compare';
  static const String compareArrows = 'compare-arrows';
  static const String syncAlt = 'sync-alt';
  static const String selectAll = 'select-all';
  static const String checklist = 'checklist';
  static const String doneAll = 'done-all';
  static const String removeDone = 'remove-done';
  static const String restore = 'restore';

  // 设置与网络
  static const String tune = 'tune';
  static const String filter = 'filter';
  static const String sort = 'sort';
  static const String dns = 'dns';
  static const String networkCheck = 'network-check';
  static const String settingsEthernet = 'settings-ethernet';
  static const String sync = 'sync';
  static const String refresh = 'refresh';
  static const String hub = 'hub';
  static const String wifiFind = 'wifi-find';
  static const String wifiOff = 'wifi-off';
  static const String admin = 'admin';
  static const String backup = 'backup';
  static const String lock = 'lock';
  static const String visibility = 'visibility';
  static const String visibilityOff = 'visibility-off';

  // 状态与提示
  static const String image = 'image';
  static const String palette = 'palette';
  static const String lightMode = 'light-mode';
  static const String blur = 'blur';
  static const String info = 'info';
  static const String error = 'error';
  static const String emailRead = 'email-read';

  /// 启动预缓存核心集（首屏/底栏/播放器高频）。
  static const List<String> core = <String>[
    explore,
    movie,
    download,
    person,
    play,
    playCircleFilled,
    pause,
    search,
    history,
    bookmark,
    bookmarkFilled,
    arrowBack,
    close,
    chevronRight,
    moreVert,
  ];
}

/// 自绘 SVG 图标组件，替代 `Icon(Icons.*)`。
///
/// - [name]：[AppIcons] 常量（资产逻辑名）。
/// - [filled]：使用面性变体 `assets/icons/<name>-filled.svg`，缺失时渲染空
///   （flutter_svg 无内置回退；新增 filled 变体前先确认资产存在）。
/// - [color]：默认继承 `IconTheme`，与 Material 图标一致。
class AppIcon extends StatelessWidget {
  const AppIcon(
    this.name, {
    super.key,
    this.size = 24,
    this.color,
    this.filled = false,
  });

  final String name;
  final double size;
  final Color? color;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    final Color tint = color ??
        Theme.of(context).iconTheme.color ??
        const Color(0xFF252328);
    final String asset =
        'assets/icons/${filled ? '$name-filled' : name}.svg';
    return SvgPicture.asset(
      asset,
      width: size,
      height: size,
      fit: BoxFit.contain,
      colorFilter: ColorFilter.mode(tint, BlendMode.srcIn),
      placeholderBuilder: (_) => SizedBox(width: size, height: size),
    );
  }
}
