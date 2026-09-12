import 'package:dio/dio.dart';

import 'api_client.dart';
import '../models/im_conversation.dart';
import '../models/im_face.dart';
import '../models/im_message.dart';
import '../shared/json_utils.dart';

/// IM 聊天相关接口。
class ImApi {
  /// 查询私聊历史消息。
  /// [receiverId] 对方用户编号；[limit] 每页条数；
  /// [maxId] 起始消息编号（不含），为空则从最新消息开始——
  /// 向上翻页时传当前已加载最早消息的 id。
  static Future<List<ImPrivateMessage>> getPrivateMessageList({
    required int receiverId,
    required int limit,
    int? maxId,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/private/list',
      queryParameters: {
        'receiverId': receiverId,
        'limit': limit,
        'maxId': ?maxId,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImPrivateMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 查询群聊历史消息。
  /// [groupId] 群编号；[limit] 每页条数；
  /// [maxId] 起始消息编号（不含），为空则从最新消息开始——
  /// 向上翻页时传当前已加载最早消息的 id。
  static Future<List<ImGroupMessage>> getGroupMessageList({
    required int groupId,
    required int limit,
    int? maxId,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/group/list',
      queryParameters: {'groupId': groupId, 'limit': limit, 'maxId': ?maxId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroupMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得当前登录用户的好友列表。
  static Future<List<ImFriend>> getFriendList() async {
    final resp = await ApiClient.dio.get('/admin-api/im/friend/list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImFriend.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得当前登录用户的群列表（含已退群的历史群，供展示群名/头像）。
  static Future<List<ImGroup>> getGroupList() async {
    final resp = await ApiClient.dio.get('/admin-api/im/group/list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroup.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得群成员列表（群聊消息发送者头像/昵称解析用）。
  static Future<List<ImGroupMember>> getGroupMemberList({
    required int groupId,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/group-member/list',
      queryParameters: {'groupId': groupId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroupMember.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得频道素材详情（频道素材消息点击后渲染正文）。
  static Future<ImChannelMaterial> getChannelMaterial({
    required int id,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/channel/material/get',
      queryParameters: {'id': id},
    );
    return ImChannelMaterial.fromJson(ApiClient.unwrap(resp));
  }

  /// ==================== 群设置页接口（对应后端 ImGroupController） ====================

  /// 获得群详情（含我的成员视角：joinStatus/groupRemark/silent）。
  static Future<ImGroup> getGroup({required int id}) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/group/get',
      queryParameters: {'id': id},
    );
    return ImGroup.fromJson(ApiClient.unwrap(resp));
  }

  /// 更新群（名称/头像/公告/进群审批；管理员权限）。
  static Future<void> updateGroup({
    required int id,
    String? name,
    String? avatar,
    String? notice,
    bool? joinApproval,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/update',
      data: {
        'id': id,
        if (name != null) 'name': name,
        if (avatar != null) 'avatar': avatar,
        if (notice != null) 'notice': notice,
        if (joinApproval != null) 'joinApproval': joinApproval,
      },
    );
  }

  /// 解散群（仅群主）。
  static Future<void> dissolveGroup({required int id}) async {
    await ApiClient.dio.delete(
      '/admin-api/im/group/dissolve',
      queryParameters: {'id': id},
    );
  }

  /// 邀请用户加入群。
  static Future<void> inviteGroupMembers({
    required int groupId,
    required List<int> memberUserIds,
  }) async {
    await ApiClient.dio.post(
      '/admin-api/im/group/invite',
      data: {'groupId': groupId, 'memberUserIds': memberUserIds},
    );
  }

  /// 退出群。
  static Future<void> quitGroup({required int groupId}) async {
    await ApiClient.dio.delete(
      '/admin-api/im/group/quit',
      queryParameters: {'groupId': groupId},
    );
  }

  /// 移除群成员（管理员权限）。
  static Future<void> kickGroupMembers({
    required int groupId,
    required List<int> memberUserIds,
  }) async {
    await ApiClient.dio.delete(
      '/admin-api/im/group/kicking',
      data: {'groupId': groupId, 'memberUserIds': memberUserIds},
    );
  }

  /// 添加群管理员（仅群主）。
  static Future<void> addGroupAdmins({
    required int id,
    required List<int> userIds,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/add-admin',
      data: {'id': id, 'userIds': userIds},
    );
  }

  /// 撤销群管理员（仅群主）。
  static Future<void> removeGroupAdmins({
    required int id,
    required List<int> userIds,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/remove-admin',
      data: {'id': id, 'userIds': userIds},
    );
  }

  /// 转让群主（仅群主）。
  static Future<void> transferGroupOwner({
    required int id,
    required int newOwnerUserId,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/transfer-owner',
      data: {'id': id, 'newOwnerUserId': newOwnerUserId},
    );
  }

  /// 全群禁言/取消（管理员权限）。
  static Future<void> muteGroupAll({
    required int id,
    required bool mutedAll,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/mute-all',
      data: {'id': id, 'mutedAll': mutedAll},
    );
  }

  /// 禁言成员（管理员权限；mutedSeconds=0 永久）。
  static Future<void> muteGroupMember({
    required int id,
    required int userId,
    required int mutedSeconds,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/mute-member',
      data: {'id': id, 'userId': userId, 'mutedSeconds': mutedSeconds},
    );
  }

  /// 取消成员禁言（管理员权限）。
  static Future<void> cancelMuteGroupMember({
    required int id,
    required int userId,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group/cancel-mute-member',
      data: {'id': id, 'userId': userId},
    );
  }

  /// 更新我的群成员信息（组内昵称/群备注/免打扰）。
  static Future<void> updateMyGroupMember({
    required int groupId,
    String? displayUserName,
    String? groupRemark,
    bool? silent,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group-member/update',
      data: {
        'groupId': groupId,
        if (displayUserName != null) 'displayUserName': displayUserName,
        if (groupRemark != null) 'groupRemark': groupRemark,
        if (silent != null) 'silent': silent,
      },
    );
  }

  /// ==================== 进群申请（对应后端 ImGroupRequestController） ====================

  /// 查询指定群的进群申请列表（管理员视角；含已处理记录）。
  static Future<List<ImGroupRequest>> getGroupRequestList({
    required int groupId,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/group-request/list-by-group',
      queryParameters: {'groupId': groupId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroupRequest.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 同意进群申请。
  static Future<void> agreeGroupRequest({required int id}) async {
    await ApiClient.dio.put(
      '/admin-api/im/group-request/agree',
      queryParameters: {'id': id},
    );
  }

  /// 拒绝进群申请。
  static Future<void> refuseGroupRequest({
    required int id,
    String handleContent = '',
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/group-request/refuse',
      queryParameters: {'id': id, 'handleContent': handleContent},
    );
  }

  /// 增量拉取私聊消息（写入本地缓存用；会话列表数据源）。
  /// [minId] 游标：拉取 id 大于 minId 的消息；首次传 0 全量拉取。
  static Future<List<ImPrivateMessage>> pullPrivateMessages({
    required int minId,
    required int size,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/private/pull',
      queryParameters: {'minId': minId, 'size': size},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImPrivateMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 增量拉取群聊消息（写入本地缓存用；会话列表数据源）。
  /// [minId] 游标：拉取 id 大于 minId 的消息；首次传 0 全量拉取。
  static Future<List<ImGroupMessage>> pullGroupMessages({
    required int minId,
    required int size,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/group/pull',
      queryParameters: {'minId': minId, 'size': size},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroupMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 增量拉取当前用户的会话读位置（未读数计算用）。
  /// [lastId] 游标；[limit] 每页条数。
  static Future<List<ImConversationRead>> pullConversationReads({
    int? lastId,
    required int limit,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/conversation-read/pull',
      queryParameters: {'lastId': ?lastId, 'limit': limit},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImConversationRead.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得启用的频道精简列表（频道会话的标题/头像来源）。
  static Future<List<ImChannel>> getChannelSimpleList() async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/manager/channel/simple-list',
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImChannel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 增量拉取频道消息（minId 游标，频道会话数据源）。
  static Future<List<ImChannelMessage>> pullChannelMessages({
    required int minId,
    required int size,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/channel/message/pull',
      queryParameters: {'minId': minId, 'size': size},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImChannelMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  // ==================== 消息发送（幂等） ====================

  /// 发送私聊消息。
  /// [clientMessageId] 客户端生成并随请求上报，服务端据此去重——
  /// 断网重试不会发出重复消息。返回落库后的服务端消息（失败抛异常）。
  static Future<ImPrivateMessage?> sendPrivateMessage({
    required String clientMessageId,
    required int receiverId,
    required int type,
    required String content,
    bool receipt = true,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/message/private/send',
      data: {
        'clientMessageId': clientMessageId,
        'receiverId': receiverId,
        'type': type,
        'content': content,
        'receipt': receipt,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is Map<String, dynamic>) {
      return ImPrivateMessage.fromJson(data);
    }
    return null; // 后端仅返回布尔等：保留本地消息为已发送态
  }

  /// 发送群聊消息（[atUserIds] @目标，文本消息为空列表）。
  static Future<ImGroupMessage?> sendGroupMessage({
    required String clientMessageId,
    required int groupId,
    required int type,
    required String content,
    List<int> atUserIds = const [],
    bool receipt = true,
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/message/group/send',
      data: {
        'clientMessageId': clientMessageId,
        'groupId': groupId,
        'type': type,
        'content': content,
        'atUserIds': atUserIds,
        'receipt': receipt,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is Map<String, dynamic>) {
      return ImGroupMessage.fromJson(data);
    }
    return null;
  }

  // ==================== 已读上报与对方已读位置 ====================

  /// 私聊已读上报（读到 [messageId]）。参数走 query（后端 @RequestParam）。
  static Future<void> markPrivateRead({
    required int receiverId,
    required int messageId,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/message/private/read',
      queryParameters: {'receiverId': receiverId, 'messageId': messageId},
    );
  }

  /// 群聊已读上报。
  static Future<void> markGroupRead({
    required int groupId,
    required int messageId,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/message/group/read',
      queryParameters: {'groupId': groupId, 'messageId': messageId},
    );
  }

  /// 频道已读上报。
  static Future<void> markChannelRead({
    required int channelId,
    required int messageId,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/channel/message/read',
      queryParameters: {'channelId': channelId, 'messageId': messageId},
    );
  }

  /// 查询私聊对方已读到的消息编号（自己消息下「已读/未读」小字用）。
  static Future<int> getPrivateMaxReadMessageId({required int peerId}) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/private/max-read-message-id',
      queryParameters: {'peerId': peerId},
    );
    return asInt(ApiClient.unwrap(resp));
  }

  /// 查询群消息已读用户编号列表（回执详情用；
  /// 未读列表由客户端拿群成员表做差集，一次请求出两个页签）。
  static Future<List<int>> getGroupMessageReadUserIds({
    required int groupId,
    required int messageId,
  }) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/message/group/get-read-user-ids',
      queryParameters: {'groupId': groupId, 'messageId': messageId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data.map((e) => asInt(e)).where((id) => id > 0).toList();
  }

  // ==================== 撤回 ====================

  /// 撤回私聊消息（服务端会向对方推送 RECALL 通知）。
  static Future<void> recallPrivateMessage({required int id}) async {
    await ApiClient.dio.delete(
      '/admin-api/im/message/private/recall',
      queryParameters: {'id': id},
    );
  }

  /// 撤回群聊消息。
  static Future<void> recallGroupMessage({required int id}) async {
    await ApiClient.dio.delete(
      '/admin-api/im/message/group/recall',
      queryParameters: {'id': id},
    );
  }

  // ==================== 文件上传 ====================

  /// 上传文件到基础设施文件服务（语音/表情/图片/视频/文件等）。
  /// [directory] 业务目录，如 im/voice、im/face、im/message、im/file。
  /// 返回文件 URL；[onSendProgress] 回调上传进度（已发送字节数, 总字节数）。
  static Future<String> uploadFile({
    required String filePath,
    required String directory,
    String? fileName,
    void Function(int sent, int total)? onSendProgress,
  }) async {
    final form = FormData.fromMap({
      'directory': directory,
      'file': await MultipartFile.fromFile(filePath, filename: fileName),
    });
    final resp = await ApiClient.dio.post(
      '/admin-api/infra/file/upload',
      data: form,
      onSendProgress: onSendProgress,
    );
    return ApiClient.unwrap(resp).toString();
  }

  // ==================== 表情包 ====================

  /// 获得所有启用的系统表情包（含 items）。
  static Future<List<ImFacePack>> getFacePackList() async {
    final resp = await ApiClient.dio.get('/admin-api/im/face-pack/list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImFacePack.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得我的个人表情列表。
  static Future<List<ImFaceItem>> getFaceUserItemList() async {
    final resp = await ApiClient.dio.get('/admin-api/im/face-user-item/list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImFaceItem.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 添加个人表情，返回编号。
  static Future<int> createFaceUserItem({
    required String url,
    required int width,
    required int height,
    String name = '',
  }) async {
    final resp = await ApiClient.dio.post(
      '/admin-api/im/face-user-item/create',
      data: {'url': url, 'name': name, 'width': width, 'height': height},
    );
    return asInt(ApiClient.unwrap(resp));
  }

  /// 删除个人表情。
  static Future<void> deleteFaceUserItem({required int id}) async {
    await ApiClient.dio.delete(
      '/admin-api/im/face-user-item/delete',
      queryParameters: {'id': id},
    );
  }

  /// 获得好友详情（备注/来源/拉黑/添加时间）。
  static Future<ImFriend?> getFriendDetail({required int friendUserId}) async {
    final resp = await ApiClient.dio.get(
      '/admin-api/im/friend/get',
      queryParameters: {'friendUserId': friendUserId},
    );
    final data = ApiClient.unwrap(resp);
    if (data is! Map<String, dynamic>) return null;
    return ImFriend.fromJson(data);
  }

  /// 更新好友备注（仅自己可见；displayName 传空串表示清空）。
  static Future<void> updateFriendRemark({
    required int friendUserId,
    required String displayName,
  }) async {
    await ApiClient.dio.put(
      '/admin-api/im/friend/update',
      data: {'friendUserId': friendUserId, 'displayName': displayName},
    );
  }

  /// 拉黑好友（必须先是好友；单边屏蔽对方私聊消息）。
  static Future<void> blockFriend({required int friendUserId}) async {
    await ApiClient.dio.put(
      '/admin-api/im/friend/block',
      queryParameters: {'friendUserId': friendUserId},
    );
  }

  /// 移出黑名单。
  static Future<void> unblockFriend({required int friendUserId}) async {
    await ApiClient.dio.put(
      '/admin-api/im/friend/unblock',
      queryParameters: {'friendUserId': friendUserId},
    );
  }

  /// 删除好友（单向软删除；clear=true 级联清理本端私聊会话）。
  static Future<void> deleteFriend({
    required int friendUserId,
    bool clear = true,
  }) async {
    await ApiClient.dio.delete(
      '/admin-api/im/friend/delete',
      queryParameters: {'friendUserId': friendUserId, 'clear': clear},
    );
  }

  /// 发起好友申请（source：1=搜索 2=群聊 3=扫码 4=名片）。
  static Future<void> applyFriendRequest({
    required int toUserId,
    String applyContent = '',
    int addSource = 1,
  }) async {
    await ApiClient.dio.post(
      '/admin-api/im/friend-request/apply',
      data: {
        'toUserId': toUserId,
        'applyContent': applyContent,
        'addSource': addSource,
      },
    );
  }
}
