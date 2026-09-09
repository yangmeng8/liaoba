import 'dart:convert';

import '../services/auth_manager.dart';
import '../shared/json_utils.dart';
import 'im_conversation.dart';

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

  /// 是否已被撤回（对应后端 ImMessageStatusEnum.RECALL = 2）。
  bool get isRecalled => status == 2;

  /// 消息文本：content 为 JSON 字符串（文本消息形如 {"content":"你好"}），
  /// 解析失败时回退为原始字符串；RTC 通话消息给通话摘要。
  String get textContent {
    if (isRecalled) return '[消息已撤回]';
    if (type == ImRtcMessageType.callStart || type == ImRtcMessageType.callEnd) {
      return resolveRtcCallLastContent(
        type,
        content,
        ImConversationType.private.value,
      );
    }
    if (type == ImSystemMessageType.friendDelete) return '你已删除好友';
    if (type == ImSystemMessageType.recall) return '[消息已撤回]';
    return extractTextContent(content);
  }
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

  /// 是否已被撤回（对应后端 ImMessageStatusEnum.RECALL = 2）。
  bool get isRecalled => status == 2;

  /// 消息文本：content 为 JSON 字符串（文本消息形如 {"content":"你好"}），
  /// 解析失败时回退为原始字符串；RTC 通话消息给通话摘要；
  /// 群广播事件给结构化文案（会话列表无成员缓存，人名以「用户N」兜底）。
  String get textContent {
    if (isRecalled) return '[消息已撤回]';
    if (type == ImRtcMessageType.callStart || type == ImRtcMessageType.callEnd) {
      return resolveRtcCallLastContent(
        type,
        content,
        ImConversationType.group.value,
      );
    }
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
    if (type == ImSystemMessageType.recall) return '[消息已撤回]';
    return extractTextContent(content);
  }
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

/// RTC 通话系统消息类型（对应后端 ImContentTypeEnum；服务端通话落库消息，
/// 走与普通消息相同的拉取/WebSocket 通道，历史记录可见）。
class ImRtcMessageType {
  /// 通话开始（仅群聊落库；私聊 START 不入消息流）。
  static const int callStart = 1610;

  /// 通话结束（私聊/群聊均落库；senderId 始终为通话发起人）。
  static const int callEnd = 1611;
}

/// 系统消息类型（对应后端 ImContentTypeEnum）。
class ImSystemMessageType {
  /// 好友添加通知（私聊落库）。
  static const int friendAdd = 1204;

  /// 好友删除通知（私聊落库）。
  static const int friendDelete = 1205;

  /// 撤回信号消息：content = {messageId} 指向被撤回原消息。
  /// 原消息 status 同步改为 RECALL(2)；信号消息本身不渲染。
  static const int recall = 2101;
}

/// 群广播事件类型（1501~1533，服务端群操作时自动落库推全群；
/// 1530 仅触发群资料刷新不显示提示，故不在范围内）。
class ImGroupNotificationType {
  static const int groupCreate = 1501;
  static const int groupInfoUpdate = 1502;
  static const int groupMemberQuit = 1504;
  static const int groupOwnerTransfer = 1507;
  static const int groupMemberKick = 1508;
  static const int groupMemberInvite = 1509;
  static const int groupMemberEnter = 1510;
  static const int groupDissolve = 1511;
  static const int groupMemberMuted = 1512;
  static const int groupMemberCancelMuted = 1513;
  static const int groupMuted = 1514;
  static const int groupCancelMuted = 1515;
  static const int groupMemberNicknameUpdate = 1516;
  static const int groupAdminAdd = 1517;
  static const int groupAdminRemove = 1518;
  static const int groupNoticeUpdate = 1519;
  static const int groupNameUpdate = 1520;
  static const int groupMessagePin = 1531;
  static const int groupMessageUnpin = 1532;
  static const int groupBanned = 1533;
}

/// 是否群广播事件类型（居中灰条渲染范围）。
bool isGroupNotificationType(int type) =>
    type >= ImGroupNotificationType.groupCreate && type <= 1533;

/// 系统提示分段（对齐 H5 TipSegment）：text=灰字，mention=高亮蓝字（人名）。
/// content 只存 userId，名字由渲染方运行时解析（改昵称后历史提示自动更新）。
class TipSegment {
  final String text;
  final int? userId;

  const TipSegment._(this.text, this.userId);

  /// 灰字片段。
  factory TipSegment.text(String text) => TipSegment._(text, null);

