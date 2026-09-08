import 'dart:convert';
import 'dart:math';

import '../models/im_message.dart';
import '../services/auth_manager.dart';
import '../shared/json_utils.dart';

/// 本地消息状态（乐观更新状态机）：
/// sending（占位转圈）→ sent（服务端确认）/ failed（可点击重试）。
enum ChatMessageStatus { sending, sent, failed }

/// 已知消息类型（对应后端 ImMessageContentTypeEnum，先列出已确认项）。
class ChatMsgType {
  /// 文本消息。
  static const int text = 101;

  /// 图片消息：content = {"url","width","height","size"}。
  static const int image = 102;

  /// 语音消息：content = {"url","duration","size"}。
  static const int voice = 103;

  /// 视频消息：content = {"url","coverUrl","duration","width","height","size"}。
  static const int video = 104;

  /// 文件消息：content = {"url","name","size","type"}。
  static const int file = 105;

  /// 图片表情消息：content = {"url","name","width","height"}。
  static const int face = 115;

  /// 好友添加通知（系统消息）。
  static const int friendAdded = 1204;
}

/// 语音消息 content 结构。
class VoicePayload {
  final String url;
  final int duration;

  const VoicePayload({required this.url, required this.duration});

  factory VoicePayload.fromJson(Map<String, dynamic> json) => VoicePayload(
    url: asString(json['url']),
    duration: asInt(json['duration']),
  );

  Map<String, dynamic> toJson() => {'url': url, 'duration': duration};
}

/// 图片消息 content 结构。
class ImagePayload {
  final String url;

  /// 缩略图（列表优先显示省流量，点开看原图；可能为空）。
  final String thumbnailUrl;
  final int width;
  final int height;
  final int size;

  const ImagePayload({
    required this.url,
    this.thumbnailUrl = '',
    this.width = 0,
    this.height = 0,
    this.size = 0,
  });

  factory ImagePayload.fromJson(Map<String, dynamic> json) => ImagePayload(
    url: asString(json['url']),
    thumbnailUrl: asString(json['thumbnailUrl']),
    width: asInt(json['width']),
    height: asInt(json['height']),
    size: asInt(json['size']),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'thumbnailUrl': thumbnailUrl,
    'width': width,
    'height': height,
    'size': size,
  };
}

/// 视频消息 content 结构。
class VideoPayload {
  final String url;
  final String coverUrl;
  final int duration;
  final int width;
  final int height;
  final int size;

  const VideoPayload({
    required this.url,
    this.coverUrl = '',
    this.duration = 0,
    this.width = 0,
    this.height = 0,
    this.size = 0,
  });

  factory VideoPayload.fromJson(Map<String, dynamic> json) => VideoPayload(
    url: asString(json['url']),
    coverUrl: asString(json['coverUrl']),
    duration: asInt(json['duration']),
    width: asInt(json['width']),
    height: asInt(json['height']),
    size: asInt(json['size']),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'coverUrl': coverUrl,
    'duration': duration,
    'width': width,
    'height': height,
    'size': size,
  };
}

/// 文件消息 content 结构。
class FilePayload {
  final String url;
  final String name;
  final int size;
  final String type;

  const FilePayload({
    required this.url,
    required this.name,
    this.size = 0,
    this.type = '',
  });

  factory FilePayload.fromJson(Map<String, dynamic> json) => FilePayload(
    url: asString(json['url']),
    name: asString(json['name']),
    size: asInt(json['size']),
    type: asString(json['type']),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'size': size,
    'type': type,
  };
}

/// 图片表情消息 content 结构。
class FacePayload {
  final String url;
  final String name;
  final int width;
  final int height;

  const FacePayload({
    required this.url,
    this.name = '',
    this.width = 200,
    this.height = 200,
  });

  factory FacePayload.fromJson(Map<String, dynamic> json) => FacePayload(
    url: asString(json['url']),
    name: asString(json['name']),
    width: asInt(json['width'], 200),
    height: asInt(json['height'], 200),
  );

  Map<String, dynamic> toJson() => {
    'url': url,
    'name': name,
    'width': width,
    'height': height,
  };
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

  /// 上传进度（0.0~1.0，null 表示无进度跟踪或已完成）。
  final double? progress;

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
    this.progress,
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

