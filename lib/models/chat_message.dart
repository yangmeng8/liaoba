import 'dart:convert';
import 'dart:math';

import '../models/im_conversation.dart';
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

  /// 名片消息：content = {"targetType","targetId","name","avatar","memberCount"}。
  static const int card = 108;

  /// 频道素材消息：content = {"materialId","channelId","title","coverUrl","summary","url"}。
  static const int material = 125;

  /// 好友添加通知（系统消息）。
  static const int friendAdded = 1204;

  /// 好友删除通知（系统消息）。
  static const int friendDeleted = 1205;

  /// 撤回信号消息：content = {messageId} 指向原消息，本身不渲染。
  static const int recallSignal = 2101;

  /// 通话开始系统消息（1610，仅群聊落库）。
  static const int rtcCallStart = 1610;

  /// 通话结束系统消息（1611，私聊/群聊均落库）。
  static const int rtcCallEnd = 1611;
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

/// 名片消息 content 结构（对齐 H5 CardMessage：
/// targetType 用 ImConversationType 值，群名片带 memberCount）。
class CardPayload {
  /// 名片目标类型（1=个人名片 2=群名片，ImConversationType）。
  final int targetType;

  /// 名片目标编号（用户编号 / 群编号）。
  final int targetId;
  final String name;
  final String avatar;

  /// 群成员数（仅群名片；个人名片为 0）。
  final int memberCount;

  const CardPayload({
    required this.targetType,
    required this.targetId,
    required this.name,
    this.avatar = '',
    this.memberCount = 0,
  });

  factory CardPayload.fromJson(Map<String, dynamic> json) => CardPayload(
    targetType: asInt(json['targetType']),
    targetId: asInt(json['targetId']),
    name: asString(json['name']),
    avatar: asString(json['avatar']),
    memberCount: asInt(json['memberCount']),
  );

  Map<String, dynamic> toJson() => {
    'targetType': targetType,
    'targetId': targetId,
    'name': name,
    'avatar': avatar,
    'memberCount': memberCount,
  };

  /// 是否群名片。
  bool get isGroupCard => targetType == ImConversationType.group.value;

  /// 名片标签文案（对齐 H5 getCardLabelInfo）。
  String get label => isGroupCard ? '群名片' : '个人名片';
}

/// 频道素材消息 content 结构（对齐 H5 MaterialMessage）：
/// 频道运营推送的图文卡片；url 非空为外链，否则按 materialId 拉详情。
class MaterialPayload {
  final int materialId;
  final int channelId;
  final String title;
  final String coverUrl;
  final String summary;
  final String url;

  const MaterialPayload({
    required this.materialId,
    required this.channelId,
    required this.title,
    this.coverUrl = '',
    this.summary = '',
    this.url = '',
  });

  factory MaterialPayload.fromJson(Map<String, dynamic> json) =>
      MaterialPayload(
        materialId: asInt(json['materialId']),
        channelId: asInt(json['channelId']),
        title: asString(json['title']),
        coverUrl: asString(json['coverUrl']),
        summary: asString(json['summary']),
        url: asString(json['url']),
      );
}

/// 引用信息（content JSON 的 quote 字段，对齐 H5 QuoteMessage）。
class QuotePayload {
  /// 被引用消息编号。
  final int messageId;

  /// 被引用消息发送人。
  final int senderId;

  /// 被引用消息类型（用于摘要文案 [图片]/[语音] 等）。
  final int type;

  /// 被引用消息原始 content（JSON 字符串，不带自身 quote）。
  final String content;

  const QuotePayload({
    required this.messageId,
    required this.senderId,
    required this.type,
    required this.content,
  });

  factory QuotePayload.fromJson(Map<String, dynamic> json) => QuotePayload(
    messageId: asInt(json['messageId']),
    senderId: asInt(json['senderId']),
    type: asInt(json['type'], ChatMsgType.text),
    content: asString(json['content']),
  );

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'senderId': senderId,
    'type': type,
    'content': content,
  };

  /// 引用摘要：文本取内层文本，其他类型给类型文案（截断 60 字符）。
  /// 注意非文本消息的 content 无 content 键，extractTextContent 会回退
  /// 返回原始 JSON（含 URL），因此非文本类型直接给类型标签。
  String get summary {
    if (type != ChatMsgType.text) {
      return '[${_typeLabel(type)}]';
    }
    final s = extractTextContent(content);
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 图片/表情引用的媒体地址（引用块渲染缩略图用；其余类型为 null）。
  String? get mediaUrl {
    if (type != ChatMsgType.image && type != ChatMsgType.face) return null;
    try {
      final decoded = jsonDecode(content);
      if (decoded is Map) {
        final url = decoded['url']?.toString() ?? '';
        if (url.isNotEmpty) return url;
      }
    } catch (_) {
      // 非 JSON：无缩略图
    }
    return null;
  }
}