  /// 人名片段（高亮显示）。
  factory TipSegment.mention(int userId, String name) =>
      TipSegment._(name, userId);

  bool get isMention => userId != null;
}

/// 分段拼接为纯文本（会话列表摘要等场景）。
String segmentsToText(List<TipSegment> segments) =>
    segments.map((s) => s.text).join();

/// 群广播事件 content（字段对齐后端各通知子类的并集；
/// 名字不入库，只存 userId）。
class GroupNotificationPayload {
  final int operatorUserId;
  final List<int> memberUserIds;
  final int newOwnerUserId;
  final String newName;
  final String newNotice;
  final bool newAvatar;
  final String displayUserName;
  final int mutedUserId;
  final int entrantUserId;
  final bool banned;

  const GroupNotificationPayload({
    this.operatorUserId = 0,
    this.memberUserIds = const [],
    this.newOwnerUserId = 0,
    this.newName = '',
    this.newNotice = '',
    this.newAvatar = false,
    this.displayUserName = '',
    this.mutedUserId = 0,
    this.entrantUserId = 0,
    this.banned = false,
  });

  factory GroupNotificationPayload.fromJson(Map<String, dynamic> json) =>
      GroupNotificationPayload(
        operatorUserId: asInt(json['operatorUserId']),
        memberUserIds: parseIntList(json['memberUserIds']),
        newOwnerUserId: asInt(json['newOwnerUserId']),
        newName: asString(json['newName']),
        newNotice: asString(json['newNotice']),
        // 换头像事件无明确布尔标记，用 newAvatar 字段非空判断（后端传头像 URL）
        newAvatar: json['newAvatar'] != null && json['newAvatar'] != '',
        displayUserName: asString(json['displayUserName']),
        mutedUserId: asInt(json['mutedUserId']),
        entrantUserId: asInt(json['entrantUserId']),
        banned: asBool(json['banned']),
      );
}

/// 解析群广播事件 content；非 JSON 返回 null。
GroupNotificationPayload? parseGroupNotificationPayload(String? content) {
  if (content == null || content.isEmpty) return null;
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return GroupNotificationPayload.fromJson(decoded);
    }
  } catch (_) {
    // 非 JSON 格式
  }
  return null;
}

/// 群广播事件结构化文案（对齐 H5 resolveGroupNotificationSegments：
/// 22 种事件映射；名字运行时解析；payload 缺操作者返回空）。
List<TipSegment> resolveGroupNotificationSegments(
  int type,
  GroupNotificationPayload? payload,
  String Function(int userId) resolveName,
) {
  if (payload == null) return const [];
  // 特例：入群用 entrantUserId（入群者本人），无操作者概念
  if (type == ImGroupNotificationType.groupMemberEnter) {
    final entrantId = payload.entrantUserId != 0
        ? payload.entrantUserId
        : payload.operatorUserId;
    if (entrantId == 0) return const [];
    return [
      TipSegment.mention(entrantId, resolveName(entrantId)),
      TipSegment.text(' 加入了群聊'),
    ];
  }
  final operatorId = payload.operatorUserId;
  if (operatorId == 0) return const [];
  final operator = TipSegment.mention(operatorId, resolveName(operatorId));
  final members = payload.memberUserIds
      .map((id) => TipSegment.mention(id, resolveName(id)))
      .toList();
  switch (type) {
    case ImGroupNotificationType.groupCreate:
      return [operator, TipSegment.text(' 创建了群聊')];
    case ImGroupNotificationType.groupNameUpdate:
      return [operator, TipSegment.text(' 将群名修改为 "${payload.newName}"')];
    case ImGroupNotificationType.groupNoticeUpdate:
      return [operator, TipSegment.text(' 更新了群公告')];
    case ImGroupNotificationType.groupInfoUpdate:
      return [
        operator,
        TipSegment.text(payload.newAvatar ? ' 更换了群头像' : ' 更新了群信息'),
      ];
    case ImGroupNotificationType.groupDissolve:
      return [operator, TipSegment.text(' 解散了群聊')];
    case ImGroupNotificationType.groupMemberInvite:
      return [
        operator,
        TipSegment.text(' 邀请 '),
        ...members,
        TipSegment.text(' 加入群聊'),
      ];
    case ImGroupNotificationType.groupMemberQuit:
      return [operator, TipSegment.text(' 退出了群聊')];
    case ImGroupNotificationType.groupMemberKick:
      return [operator, TipSegment.text(' 移出了 '), ...members];
    case ImGroupNotificationType.groupMemberNicknameUpdate:
      return [
        operator,
        TipSegment.text(' 修改群昵称为 "${payload.displayUserName}"'),
      ];
    case ImGroupNotificationType.groupAdminAdd:
      return [
        operator,
        TipSegment.text(' 将 '),
        ...members,
        TipSegment.text(' 设为管理员'),
      ];
    case ImGroupNotificationType.groupAdminRemove:
      return [
        operator,
        TipSegment.text(' 撤销了 '),
        ...members,
        TipSegment.text(' 的管理员身份'),
      ];
    case ImGroupNotificationType.groupOwnerTransfer:
      if (payload.newOwnerUserId == 0) return const [];
      return [
        operator,
        TipSegment.text(' 已将群主转让给 '),
        TipSegment.mention(
          payload.newOwnerUserId,
          resolveName(payload.newOwnerUserId),
        ),
      ];
    case ImGroupNotificationType.groupMessagePin:
      return [operator, TipSegment.text(' 置顶了一条消息')];
    case ImGroupNotificationType.groupMessageUnpin:
      return [operator, TipSegment.text(' 取消了一条置顶消息')];
    case ImGroupNotificationType.groupMemberMuted:
      if (payload.mutedUserId == 0) return const [];
      return [
        operator,
        TipSegment.text(' 将 '),
        TipSegment.mention(
          payload.mutedUserId,
          resolveName(payload.mutedUserId),
        ),
        TipSegment.text(' 禁言'),
      ];
    case ImGroupNotificationType.groupMemberCancelMuted:
      if (payload.mutedUserId == 0) return const [];
      return [
        operator,
        TipSegment.text(' 解除了 '),
        TipSegment.mention(
          payload.mutedUserId,
          resolveName(payload.mutedUserId),
        ),
        TipSegment.text(' 的禁言'),
      ];
    case ImGroupNotificationType.groupMuted:
      return [operator, TipSegment.text(' 开启了全群禁言')];
    case ImGroupNotificationType.groupCancelMuted:
      return [operator, TipSegment.text(' 关闭了全群禁言')];
    case ImGroupNotificationType.groupBanned:
      return [
        operator,
        TipSegment.text(payload.banned ? ' 封禁了该群' : ' 解封了该群'),
      ];
    default:
      return const [];
  }
}

