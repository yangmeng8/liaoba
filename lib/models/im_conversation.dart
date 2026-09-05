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
      id: (json['id'] as num?)?.toInt() ?? 0,
      friendUserId: (json['friendUserId'] as num?)?.toInt() ?? 0,
      silent: json['silent'] == true,
      displayName: json['displayName']?.toString() ?? '',
      pinned: json['pinned'] == true,
      blocked: json['blocked'] == true,
      status: (json['status'] as num?)?.toInt() ?? 0,
      nickname: json['nickname']?.toString() ?? '',
      avatar: json['avatar']?.toString() ?? '',
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
      id: (json['id'] as num?)?.toInt() ?? 0,
      name: json['name']?.toString() ?? '',
      ownerUserId: (json['ownerUserId'] as num?)?.toInt() ?? 0,
      avatar: json['avatar']?.toString() ?? '',
      notice: json['notice']?.toString() ?? '',
      mutedAll: json['mutedAll'] == true,
      joinStatus: (json['joinStatus'] as num?)?.toInt() ?? 0,
      groupRemark: json['groupRemark']?.toString() ?? '',
      silent: json['silent'] == true,
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
      id: (json['id'] as num?)?.toInt() ?? 0,
      conversationType:
          ImConversationType.fromValue((json['conversationType'] as num?)?.toInt()),
      targetId: (json['targetId'] as num?)?.toInt() ?? 0,
      messageId: (json['messageId'] as num?)?.toInt() ?? 0,
      updateTime: DateTime.tryParse(json['updateTime']?.toString() ?? ''),
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
