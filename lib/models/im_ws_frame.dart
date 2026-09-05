import 'dart:convert';

/// WebSocket 帧结构（对应 H5 WebSocketFrame）：
/// { "type": "im-notification", "content": "{...}" }
/// content 为 JSON 字符串，内含 [ImWsNotification]。
class ImWsFrame {
  /// 帧类型（如 im-notification）。
  final String type;

  /// 内层 JSON 字符串。
  final String content;

  const ImWsFrame({required this.type, required this.content});

  /// 解析外层帧；非 JSON 结构（如心跳文本 pong）返回 null。
  static ImWsFrame? tryParse(String raw) {
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return null;
      final type = decoded['type']?.toString() ?? '';
      final content = decoded['content']?.toString() ?? '';
      if (type.isEmpty) return null;
      return ImWsFrame(type: type, content: content);
    } catch (_) {
      return null;
    }
  }

  /// 惰性解析内层通知 DTO；解析失败返回 null。
  ImWsNotification? get notification => ImWsNotification.tryParse(content);
}

/// WebSocket 通知 DTO（对应 H5 ImNotificationWebSocketDTO）。
class ImWsNotification {
  /// 会话类型：0=无会话（关系事件/信令） 1=私聊 2=群聊 3=频道。
  final int conversationType;

  /// 通知内容类型：消息 / 已读 / 回执 / 撤回 / 关系事件等。
  final int contentType;

  /// 通知负载（各类型结构不同，原样透传给消费方按需取值）。
  final Map<String, dynamic> payload;

  const ImWsNotification({
    required this.conversationType,
    required this.contentType,
    required this.payload,
  });

  static ImWsNotification? tryParse(String content) {
    try {
      final decoded = jsonDecode(content);
      if (decoded is! Map) return null;
      final ct = decoded['conversationType'];
      final cot = decoded['contentType'];
      if (ct == null || cot == null) return null;
      final payload = decoded['payload'];
      return ImWsNotification(
        conversationType: ct is num ? ct.toInt() : int.tryParse('$ct') ?? 0,
        contentType: cot is num ? cot.toInt() : int.tryParse('$cot') ?? 0,
        payload: payload is Map
            ? payload.map((k, v) => MapEntry(k.toString(), v))
            : const {},
      );
    } catch (_) {
      return null;
    }
  }
}
