import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../shared/chat_background.dart';

/// 聊天背景选择 store（全局单例）：
/// - SharedPreferences 持久化选中的背景 id（换机/重装恢复默认）
/// - ChangeNotifier：聊天室在用的背景层实时响应切换
class ChatBackgroundStore extends ChangeNotifier {
  ChatBackgroundStore._();

  static final ChatBackgroundStore instance = ChatBackgroundStore._();

  static const String _prefKey = 'im_chat_background_id';

  /// 当前生效的聊天背景（未选择过 = 默认第 0 张）。
  ChatBg _bg = defaultChatBackground;
  ChatBg get bg => _bg;

  /// 冷启动恢复持久化的选择（幂等，聊天页 initState 调用）。
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final sp = await SharedPreferences.getInstance();
      final id = sp.getInt(_prefKey);
      if (id != null) {
        final found = chatBackgrounds.where((b) => b.id == id).firstOrNull;
        if (found != null && found != _bg) {
          _bg = found;
          notifyListeners();
        }
      }
    } catch (_) {
      // 读取失败保持默认
    }
  }

  bool _loaded = false;

  /// 设置聊天背景（内存即时生效 + 持久化）。
  Future<void> set(ChatBg bg) async {
    if (_bg == bg) return;
    _bg = bg;
    notifyListeners();
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_prefKey, bg.id);
    } catch (_) {
      // 持久化失败不影响本次会话生效
    }
  }
}
