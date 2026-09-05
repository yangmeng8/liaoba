import '../shared/json_utils.dart';

/// 会话类型（对应后端 ImConversationTypeEnum：1=私聊 2=群聊 3=频道）。
enum ImConversationType {
  private(1),
  group(2),
  channel(3);

  final int value;
  const ImConversationType(this.value);

  static ImConversationType fromValue(int? value) {
    return switch (value) {
      2 => ImConversationType.group,
      3 => ImConversationType.channel,
      _ => ImConversationType.private,
    };
  }
}

/// 好友（对应后端 FriendRespVO）。
class ImFriend {
  final int id;
  final int friendUserId;
  final bool silent;
  final String displayName;
  final bool pinned;
  final bool blocked;
  final int status;
  final String nickname;
  final String avatar;

  const ImFriend({
    required this.id,
    required this.friendUserId,
    required this.silent,
    required this.displayName,
    required this.pinned,
    required this.blocked,
    required this.status,
    required this.nickname,
    required this.avatar,
  });

  factory ImFriend.fromJson(Map<String, dynamic> json) {
    return ImFriend(
      id: asInt(json['id']),
      friendUserId: asInt(json['friendUserId']),
      silent: asBool(json['silent']),
      displayName: asString(json['displayName']),
      pinned: asBool(json['pinned']),
      blocked: asBool(json['blocked']),
      status: asInt(json['status']),
      nickname: asString(json['nickname']),
      avatar: asString(json['avatar']),
    );
  }

  /// 展示名：备注（仅自己可见）优先，其次好友昵称。
  String get shownName =>
      displayName.isNotEmpty ? displayName : (nickname.isNotEmpty ? nickname : '用户$friendUserId');
}

/// 群（对应后端 GroupRespVO）。
class ImGroup {
  final int id;
  final String name;
  final int ownerUserId;
  final String avatar;
  final String notice;
  final bool mutedAll;
  final int joinStatus;
  final String groupRemark;
  final bool silent;

  const ImGroup({
    required this.id,
    required this.name,
    required this.ownerUserId,
    required this.avatar,
    required this.notice,
    required this.mutedAll,
    required this.joinStatus,
    required this.groupRemark,
    required this.silent,
  });

  factory ImGroup.fromJson(Map<String, dynamic> json) {
    return ImGroup(
      id: asInt(json['id']),
      name: asString(json['name']),
      ownerUserId: asInt(json['ownerUserId']),
      avatar: asString(json['avatar']),
      notice: asString(json['notice']),
      mutedAll: asBool(json['mutedAll']),
      joinStatus: asInt(json['joinStatus']),
      groupRemark: asString(json['groupRemark']),
      silent: asBool(json['silent']),
    );
  }

  /// 展示名：我的群备注优先，其次群名称。
  String get shownName =>
      groupRemark.isNotEmpty ? groupRemark : (name.isNotEmpty ? name : '群$id');
}

/// 会话读位置（对应后端 ConversationReadRespVO）。
class ImConversationRead {
  final int id;
  final ImConversationType conversationType;
  final int targetId;
  final int messageId;
  final DateTime? updateTime;

  const ImConversationRead({
    required this.id,
    required this.conversationType,
    required this.targetId,
    required this.messageId,
    this.updateTime,
  });

  factory ImConversationRead.fromJson(Map<String, dynamic> json) {
    return ImConversationRead(
      id: asInt(json['id']),
      conversationType:
          ImConversationType.fromValue(asInt(json['conversationType'], -1)),
      targetId: asInt(json['targetId']),
      messageId: asInt(json['messageId']),
      updateTime: DateTime.tryParse(json['updateTime']?.toString() ?? ''),
    );
  }
}

/// 频道（对应后端 ImChannelRespVO）。
class ImChannel {
  final int id;
  final String code;
  final String name;
  final String avatar;
  final int sort;
  final int status;

  const ImChannel({
    required this.id,
    required this.code,
    required this.name,
    required this.avatar,
    required this.sort,
    required this.status,
  });

  factory ImChannel.fromJson(Map<String, dynamic> json) {
    return ImChannel(
      id: asInt(json['id']),
      code: asString(json['code']),
      name: asString(json['name']),
      avatar: asString(json['avatar']),
      sort: asInt(json['sort']),
      status: asInt(json['status']),
    );
  }
}

/// 客户端聚合出的会话（无服务端接口，由消息流 + 元数据计算）。
class ImConversation {
  final ImConversationType type;

  /// 私聊：对方用户编号；群聊：群编号。
  final int targetId;
  final String title;
  final String avatar;
  final String lastMessageText;
  final DateTime? lastMessageTime;
  final int unreadCount;
  final bool pinned;
  final bool silent;

  const ImConversation({
    required this.type,
    required this.targetId,
    required this.title,
    required this.avatar,
    required this.lastMessageText,
    required this.lastMessageTime,
    required this.unreadCount,
    required this.pinned,
    required this.silent,
  });

  /// 排序键：置顶优先，其余按最后消息时间倒序。
  int compareTo(ImConversation other) {
    if (pinned != other.pinned) return pinned ? -1 : 1;
    final a = lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    final b = other.lastMessageTime ?? DateTime.fromMillisecondsSinceEpoch(0);
    return b.compareTo(a);
  }
}
