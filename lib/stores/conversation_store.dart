import 'package:flutter/foundation.dart';

import '../models/im_conversation.dart';
import '../models/im_message.dart';
import '../services/auth_manager.dart';
import '../services/im_api.dart';

/// 会话列表 Store：对应 H5 conversationStore——
/// 无服务端"会话接口"，进入页面时拉取「好友/群元数据 + 消息增量 + 读位置」，
/// 在客户端由消息流聚合出会话列表（最后一条摘要、未读数、排序）。
///
/// 第一期说明：暂无本地数据库，每次 load 全量拉取（minId=0）后在内存聚合；
/// 后续引入 sqflite 后改为增量拉取 + 本地缓存。
class ConversationStore with ChangeNotifier {
  ConversationStore._();

  static final ConversationStore instance = ConversationStore._();

  /// 增量拉取分页大小。
  static const int _pullPageSize = 100;

  /// 读位置拉取分页大小。
  static const int _readPageSize = 200;

  /// 聚合出的会话列表（已排序）。
  List<ImConversation> conversations = [];

  /// 好友元数据（key: friendUserId），私聊会话的标题/头像来源。
  final Map<int, ImFriend> friends = {};

  /// 群元数据（key: groupId），群聊会话的标题/头像来源。
  final Map<int, ImGroup> groups = {};

  /// 频道元数据（key: channelId），频道会话的标题/头像来源。
  final Map<int, ImChannel> channels = {};

  /// 会话读位置（key: type_targetId），未读数计算用。
  final Map<String, int> _readPositions = {};

  /// 拉取并重建会话列表。失败抛出异常由调用方处理。
  Future<void> load() async {
    final myUserId = AuthManager.instance.userId;

    // ① 元数据 + 读位置（并行）
    final friendListFuture = ImApi.getFriendList();
    final groupListFuture = ImApi.getGroupList();
    final channelListFuture = ImApi.getChannelSimpleList();
    final readsFuture = _pullAllReads();

    // ② 消息增量全量拉取（并行）
    final privateMsgsFuture = _pullAllPrivate();
    final groupMsgsFuture = _pullAllGroup();
    final channelMsgsFuture = _pullAllChannel();

    final results = await Future.wait([
      friendListFuture,
      groupListFuture,
      channelListFuture,
      readsFuture,
      privateMsgsFuture,
      groupMsgsFuture,
      channelMsgsFuture,
    ]);
    final friendList = results[0] as List<ImFriend>;
    final groupList = results[1] as List<ImGroup>;
    final channelList = results[2] as List<ImChannel>;
    final reads = results[3] as List<ImConversationRead>;
    final privateMsgs = results[4] as List<ImPrivateMessage>;
    final groupMsgs = results[5] as List<ImGroupMessage>;
    final channelMsgs = results[6] as List<ImChannelMessage>;

    // ③ 落内存
    friends
      ..clear()
      ..addEntries(friendList.map((f) => MapEntry(f.friendUserId, f)));
    groups
      ..clear()
      ..addEntries(groupList.map((g) => MapEntry(g.id, g)));
    channels
      ..clear()
      ..addEntries(channelList.map((c) => MapEntry(c.id, c)));
    _readPositions
      ..clear()
      ..addEntries(reads.map(
          (r) => MapEntry('${r.conversationType.value}_${r.targetId}', r.messageId)));

    // ④ 客户端聚合重建会话列表
    conversations = _rebuild(privateMsgs, groupMsgs, channelMsgs, myUserId);
    notifyListeners();
  }

