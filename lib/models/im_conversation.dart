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

  /// 备注拼音（后端预计算下发，字母分桶/搜索用；空格分隔音节）。
  final String displayNamePinyin;

  /// 昵称拼音（后端预计算下发）。
  final String nicknamePinyin;

  /// 添加来源（1=搜索 2=群聊 3=扫码 4=名片）。
  final int addSource;

  /// 添加好友时间。
  final DateTime? addTime;

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
    this.displayNamePinyin = '',
    this.nicknamePinyin = '',
    this.addSource = 0,
    this.addTime,
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
      displayNamePinyin: asString(json['displayNamePinyin']),
      nicknamePinyin: asString(json['nicknamePinyin']),
      addSource: asInt(json['addSource']),
      addTime: DateTime.tryParse(asString(json['addTime'])),
    );
  }

  /// 展示名：备注（仅自己可见）优先，其次好友昵称。
  String get shownName =>
      displayName.isNotEmpty ? displayName : (nickname.isNotEmpty ? nickname : '用户$friendUserId');

  /// 添加来源文案。
  String get addSourceLabel => switch (addSource) {
    2 => '来自群聊',
    3 => '通过扫一扫',
    4 => '通过名片',
    _ => '通过搜索',
  };
}

/// 群角色（对应后端 ImGroupMemberRoleEnum）。
class ImGroupRole {
  /// 群主。
  static const int owner = 1;

  /// 管理员。
  static const int admin = 2;

  /// 普通成员。
  static const int normal = 3;
}

/// 通用状态（对应后端 CommonStatusEnum：0=有效 1=无效/退群）。
class ImCommonStatus {
  static const int enable = 0;
  static const int disable = 1;
}

/// 群（对应后端 GroupRespVO）。
class ImGroup {
  final int id;
  final String name;
  final int ownerUserId;
  final String avatar;
  final String notice;
  final bool mutedAll;

  /// 进群是否需群主/管理员审批。
  final bool joinApproval;

  /// 当前登录用户在该群的成员状态（0=在群 1=已退群，CommonStatusEnum）。
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
    this.joinApproval = false,
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
      joinApproval: asBool(json['joinApproval']),
      joinStatus: asInt(json['joinStatus']),
      groupRemark: asString(json['groupRemark']),
      silent: asBool(json['silent']),
    );
  }

  /// 是否已退群（历史群仍返回，供展示离线消息的群名/头像）。
  bool get quit => joinStatus == ImCommonStatus.disable;

  /// 展示名：我的群备注优先，其次群名称。
  String get shownName =>
      groupRemark.isNotEmpty ? groupRemark : (name.isNotEmpty ? name : '群$id');
}

/// 群成员（对应后端 ImGroupMemberRespVO）。
class ImGroupMember {
  final int userId;
  final String nickname;
  final String avatar;

  /// 组内显示名（我在本群的昵称）。
  final String displayUserName;

  /// 成员角色（ImGroupRole：1=群主 2=管理员 3=普通）。
  final int role;

  /// 成员状态（0=有效 1=已退群，CommonStatusEnum）。
  final int status;

  /// 禁言截止时间（null 或早于当前时间表示未禁言）。
  final DateTime? muteEndTime;

  const ImGroupMember({
    required this.userId,
    required this.nickname,
    required this.avatar,
    this.displayUserName = '',
    this.role = ImGroupRole.normal,
    this.status = ImCommonStatus.enable,
    this.muteEndTime,
  });

  factory ImGroupMember.fromJson(Map<String, dynamic> json) {
    return ImGroupMember(
      userId: asInt(json['userId']),
      nickname: asString(json['nickname']),
      avatar: asString(json['avatar']),
      displayUserName: asString(json['displayUserName']),
      role: asInt(json['role'], ImGroupRole.normal),
      status: asInt(json['status']),
      muteEndTime: DateTime.tryParse(json['muteEndTime']?.toString() ?? ''),
    );
  }

  /// 有效成员（未退群）。
  bool get active => status == ImCommonStatus.enable;

  /// 当前是否处于禁言中。
  bool get muted =>
      muteEndTime != null && muteEndTime!.isAfter(DateTime.now());

  /// 展示名：组内昵称优先，其次用户昵称。
  String get shownName =>
      displayUserName.isNotEmpty ? displayUserName : nickname;
}

/// 进群申请（对应后端 ImGroupRequestRespVO）。
class ImGroupRequest {
  final int id;
  final int groupId;
  final int userId;
  final int inviterUserId;

