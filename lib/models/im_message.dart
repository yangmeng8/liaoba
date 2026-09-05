import 'dart:convert';

import '../services/auth_manager.dart';

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
      id: (json['id'] as num?)?.toInt() ?? 0,
      clientMessageId: json['clientMessageId']?.toString() ?? '',
      senderId: (json['senderId'] as num?)?.toInt() ?? 0,
      receiverId: (json['receiverId'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      content: json['content']?.toString() ?? '',
      status: (json['status'] as num?)?.toInt() ?? 0,
      receiptStatus: (json['receiptStatus'] as num?)?.toInt() ?? 0,
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
      id: (json['id'] as num?)?.toInt() ?? 0,
      clientMessageId: json['clientMessageId']?.toString() ?? '',
      senderId: (json['senderId'] as num?)?.toInt() ?? 0,
      groupId: (json['groupId'] as num?)?.toInt() ?? 0,
      type: (json['type'] as num?)?.toInt() ?? 0,
      content: json['content']?.toString() ?? '',
      status: (json['status'] as num?)?.toInt() ?? 0,
      sendTime: parseDateTime(json['sendTime']),
      atUserIds: parseIntList(json['atUserIds']),
      receiverUserIds: parseIntList(json['receiverUserIds']),
      receiptStatus: (json['receiptStatus'] as num?)?.toInt() ?? 0,
      readCount: (json['readCount'] as num?)?.toInt() ?? 0,
    );
  }

  /// 是否自己发送（区分气泡左右方向）。
  bool get isSelf => senderId == AuthManager.instance.userId;

  /// 消息文本：content 为 JSON 字符串（文本消息形如 {"content":"你好"}），
  /// 解析失败时回退为原始字符串。
  String get textContent => extractTextContent(content);
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
    return parsed
        .map((e) => (e as num?)?.toInt() ?? 0)
        .where((e) => e > 0)
        .toList();
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