  /// 本地语音占位（上传完成前转圈）。
  factory ChatMessage.localVoice({
    required String clientMessageId,
    required VoicePayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.voice,
    content: jsonEncode(payload.toJson()),
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    isSelf: true,
  );

  /// 本地表情占位（本地即时显示，服务端确认后替换）。
  factory ChatMessage.localFace({
    required String clientMessageId,
    required FacePayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.face,
    content: jsonEncode(payload.toJson()),
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    isSelf: true,
  );

  /// 本地图片占位（url 先放本地路径，上传期间直接预览）。
  factory ChatMessage.localImage({
    required String clientMessageId,
    required ImagePayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.image,
    content: jsonEncode(payload.toJson()),
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    progress: 0.0,
    isSelf: true,
  );

  /// 本地视频占位（url 先放本地路径，上传期间显示封面预览）。
  factory ChatMessage.localVideo({
    required String clientMessageId,
    required VideoPayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.video,
    content: jsonEncode(payload.toJson()),
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    progress: 0.0,
    isSelf: true,
  );

  /// 本地文件占位（url 先放本地路径）。
  factory ChatMessage.localFile({
    required String clientMessageId,
    required FilePayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.file,
    content: jsonEncode(payload.toJson()),
    sendTime: DateTime.now(),
    status: ChatMessageStatus.sending,
    progress: 0.0,
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
    progress: progress,
    isSelf: isSelf,
  );

  /// 替换 content（上传成功后本地路径 → 远程 URL）。
  ChatMessage withContent(String newContent) => ChatMessage(
    id: id,
    clientMessageId: clientMessageId,
    senderId: senderId,
    type: type,
    content: newContent,
    sendTime: sendTime,
    status: status,
    progress: progress,
    isSelf: isSelf,
  );

  /// 更新上传进度。
  ChatMessage withProgress(double? p) => ChatMessage(
    id: id,
    clientMessageId: clientMessageId,
    senderId: senderId,
    type: type,
    content: content,
    sendTime: sendTime,
    status: status,
    progress: p,
    isSelf: isSelf,
  );

  /// 唯一 key：服务端消息用 id，本地占位用 clientMessageId（去重/替换用）。
  String get key => id != null ? 's$id' : 'c$clientMessageId';

  /// 解析后的 content Map（解析失败返回空 Map）。
  Map<String, dynamic> get contentMap {
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {
      // 非 JSON
    }
    return const {};
  }

  /// 语音消息 payload（非语音消息返回 null）。
  VoicePayload? get voicePayload => type == ChatMsgType.voice
      ? (contentMap['url'] != null && contentMap['url'].toString().isNotEmpty
            ? VoicePayload.fromJson(contentMap)
            : null)
      : null;

  /// 表情消息 payload（非表情消息返回 null）。
  FacePayload? get facePayload => type == ChatMsgType.face
      ? (contentMap['url'] != null && contentMap['url'].toString().isNotEmpty
            ? FacePayload.fromJson(contentMap)
            : null)
      : null;

  /// 图片消息 payload（非图片消息返回 null）。
  ImagePayload? get imagePayload => type == ChatMsgType.image
      ? (contentMap['url'] != null && contentMap['url'].toString().isNotEmpty
            ? ImagePayload.fromJson(contentMap)
            : null)
      : null;

  /// 视频消息 payload（非视频消息返回 null）。
  VideoPayload? get videoPayload => type == ChatMsgType.video
      ? (contentMap['url'] != null && contentMap['url'].toString().isNotEmpty
            ? VideoPayload.fromJson(contentMap)
            : null)
      : null;

  /// 文件消息 payload（非文件消息返回 null）。
  FilePayload? get filePayload => type == ChatMsgType.file
      ? (contentMap['url'] != null && contentMap['url'].toString().isNotEmpty
            ? FilePayload.fromJson(contentMap)
            : null)
      : null;

  /// 是否可长按操作（文本消息 + 已被服务端确认）。
  bool get operable =>
      isSelf && type == ChatMsgType.text && status == ChatMessageStatus.sent;

  /// 展示文本：文本消息取内层文本；系统/群事件等非文本类型给友好文案。
  String get displayText {
    switch (type) {
      case ChatMsgType.text:
        return extractTextContent(content);
      case ChatMsgType.voice:
        return '[语音]';
      case ChatMsgType.image:
        return '[图片]';
      case ChatMsgType.video:
        return '[视频]';
      case ChatMsgType.file:
        return '[文件]';
      case ChatMsgType.face:
        return '[表情]';
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
      type != ChatMsgType.voice &&
      type != ChatMsgType.image &&
      type != ChatMsgType.video &&
      type != ChatMsgType.file &&
      type != ChatMsgType.face &&
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
