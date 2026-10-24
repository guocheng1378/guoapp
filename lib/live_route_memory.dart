import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// 直播线路记忆：按「列表 + 频道」记住上次手动选中的线路地址。
///
/// 键 = `$listId|$channelName`，值 = 线路 URL——不用下标，因为 m3u 列表
/// 更新后线路顺序会变，URL 才是稳定锚点；记忆的 URL 若在新列表里已失效
/// （不在频道 urls 内），进台时自动回落线路 1。
/// 整张映射存单条 SharedPreferences 键，写入走 read-modify-write。
class LiveRouteMemory {
  LiveRouteMemory._();

  static const String storageKey = 'live.route.memory.v1';
  static const int maxEntries = 400;

  static Map<String, String> _routes = {};
  static SharedPreferences? _store;

  /// 应用启动链（main）与测试注入用。
  static Future<void> load(SharedPreferences preferences) async {
    _store = preferences;
    _routes = _parse(preferences.getString(storageKey));
  }

  /// 兜底懒加载：未走 main 链直接进播放器的场景。
  static Future<void> ensureLoaded() async {
    if (_store != null) return;
    _store = await SharedPreferences.getInstance();
    _routes = _parse(_store!.getString(storageKey));
  }

  static Map<String, String> _parse(String? raw) {
    if (raw == null || raw.isEmpty) return {};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        return decoded.map(
          (key, value) => MapEntry('$key', value is String ? value : '$value'),
        );
      }
    } catch (_) {
      // 损坏即当空表，下次选线重写。
    }
    return {};
  }

  static String keyFor(String listId, String channelName) =>
      '$listId|$channelName';

  static String? recall(String listId, String channelName) {
    final value = _routes[keyFor(listId, channelName)];
    if (value == null || value.isEmpty) return null;
    return value;
  }

  /// 仅用户手动选线时调用；自动兜底切线不写，避免网络抖动把临时线路记下来。
  static Future<void> remember(
    String listId,
    String channelName,
    String url,
  ) async {
    if (channelName.isEmpty || url.isEmpty) return;
    final key = keyFor(listId, channelName);
    if (_routes[key] == url) return;
    // 先移除再写入，刷新插入序：容量淘汰时优先挤掉真正最久没动的。
    _routes.remove(key);
    _routes[key] = url;
    while (_routes.length > maxEntries) {
      _routes.remove(_routes.keys.first);
    }
    await _flush();
  }

  static Future<void> _flush() async {
    final store = _store;
    if (store == null) return;
    try {
      await store.setString(storageKey, jsonEncode(_routes));
    } catch (_) {
      // 落盘失败不影响本次播放，下次选线重试。
    }
  }

  /// 测试隔离用。
  static void resetForTest() {
    _routes = {};
    _store = null;
  }
}