/// 好友关系事件文案（对齐 H5 resolveFriendNotificationSegments）。
List<TipSegment> resolveFriendNotificationSegments(int type) {
  switch (type) {
    case ImSystemMessageType.friendAdd:
      return [TipSegment.text('你们已经是好友了，开始聊天吧')];
    case ImSystemMessageType.friendDelete:
      return [TipSegment.text('你已删除好友')];
    default:
      return const [];
  }
}

/// RTC 通话媒体类型（对应后端 ImRtcCallMediaTypeEnum）。
class ImRtcMediaType {
  static const int voice = 1;
  static const int video = 2;
}

/// RTC 通话结束原因（对应后端 ImRtcCallEndReasonEnum）。
class ImRtcEndReason {
  /// 接通后任一方主动挂断。
  static const int hangup = 1;

  /// 被叫接通前点拒接。
  static const int reject = 2;

  /// 主叫接通前主动取消。
  static const int cancel = 3;

  /// 振铃超时未接通。
  static const int noAnswer = 4;

  /// 私聊呼叫时对方在另一通话。
  static const int busy = 5;

  /// 网络中断、设备失败等。
  static const int error = 9;
}

/// RTC 通话消息 content（1610 START 与 1611 END 两类 payload 的并集）。
class RtcCallPayload {
  /// 业务通话编号。
  final String room;

  /// 会话类型（ImConversationType：1=私聊 2=群聊）。
  final int conversationType;

  /// 媒体类型（ImRtcMediaType）。
  final int mediaType;

  /// 结束原因（ImRtcEndReason；仅 END 消息）。
  final int endReason;

  /// 通话时长（秒）；未接通为 0。
  final int durationSeconds;

  /// 结束操作者（触发结束的人；webhook 兜底时为 0）。
  final int operatorUserId;

  /// 结束操作者昵称（可空）。
  final String operatorNickname;

  /// 发起人编号（仅 START 消息）。
  final int inviterUserId;

  /// 发起人昵称（可空；群聊 tip 文案用，缺失回退「用户N」）。
  final String inviterNickname;

  const RtcCallPayload({
    this.room = '',
    this.conversationType = 0,
    this.mediaType = 0,
    this.endReason = 0,
    this.durationSeconds = 0,
    this.operatorUserId = 0,
    this.operatorNickname = '',
    this.inviterUserId = 0,
    this.inviterNickname = '',
  });

