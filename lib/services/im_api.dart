import 'api_client.dart';
import '../models/im_conversation.dart';
import '../models/im_message.dart';

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
      '/app-api/im/message/private/list',
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
      '/app-api/im/message/group/list',
      queryParameters: {
        'groupId': groupId,
        'limit': limit,
        'maxId': ?maxId,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImGroupMessage.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得当前登录用户的好友列表。
  static Future<List<ImFriend>> getFriendList() async {
    final resp = await ApiClient.dio.get('/app-api/im/friend/list');
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImFriend.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 获得当前登录用户的群列表（含已退群的历史群，供展示群名/头像）。
  static Future<List<ImGroup>> getGroupList() async {
    final resp = await ApiClient.dio.get('/app-api/im/group/list');
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
      '/app-api/im/message/private/pull',
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
      '/app-api/im/message/group/pull',
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
      '/app-api/im/conversation-read/pull',
      queryParameters: {
        'lastId': ?lastId,
        'limit': limit,
      },
    );
    final data = ApiClient.unwrap(resp);
    if (data is! List) return const [];
    return data
        .map((e) => ImConversationRead.fromJson(e as Map<String, dynamic>))
        .toList();
  }
}