String _typeLabel(int type) => switch (type) {
      ChatMsgType.voice => '语音',
      ChatMsgType.image => '图片',
      ChatMsgType.video => '视频',
      ChatMsgType.file => '文件',
      ChatMsgType.face => '表情',
      _ => '消息',
    };

/// 剥掉 content JSON 里的 quote 字段（转发/引用时避免嵌套引用）。
String stripQuote(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic> && decoded.containsKey('quote')) {
      final copy = Map<String, dynamic>.from(decoded)..remove('quote');
      return jsonEncode(copy);
    }
  } catch (_) {
    // 非 JSON：原样返回
  }
  return content;
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

  /// 群聊回执状态（仅群消息：发送时勾选回执，DONE=全部已读）。
  final int receiptStatus;

  /// 群聊已读人数（仅群消息）。
  final int readCount;

  /// 是否已被撤回（服务端消息 status=2；渲染成居中灰条）。
  final bool recalled;

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
    this.receiptStatus = 0,
    this.readCount = 0,
    this.recalled = false,
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
    recalled: m.isRecalled,
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
    receiptStatus: m.receiptStatus,
    readCount: m.readCount,
    recalled: m.isRecalled,
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

  /// 本地名片占位（推荐群聊/好友名片发送用）。
  factory ChatMessage.localCard({
    required String clientMessageId,
    required CardPayload payload,
  }) => ChatMessage(
    clientMessageId: clientMessageId,
    senderId: AuthManager.instance.userId ?? 0,
    type: ChatMsgType.card,
    content: jsonEncode(payload.toJson()),
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
    progress: progress,
    receiptStatus: receiptStatus,
    readCount: readCount,
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
    receiptStatus: receiptStatus,
    readCount: readCount,
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
    receiptStatus: receiptStatus,
    readCount: readCount,
    isSelf: isSelf,
  );

  /// 更新回执（已读人数/状态回写）。
  ChatMessage withReceipt({required int status, required int count}) =>
      ChatMessage(
        id: id,
        clientMessageId: clientMessageId,
        senderId: senderId,
        type: type,
        content: content,
        sendTime: sendTime,
        status: this.status,
        progress: progress,
        receiptStatus: status,
        readCount: count,
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

  /// 频道素材 content 解析（125）；非素材消息返回 null。
  MaterialPayload? get materialPayload =>
      type == ChatMsgType.material && contentMap['materialId'] != null
          ? MaterialPayload.fromJson(contentMap)
          : null;

  /// 名片消息 payload（非名片消息返回 null）。
  CardPayload? get cardPayload => type == ChatMsgType.card
      ? (contentMap['targetId'] != null &&
                contentMap['targetId'].toString().isNotEmpty
            ? CardPayload.fromJson(contentMap)
            : null)
      : null;

  /// 引用信息（content JSON 的 quote 字段，对齐 H5 Quotable）。
  QuotePayload? get quotePayload {
    final q = contentMap['quote'];
    if (q is! Map) return null;
    final quote = QuotePayload.fromJson(Map<String, dynamic>.from(q));
    return quote.messageId == 0 && quote.content.isEmpty ? null : quote;
  }

  /// 从本消息构造引用对象（回复/引用时序列化进新消息 content 的 quote 字段）。
  Map<String, dynamic> buildQuote() => {
    'messageId': id ?? 0,
    'senderId': senderId,
    'type': type,
    'content': stripQuote(content),
  };

  /// 是否可长按操作（正常聊天消息：服务端已确认；菜单项再逐项动态判断）。
  bool get operable =>
      id != null &&
      status == ChatMessageStatus.sent &&
      !recalled &&
      (type == ChatMsgType.text ||
          type == ChatMsgType.image ||
          type == ChatMsgType.voice ||
          type == ChatMsgType.video ||
          type == ChatMsgType.file ||
          type == ChatMsgType.face ||
          type == ChatMsgType.card);

  /// 是否可撤回：自己的消息 + 发送时间在撤回窗口内（对齐 H5 2 分钟窗口）。
  bool canRecall({Duration window = const Duration(minutes: 2)}) {
    if (id == null || !isSelf || status != ChatMessageStatus.sent) return false;
    if (recalled) return false; // 已撤回的不可重复撤回
    final t = sendTime;
    if (t == null) return false;
    return DateTime.now().difference(t) <= window;
  }

  /// 展示文本：文本消息取内层文本；系统/群事件等非文本类型给友好文案
  /// （群广播事件人名以「用户N」兜底，聊天室内富文本渲染时用真实名）。
  String get displayText {
    if (recalled) {
      return isSelf ? '你撤回了一条消息' : '[消息已撤回]';
    }
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
      case ChatMsgType.card:
        final card = cardPayload;
        return card != null ? '[${card.label}] ${card.name}' : '[名片]';
      case ChatMsgType.material:
        // 频道素材摘要（对齐 H5：[频道] 标题）
        final m = materialPayload;
        return m != null && m.title.isNotEmpty ? '[频道] ${m.title}' : '[频道]';
      case ChatMsgType.rtcCallStart:
      case ChatMsgType.rtcCallEnd:
        // 通话消息：按会话类型给摘要（私聊 [语音通话] / 群聊 tip 文案）
        final p = rtcCallPayload;
        if (p == null) return '[通话]';
        return resolveRtcCallLastContent(
          type,
          content,
          p.conversationType,
        );
      case ChatMsgType.friendAdded:
        return '你们已经是好友了，开始聊天吧';
      case ChatMsgType.friendDeleted:
        return '你已删除好友';
      default:
        // 群广播事件：结构化文案（纯文本口径）
        if (isGroupNotificationType(type)) {
          final text = segmentsToText(
            resolveGroupNotificationSegments(
              type,
              parseGroupNotificationPayload(content),
              (userId) => '用户$userId',
            ),
          );
          return text.isNotEmpty ? text : '[群通知]';
        }
        if (type == ChatMsgType.recallSignal) return '[消息已撤回]';
        // 其余未实现类型：非聊天主体消息
        return '[暂不支持的消息类型]';
    }
  }

  /// RTC 通话消息 content 解析（1610/1611）；非 RTC 消息返回 null。
  RtcCallPayload? get rtcCallPayload {
    if (type != ChatMsgType.rtcCallStart && type != ChatMsgType.rtcCallEnd) {
      return null;
    }
    return parseRtcCallPayload(content);
  }

  /// 是否私聊通话结束消息（渲染成电话气泡，点击可重拨；
  /// 对应 H5 privateRtcCallPayload 判定）。
  bool get isPrivateRtcCallEnd =>
      type == ChatMsgType.rtcCallEnd &&
      rtcCallPayload?.conversationType == ImConversationType.private.value;

  /// 是否为居中灰字展示的系统类消息（撤回提示、好友通知、群广播事件、
  /// 群通话 tip 等）。注意：撤回/群事件无论是否自己操作都居中。
  bool get isCenteredNotice {
    if (status != ChatMessageStatus.sent) return false;
    // 撤回的原消息：居中「你/xx 撤回了一条消息」
    if (recalled) return true;
    // RTC：群聊居中（senderId=发起人），私聊结束走电话气泡
    if (type == ChatMsgType.rtcCallStart || type == ChatMsgType.rtcCallEnd) {
      return !isPrivateRtcCallEnd;
    }
    // 群广播事件：居中（自己操作的也显示）
    if (isGroupNotificationType(type)) return true;
    // 好友关系事件 / 撤回信号（信号正常会被过滤，兜底居中）
    if (type == ChatMsgType.friendAdded ||
        type == ChatMsgType.friendDeleted ||
        type == ChatMsgType.recallSignal) {
      return true;
    }
    // 频道素材等：非聊天主体消息仍走气泡
    return !isSelf &&
        type != ChatMsgType.text &&
        type != ChatMsgType.voice &&
        type != ChatMsgType.image &&
        type != ChatMsgType.video &&
        type != ChatMsgType.file &&
        type != ChatMsgType.face &&
        senderId != 0;
  }
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
