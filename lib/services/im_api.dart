import 'api_client.dart';
import '../models/im_conversation.dart';
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
}
