import 'dart:math';

import '../models/im_message.dart';
import '../services/auth_manager.dart';

/// 本地消息状态（乐观更新状态机）：
/// sending（占位转圈）→ sent（服务端确认）/ failed（可点击重试）。
enum ChatMessageStatus { sending, sent, failed }

/// 已知消息类型（对应后端 ImMessageContentTypeEnum，先列出已确认项）。
class ChatMsgType {
  /// 文本消息。
  static const int text = 101;

  /// 好友添加通知（系统消息）。
  static const int friendAdded = 1204;
}

/// 聊天页统一消息模型：
/// 私聊/群聊/频道三类服务端 VO + 本地发送占位消息，统一供气泡渲染。
class ChatMessage {
  /// 服务端消息编号（本地占位消息为 null）。
  final int? id;

  /// 客户端消息编号（幂等去重键：发送前本地生成，服务端透传）。
  final String clientMessageId;

  /// 发送人（频道广播消息无发送人，为 0）。
  final int senderId;

  /// 消息类型（101 文本 / 1204 好友通知 / 15xx 群事件...）。
  final int type;

  /// 消息内容（JSON 字符串，文本消息形如 {"content":"你好"}）。
  final String content;

  final DateTime? sendTime;

  /// 本地发送状态（服务端消息恒为 sent）。
  final ChatMessageStatus status;

  /// 是否自己发送（决定气泡左右方向）。
  final bool isSelf;

  const ChatMessage({
    required this.clientMessageId,
    required this.senderId,
    required this.type,
    required this.content,
    this.id,
    this.sendTime,
    this.status = ChatMessageStatus.sent,
    required this.isSelf,
  });

  /// 私聊 VO 转换。
  factory ChatMessage.fromPrivate(ImPrivateMessage m) => ChatMessage(
    id: m.id,
    clientMessageId: m.clientMessageId,
    senderId: m.senderId,
    type: m.type,
    content: m.content,
    sendTime: m.sendTime,
    isSelf: m.isSelf,
  );

  /// 群聊 VO 转换。
  factory ChatMessage.fromGroup(ImGroupMessage m) => ChatMessage(
    id: m.id,
    clientMessageId: m.clientMessageId,
    senderId: m.senderId,
    type: m.type,
    content: m.content,
    sendTime: m.sendTime,
    isSelf: m.isSelf,
  );

  /// 频道 VO 转换（频道为广播，无发送人，恒左侧展示）。
  factory ChatMessage.fromChannel(ImChannelMessage m) => ChatMessage(
    id: m.id,
    clientMessageId: 'channel-${m.id}',
    senderId: 0,
    type: m.type,
    content: m.content,
    sendTime: m.sendTime,
    isSelf: false,
  );

  /// 本地发送占位消息（status=sending，气泡显示转圈）。
  factory ChatMessage.localText({
    required String clientMessageId,
    required String text,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.text,
    content: '{"content":"${_jsonEscape(text)}"}',
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    isSelf: true,
  );

  /// 更新本地状态（占位 → sent/failed）。
  ChatMessage withStatus(ChatMessageStatus s) => ChatMessage(
    id: id,
    clientMessageId: clientMessageId,
    senderId: senderId,
    type: type,
    content: content,
    sendTime: sendTime,
    status: s,
    isSelf: isSelf,
  );

  /// 唯一 key：服务端消息用 id，本地占位用 clientMessageId（去重/替换用）。
  String get key => id != null ? 's$id' : 'c$clientMessageId';

  /// 是否可长按操作（文本消息 + 已被服务端确认）。
  bool get operable =>
      isSelf && type == ChatMsgType.text && status == ChatMessageStatus.sent;

  /// 展示文本：文本消息取内层文本；系统/群事件等非文本类型给友好文案。
  String get displayText {
    switch (type) {
      case ChatMsgType.text:
        return extractTextContent(content);
      case ChatMsgType.friendAdded:
        return '我们已成为好友，开始聊天吧';
      default:
        // 15xx 群事件、125 频道素材等：非聊天主体消息
        return '[暂不支持的消息类型]';
    }
  }

  /// 是否为居中灰字展示的系统类消息（好友通知、群事件等）。
  bool get isCenteredNotice =>
      !isSelf &&
      type != ChatMsgType.text &&
      status == ChatMessageStatus.sent &&
      senderId != 0; // 频道素材仍走气泡
}

/// 生成客户端消息编号（幂等键）：32 位随机 hex，对齐服务端样例格式。
String generateClientMessageId() {
  const hexChars = '0123456789abcdef';
  final r = Random();
  return List.generate(32, (_) => hexChars[r.nextInt(16)]).join();
}

String _jsonEscape(String s) {
  // 仅处理常见转义，足够文本消息序列化使用
  return s
      .replaceAll('\\', '\\\\')
      .replaceAll('"', '\\"')
      .replaceAll('\n', '\\n')
      .replaceAll('\r', '\\r')
      .replaceAll('\t', '\\t');
}