  /// 处理结果（0=待处理 1=同意 2=拒绝）。
  final int handleResult;
  final String applyContent;
  final String handleContent;
  final DateTime? handleTime;
  final DateTime? createTime;

  /// 申请人昵称/头像（后端冗余回填）。
  final String userNickname;
  final String userAvatar;

  const ImGroupRequest({
    required this.id,
    required this.groupId,
    required this.userId,
    this.inviterUserId = 0,
    required this.handleResult,
    this.applyContent = '',
    this.handleContent = '',
    this.handleTime,
    this.createTime,
    this.userNickname = '',
    this.userAvatar = '',
  });

  factory ImGroupRequest.fromJson(Map<String, dynamic> json) {
    return ImGroupRequest(
      id: asInt(json['id']),
      groupId: asInt(json['groupId']),
      userId: asInt(json['userId']),
      inviterUserId: asInt(json['inviterUserId']),
      handleResult: asInt(json['handleResult']),
      applyContent: asString(json['applyContent']),
      handleContent: asString(json['handleContent']),
      handleTime: DateTime.tryParse(json['handleTime']?.toString() ?? ''),
      createTime: DateTime.tryParse(json['createTime']?.toString() ?? ''),
      userNickname: asString(json['userNickname']),
      userAvatar: asString(json['userAvatar']),
    );
  }

  /// 展示名：申请人昵称兜底「用户N」。
  String get shownName =>
      userNickname.isNotEmpty ? userNickname : '用户$userId';

  /// 是否待处理。
  bool get pending => handleResult == 0;

  /// 处理结果文案。
  String get handleResultLabel => switch (handleResult) {
    1 => '已同意',
    2 => '已拒绝',
    _ => '待处理',
  };
}

/// 好友申请（对应后端 ImFriendRequestRespVO；list 返回「我相关」的双向列表）。
class ImFriendRequest {
  final int id;
  final int fromUserId;
  final int toUserId;

  /// 处理结果（0=未处理 1=同意 2=拒绝）。
  final int handleResult;
  final String applyContent;
  final String handleContent;

  /// 添加来源（1=搜索 2=群聊 3=扫码 4=名片）。
  final int addSource;
  final DateTime? handleTime;
  final DateTime? createTime;

  /// 申请/被申请人信息（后端冗余回填）。
  final String fromNickname;
  final String fromAvatar;
  final String toNickname;
  final String toAvatar;

  const ImFriendRequest({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.handleResult,
    this.applyContent = '',
    this.handleContent = '',
    this.addSource = 0,
    this.handleTime,
    this.createTime,
    this.fromNickname = '',
    this.fromAvatar = '',
    this.toNickname = '',
    this.toAvatar = '',
  });

  factory ImFriendRequest.fromJson(Map<String, dynamic> json) {
    return ImFriendRequest(
      id: asInt(json['id']),
      fromUserId: asInt(json['fromUserId']),
      toUserId: asInt(json['toUserId']),
      handleResult: asInt(json['handleResult']),
      applyContent: asString(json['applyContent']),
      handleContent: asString(json['handleContent']),
      addSource: asInt(json['addSource']),
      handleTime: DateTime.tryParse(json['handleTime']?.toString() ?? ''),
      createTime: DateTime.tryParse(json['createTime']?.toString() ?? ''),
      fromNickname: asString(json['fromNickname']),
      fromAvatar: asString(json['fromAvatar']),
      toNickname: asString(json['toNickname']),
      toAvatar: asString(json['toAvatar']),
    );
  }

  /// 是否待处理。
  bool get pending => handleResult == 0;

  /// 处理结果文案。
  String get handleResultLabel => switch (handleResult) {
    1 => '已同意',
    2 => '已拒绝',
    _ => '待处理',
  };
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

/// 频道素材详情（对应后端 ImChannelMaterialRespVO；content 为富文本 HTML）。
class ImChannelMaterial {
  final int id;
  final int channelId;
  final String title;
  final String coverUrl;
  final String summary;

  /// 富文本正文（HTML；客户端按纯文本清洗渲染）。
  final String content;

  /// 外链（非空时展示"查看原文"）。
  final String url;

  const ImChannelMaterial({
    required this.id,
    required this.channelId,
    required this.title,
    required this.coverUrl,
    required this.summary,
    required this.content,
    required this.url,
  });

  factory ImChannelMaterial.fromJson(Map<String, dynamic> json) {
    return ImChannelMaterial(
      id: asInt(json['id']),
      channelId: asInt(json['channelId']),
      title: asString(json['title']),
      coverUrl: asString(json['coverUrl']),
      summary: asString(json['summary']),
      content: asString(json['content']),
      url: asString(json['url']),
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