  /// 循环拉取全部私聊消息（minId 游标，升序）。
  Future<List<ImPrivateMessage>> _pullAllPrivate() async {
    final all = <ImPrivateMessage>[];
    var minId = 0;
    while (true) {
      final batch =
          await ImApi.pullPrivateMessages(minId: minId, size: _pullPageSize);
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < _pullPageSize) break;
      minId = batch.last.id;
    }
    return all;
  }

  /// 循环拉取全部群聊消息（minId 游标，升序）。
  Future<List<ImGroupMessage>> _pullAllGroup() async {
    final all = <ImGroupMessage>[];
    var minId = 0;
    while (true) {
      final batch =
          await ImApi.pullGroupMessages(minId: minId, size: _pullPageSize);
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < _pullPageSize) break;
      minId = batch.last.id;
    }
    return all;
  }

  /// 循环拉取全部频道消息（minId 游标，升序）。
  Future<List<ImChannelMessage>> _pullAllChannel() async {
    final all = <ImChannelMessage>[];
    var minId = 0;
    while (true) {
      final batch =
          await ImApi.pullChannelMessages(minId: minId, size: _pullPageSize);
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < _pullPageSize) break;
      minId = batch.last.id;
    }
    return all;
  }

  /// 循环拉取全部会话读位置（lastId 游标）。
  Future<List<ImConversationRead>> _pullAllReads() async {
    final all = <ImConversationRead>[];
    int? lastId;
    while (true) {
      final batch =
          await ImApi.pullConversationReads(lastId: lastId, limit: _readPageSize);
      if (batch.isEmpty) break;
      all.addAll(batch);
      if (batch.length < _readPageSize) break;
      lastId = batch.last.id;
    }
    return all;
  }

  /// 用消息流聚合会话列表：按「私聊对方 / 群」分组，计算最后一条消息与未读数。
  List<ImConversation> _rebuild(
    List<ImPrivateMessage> privateMsgs,
    List<ImGroupMessage> groupMsgs,
    List<ImChannelMessage> channelMsgs,
    int? myUserId,
  ) {
    final me = myUserId ?? -1;

    // 私聊：peerId = 消息里非我的一端
    final privateByPeer = <int, List<ImPrivateMessage>>{};
    for (final m in privateMsgs) {
      final peer = m.senderId == me ? m.receiverId : m.senderId;
      privateByPeer.putIfAbsent(peer, () => []).add(m);
    }

    // 群聊：按 groupId 分组
    final groupById = <int, List<ImGroupMessage>>{};
    for (final m in groupMsgs) {
      groupById.putIfAbsent(m.groupId, () => []).add(m);
    }

    // 频道：按 channelId 分组
    final channelById = <int, List<ImChannelMessage>>{};
    for (final m in channelMsgs) {
      channelById.putIfAbsent(m.channelId, () => []).add(m);
    }

    final result = <ImConversation>[];

    for (final entry in privateByPeer.entries) {
      final peerId = entry.key;
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final friend = friends[peerId];
      final readId = _readPositions['${ImConversationType.private.value}_$peerId'] ?? 0;
      final unread =
          msgs.where((m) => m.senderId != me && m.id > readId).length;

      result.add(ImConversation(
        type: ImConversationType.private,
        targetId: peerId,
        title: friend?.shownName ?? '用户$peerId',
        avatar: friend?.avatar ?? '',
        lastMessageText: last.textContent,
        lastMessageTime: last.sendTime,
        unreadCount: unread,
        pinned: friend?.pinned ?? false,
        silent: friend?.silent ?? false,
      ));
    }

    for (final entry in groupById.entries) {
      final groupId = entry.key;
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final group = groups[groupId];
      final readId = _readPositions['${ImConversationType.group.value}_$groupId'] ?? 0;
      final unread =
          msgs.where((m) => m.senderId != me && m.id > readId).length;

      result.add(ImConversation(
        type: ImConversationType.group,
        targetId: groupId,
        title: group?.shownName ?? '群$groupId',
        avatar: group?.avatar ?? '',
        lastMessageText: last.textContent,
        lastMessageTime: last.sendTime,
        unreadCount: unread,
        pinned: false,
        silent: group?.silent ?? false,
      ));
    }

    for (final entry in channelById.entries) {
      final channelId = entry.key;
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final channel = channels[channelId];
      // 频道为广播消息（无发送人概念），未读 = id 超过读位置的消息数
      final readId =
          _readPositions['${ImConversationType.channel.value}_$channelId'] ?? 0;
      final unread = msgs.where((m) => m.id > readId).length;

      result.add(ImConversation(
        type: ImConversationType.channel,
        targetId: channelId,
        title: channel?.name.isNotEmpty == true ? channel!.name : '频道$channelId',
        avatar: channel?.avatar ?? '',
        lastMessageText: last.summaryText,
        lastMessageTime: last.sendTime,
        unreadCount: unread,
        pinned: false,
        silent: false,
      ));
    }

    result.sort((a, b) => a.compareTo(b));
    return result;
  }
}
