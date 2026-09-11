import 'dart:async';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/im_conversation.dart';

/// 本地聊天记录清理标记（对齐 H5 clearConversationMessages 的「本地已删」语义）：
/// 无本地消息 DB，用「清理时间点」标记替代——
/// 拉取/接收消息时过滤掉 sendTime <= 清理时间点的消息，
/// 服务端记录不动（重新进群/换设备仍可拉全量历史），纯本机视角删除。
///
/// [clearedStream] 广播清理事件，正在打开的聊天页监听后清空内存消息列表。
class ChatHistoryCleaner {
  ChatHistoryCleaner._();

  static const String _prefsKey = 'im_cleared_chat_history';

  /// 会话 key（type_targetId）→ 清理时间点（epoch millis）。
  static final Map<String, int> _cutoffs = {};

  /// 清理事件流：携带被清理会话的 key。
  static final StreamController<String> _ctrl =
      StreamController<String>.broadcast();

  /// 清理事件流（聊天页监听，收到后清空内存消息）。
  static Stream<String> get clearedStream => _ctrl.stream;

  static bool _loaded = false;

  static String _key(ImConversationType type, int targetId) =>
      '${type.value}_$targetId';

  /// 从磁盘加载标记（首次访问时惰性加载）。
  static Future<void> _ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_prefsKey) ?? const [];
      for (final entry in raw) {
        final parts = entry.split('|');
        if (parts.length == 2) {
          final ts = int.tryParse(parts[1]);
          if (ts != null) _cutoffs[parts[0]] = ts;
        }
      }
    } catch (_) {
      // 磁盘异常：视为无清理标记
    }
  }

  /// 清空指定会话的本地聊天记录：写入清理时间点并广播。
  static Future<void> clear(
    ImConversationType type,
    int targetId,
  ) async {
    await _ensureLoaded();
    final key = _key(type, targetId);
    _cutoffs[key] = DateTime.now().millisecondsSinceEpoch;
    _ctrl.add(key);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(
        _prefsKey,
        _cutoffs.entries.map((e) => '${e.key}|${e.value}').toList(),
      );
    } catch (_) {
      // 持久化失败不影响本次内存清理
    }
  }

  /// 指定会话的清理时间点（null=未清理过）。
  static Future<DateTime?> cutoffOf(
    ImConversationType type,
    int targetId,
  ) async {
    await _ensureLoaded();
    final ts = _cutoffs[_key(type, targetId)];
    return ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
  }
}
