import 'dart:convert';

import '../services/auth_manager.dart';
import '../shared/json_utils.dart';

/// 私聊历史消息（对应后端 ImPrivateMessageRespVO）。
class ImPrivateMessage {
  final int id;
  final String clientMessageId;
  final int senderId;
  final int receiverId;
  final int type;
  final String content;
  final int status;
  final int receiptStatus;
  final DateTime? sendTime;

  const ImPrivateMessage({
    required this.id,
    required this.clientMessageId,
    required this.senderId,
    required this.receiverId,
    required this.type,
    required this.content,
    required this.status,
    required this.receiptStatus,
    this.sendTime,
  });

  factory ImPrivateMessage.fromJson(Map<String, dynamic> json) {
    return ImPrivateMessage(
      id: asInt(json['id']),
      clientMessageId: asString(json['clientMessageId']),
      senderId: asInt(json['senderId']),
      receiverId: asInt(json['receiverId']),
      type: asInt(json['type']),
      content: asString(json['content']),
      status: asInt(json['status']),
      receiptStatus: asInt(json['receiptStatus']),
      sendTime: parseDateTime(json['sendTime']),
    );
  }

  /// 是否自己发送（区分气泡左右方向）。
  bool get isSelf => senderId == AuthManager.instance.userId;

  /// 消息文本：content 为 JSON 字符串（文本消息形如 {"content":"你好"}），
  /// 解析失败时回退为原始字符串。
  String get textContent => extractTextContent(content);
}

/// 群聊历史消息（对应后端 ImGroupMessageRespVO）。
class ImGroupMessage {
  final int id;
  final String clientMessageId;
  final int senderId;
  final int groupId;
  final int type;
  final String content;
  final int status;
  final DateTime? sendTime;
  final List<int> atUserIds;
  final List<int> receiverUserIds;
  final int receiptStatus;
  final int readCount;

  const ImGroupMessage({
    required this.id,
    required this.clientMessageId,
    required this.senderId,
    required this.groupId,
    required this.type,
    required this.content,
    required this.status,
    this.sendTime,
    this.atUserIds = const [],
    this.receiverUserIds = const [],
    required this.receiptStatus,
    required this.readCount,
  });

  factory ImGroupMessage.fromJson(Map<String, dynamic> json) {
    return ImGroupMessage(
      id: asInt(json['id']),
      clientMessageId: asString(json['clientMessageId']),
      senderId: asInt(json['senderId']),
      groupId: asInt(json['groupId']),
      type: asInt(json['type']),
      content: asString(json['content']),
      status: asInt(json['status']),
      sendTime: parseDateTime(json['sendTime']),
      atUserIds: parseIntList(json['atUserIds']),
      receiverUserIds: parseIntList(json['receiverUserIds']),
      receiptStatus: asInt(json['receiptStatus']),
      readCount: asInt(json['readCount']),
    );
  }

  /// 是否自己发送（区分气泡左右方向）。
  bool get isSelf => senderId == AuthManager.instance.userId;

  /// 消息文本：content 为 JSON 字符串（文本消息形如 {"content":"你好"}），
  /// 解析失败时回退为原始字符串。
  String get textContent => extractTextContent(content);
}

/// 频道消息（对应后端 ImChannelMessagePullRespVO）。
class ImChannelMessage {
  final int id;
  final int channelId;
  final int materialId;
  final int type;
  final String content;
  final int receiptStatus;
  final DateTime? sendTime;

  const ImChannelMessage({
    required this.id,
    required this.channelId,
    required this.materialId,
    required this.type,
    required this.content,
    required this.receiptStatus,
    this.sendTime,
  });

  factory ImChannelMessage.fromJson(Map<String, dynamic> json) {
    return ImChannelMessage(
      id: asInt(json['id']),
      channelId: asInt(json['channelId']),
      materialId: asInt(json['materialId']),
      type: asInt(json['type']),
      content: asString(json['content']),
      receiptStatus: asInt(json['receiptStatus']),
      sendTime: parseDateTime(json['sendTime']),
    );
  }

  /// 摘要：content 为素材 payload JSON 快照（图文卡片等），
  /// 尝试提取标题类字段，失败回退固定文案。
  String get summaryText {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        for (final key in ['title', 'name', 'content']) {
          final v = decoded[key];
          if (v != null && v.toString().isNotEmpty) return v.toString();
        }
      }
    } catch (_) {
      // 非 JSON 格式
    }
    return '[频道消息]';
  }
}

/// 解析后端时间字段：兼容时间戳（num）与 date-time 字符串两种形式。
DateTime? parseDateTime(dynamic value) {
  if (value == null) return null;
  if (value is num) return DateTime.fromMillisecondsSinceEpoch(value.toInt());
  final str = value.toString();
  if (str.isEmpty) return null;
  return DateTime.tryParse(str);
}

/// 解析 int 列表字段：兼容 List 与 JSON 字符串（如 "[1,2,3]"）两种形式。
List<int> parseIntList(dynamic value) {
  dynamic parsed = value;
  if (parsed is String && parsed.isNotEmpty) {
    try {
      parsed = jsonDecode(parsed);
    } catch (_) {
      return const [];
    }
  }
  if (parsed is List) {
    return parsed.map((e) => asInt(e)).where((e) => e > 0).toList();
  }
  return const [];
}

/// 从消息 content（JSON 字符串）中提取文本内容。
String extractTextContent(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map && decoded['content'] != null) {
      return decoded['content'].toString();
    }
  } catch (_) {
    // 非 JSON 格式，按原始文本处理
  }
  return content;
}