  factory RtcCallPayload.fromJson(Map<String, dynamic> json) =>
      RtcCallPayload(
        room: asString(json['room']),
        conversationType: asInt(json['conversationType']),
        mediaType: asInt(json['mediaType']),
        endReason: asInt(json['endReason']),
        durationSeconds: asInt(json['durationSeconds']),
        operatorUserId: asInt(json['operatorUserId']),
        operatorNickname: asString(json['operatorNickname']),
        inviterUserId: asInt(json['inviterUserId']),
        inviterNickname: asString(json['inviterNickname']),
      );

  /// 是否视频通话。
  bool get isVideo => mediaType == ImRtcMediaType.video;

  /// 「语音通话 / 视频通话」文案。
  String get callTypeLabel => isVideo ? '视频通话' : '语音通话';

  /// 群聊居中提示文案（对齐 H5 resolveRtcCallTipSegments：
  /// START=「xx 发起了语音通话」，END=「语音通话已经结束」）。
  String groupTipText(int messageType) {
    if (messageType == ImRtcMessageType.callStart && inviterUserId > 0) {
      final name = inviterNickname.trim().isNotEmpty
          ? inviterNickname.trim()
          : '用户$inviterUserId';
      return '$name 发起了$callTypeLabel';
    }
    return '$callTypeLabel已经结束';
  }

  /// 私聊通话结束气泡文案（对齐 H5 resolveRtcCallPrivateBubbleText；
  /// operatorUserId 视角决定主语——同一消息主叫看「已取消」、被叫看「对方已取消」）。
  String privateBubbleText(int myUserId) {
    final hasDuration = durationSeconds > 0;
    final isOperator = operatorUserId == myUserId;
    switch (endReason) {
      case ImRtcEndReason.hangup:
        return hasDuration
            ? '通话时长 ${formatCallDuration(durationSeconds)}'
            : '通话中断';
      case ImRtcEndReason.cancel:
        return isOperator ? '已取消' : '对方已取消';
      case ImRtcEndReason.reject:
        return isOperator ? '已拒绝' : '对方已拒绝';
      case ImRtcEndReason.noAnswer:
        return isOperator ? '未接听' : '对方未接听';
      case ImRtcEndReason.busy:
        return isOperator ? '忙线未接听' : '对方忙线中';
      case ImRtcEndReason.error:
        return hasDuration
            ? '通话中断 ${formatCallDuration(durationSeconds)}'
            : '通话中断';
      default:
        return hasDuration
            ? '通话时长 ${formatCallDuration(durationSeconds)}'
            : '通话已结束';
    }
  }
}

/// 通话时长格式化：mm:ss，超 1 小时变 h:mm:ss（对齐 H5 formatCallDuration）。
String formatCallDuration(int seconds) {
  final total = seconds < 0 ? 0 : seconds;
  final hours = total ~/ 3600;
  final minutes = (total % 3600) ~/ 60;
  final remain = total % 60;
  String pad(int v) => v.toString().padLeft(2, '0');
  return hours > 0
      ? '$hours:${pad(minutes)}:${pad(remain)}'
      : '${pad(minutes)}:${pad(remain)}';
}

/// 解析 RTC 通话消息 content；非 JSON 或空返回 null。
RtcCallPayload? parseRtcCallPayload(String? content) {
  if (content == null || content.isEmpty) return null;
  try {
    final decoded = jsonDecode(content);
    if (decoded is Map<String, dynamic>) {
      return RtcCallPayload.fromJson(decoded);
    }
  } catch (_) {
    // 非 JSON 格式
  }
  return null;
}

/// 会话列表 RTC 摘要（对齐 H5 resolveRtcCallLastContent）：
/// 私聊 → [语音通话]（微信风格方括号）；群聊 → 发起/结束文案。
String resolveRtcCallLastContent(int messageType, String content, int conversationType) {
  final payload = parseRtcCallPayload(content);
  final callType = payload?.isVideo == true ? '视频通话' : '语音通话';
  if (conversationType == ImConversationType.private.value) {
    return '[$callType]';
  }
  if (messageType == ImRtcMessageType.callEnd) {
    return '$callType已经结束';
  }
  if (messageType == ImRtcMessageType.callStart && payload != null) {
    final name = payload.inviterNickname.trim().isNotEmpty
        ? payload.inviterNickname.trim()
        : '用户${payload.inviterUserId}';
    return '$name 发起了$callType';
  }
  return '';
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
