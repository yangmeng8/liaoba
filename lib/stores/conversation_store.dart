import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/im_conversation.dart';
import '../models/im_message.dart';
import '../models/im_ws_frame.dart';
import '../shared/json_utils.dart';
import '../services/auth_manager.dart';
import '../services/im_api.dart';
import '../services/im_websocket.dart';

/// 会话列表 Store：对应 H5 conversationStore——
/// 无服务端"会话接口"，进入页面时拉取「好友/群元数据 + 消息增量 + 读位置」，
/// 在客户端由消息流聚合出会话列表（最后一条摘要、未读数、排序）。
///
/// 实时更新：监听 WebSocket 通知（新消息/已读等）与断线补偿事件，
/// debounce 后增量补拉重建（推送保实时、拉取保最终一致）。
///
/// 增量策略：消息在内存累积（游标 = 各流末尾 id），推送补拉只拉新增，
/// 避免每次全量重拉历史；撤回（2101）/删好友（1205）改变历史数据，
/// 对应流清空后全量重拉。后续引入 sqflite 后可替换为本地库增量。
class ConversationStore with ChangeNotifier {
  ConversationStore._() {
    // WebSocket 推送 → 防抖增量补拉（对应 H5 im:message / im:event → 重建会话）
    ImWebSocket.instance.notificationStream.listen(_onNotification);
    // 断线重连成功 → 立即增量补拉（断线补偿，游标可拉到断线期间消息）
    ImWebSocket.instance.resyncStream.listen((_) => _scheduleReload());
  }

  static final ConversationStore instance = ConversationStore._();

  /// 增量拉取分页大小。
  static const int _pullPageSize = 100;

  /// 读位置拉取分页大小。
  static const int _readPageSize = 200;

  /// 推送触发的补拉防抖间隔。
  static const Duration _reloadDebounce = Duration(milliseconds: 800);

  /// 消息内存累积缓存（游标增量的基础：推送补拉只拉 id 大于
  /// 缓存末尾的新消息，避免每次全量重拉历史导致刷新缓慢）。
  final List<ImPrivateMessage> _privateMsgs = [];
  final List<ImGroupMessage> _groupMsgs = [];
  final List<ImChannelMessage> _channelMsgs = [];

  /// 消息缓存归属用户（切换账号时清空，防止上个账号的消息串入）。
  int? _ownerUserId;

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

  /// 本地置顶会话集合（key: type_targetId；对应 H5 setConversationTop 的本地语义）。
  /// 私聊另有服务端 pinned（好友表字段），两者取或；群聊/频道纯本地。
  Set<String> _localPinned = {};
  bool _localPinnedLoaded = false;
  static const String _pinnedPrefsKey = 'im_local_pinned_conversations';

  /// 拉取并发保护 + 补拉防抖。
  bool _loading = false;
  bool _loadedOnce = false;
  Timer? _reloadTimer;

  /// 推送到达：按类型失效增量缓存后防抖补拉。
  /// 撤回（2101）改的是历史消息状态、删好友（1205）服务端会删私聊消息，
  /// 增量游标拉不到 → 清空对应流做全量；其余（新消息/好友添加等）增量即可。
  void _onNotification(ImWsNotification n) {
    if (n.contentType == ImSystemMessageType.recall) {
      switch (n.conversationType) {
        case 1:
          _privateMsgs.clear();
          break;
        case 2:
          _groupMsgs.clear();
          break;
        case 3:
          _channelMsgs.clear();
          break;
      }
    } else if (n.contentType == ImSystemMessageType.friendDelete) {
      _privateMsgs.clear();
    } else if (n.contentType == ImSystemMessageType.burnDelete) {
      // 阅后即焚销毁（2203）：服务端已删该消息，增量游标拉不到变化，
      // 按 payload.messageId 精确移除本地缓存（会话列表同步刷新）
      final burnedId = asInt(n.payload['messageId']);
      if (burnedId > 0) {
        switch (n.conversationType) {
          case 1:
            _privateMsgs.removeWhere((m) => m.id == burnedId);
            break;
          case 2:
            _groupMsgs.removeWhere((m) => m.id == burnedId);
            break;
          case 3:
            _channelMsgs.removeWhere((m) => m.id == burnedId);
            break;
        }
      }
    }
    _scheduleReload();
  }

  /// 推送触发的防抖补拉：窗口内多次通知合并为一次增量拉取。
  void _scheduleReload() {
    if (!_loadedOnce) return; // 首次加载由页面触发，避免重复
    _reloadTimer?.cancel();
    _reloadTimer = Timer(_reloadDebounce, () {
      load().catchError((Object e) {
        debugPrint('[ConversationStore] 推送补拉失败: $e');
      });
    });
  }

  /// 拉取并重建会话列表。失败抛出异常由调用方处理。
  Future<void> load() async {
    if (_loading) return; // 并发保护：在途拉取直接跳过
    _loading = true;
    try {
      await _doLoad();
      _loadedOnce = true;
    } finally {
      _loading = false;
    }
  }

  Future<void> _doLoad() async {
    final myUserId = AuthManager.instance.userId;

    // 账号切换：清空消息缓存（防上个账号的消息串入重建结果）
    if (_ownerUserId != myUserId) {
      _privateMsgs.clear();
      _groupMsgs.clear();
      _channelMsgs.clear();
      _ownerUserId = myUserId;
    }

    // 本地置顶标记（首次惰性加载）
    await _ensureLocalPinnedLoaded();

    // ① 元数据 + 读位置 + 消息增量（并行；元数据/读位置小数据全量，
    // 消息走游标增量——缓存非空时只拉新增，推送补拉秒级完成）
    final results = await Future.wait([
      ImApi.getFriendList(),
      ImApi.getGroupList(),
      ImApi.getChannelSimpleList(),
      _pullAllReads(),
      _pullAllPrivate(),
      _pullAllGroup(),
      _pullAllChannel(),
    ]);
    final friendList = results[0] as List<ImFriend>;
    final groupList = results[1] as List<ImGroup>;
    final channelList = results[2] as List<ImChannel>;
    final reads = results[3] as List<ImConversationRead>;
    final privateMsgs = results[4] as List<ImPrivateMessage>;
    final groupMsgs = results[5] as List<ImGroupMessage>;
    final channelMsgs = results[6] as List<ImChannelMessage>;

    // ② 落内存：消息追加进累积缓存，元数据/读位置整体重建
    _privateMsgs.addAll(privateMsgs);
    _groupMsgs.addAll(groupMsgs);
    _channelMsgs.addAll(channelMsgs);
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

    // ③ 客户端聚合重建会话列表（基于累积消息流）
    conversations = _rebuild(_privateMsgs, _groupMsgs, _channelMsgs, myUserId);
    notifyListeners();
  }

  /// 从磁盘加载本地置顶标记（仅一次）。
  Future<void> _ensureLocalPinnedLoaded() async {
    if (_localPinnedLoaded) return;
    _localPinnedLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _localPinned = (prefs.getStringList(_pinnedPrefsKey) ?? const [])
          .toSet();
    } catch (_) {
      // 磁盘异常：视为无本地置顶
    }
  }

  /// 会话是否置顶（私聊 = 服务端 pinned 或本地；其余纯本地）。
  bool isConversationTop(ImConversationType type, int targetId) {
    if (type == ImConversationType.private) {
      final server = friends[targetId]?.pinned ?? false;
      if (server) return true;
    }
    return _localPinned.contains('${type.value}_$targetId');
  }

  /// 切换会话置顶（本地持久化 + 即时刷新列表，对应 H5 setConversationTop）。
  Future<void> setConversationTop(
    ImConversationType type,
    int targetId,
    bool top,
  ) async {
    await _ensureLocalPinnedLoaded();
    final key = '${type.value}_$targetId';
    if (top) {
      _localPinned.add(key);
    } else {
      _localPinned.remove(key);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_pinnedPrefsKey, _localPinned.toList());
    } catch (_) {
      // 持久化失败不影响本次内存生效
    }
    // 即时更新聚合结果（避免全量重拉）
    conversations = conversations.map((c) {
      if (c.type != type || c.targetId != targetId) return c;
      final next = top || (type == ImConversationType.private &&
          (friends[targetId]?.pinned ?? false));
      return ImConversation(
        type: c.type,
        targetId: c.targetId,
        title: c.title,
        avatar: c.avatar,
        lastMessageText: c.lastMessageText,
        lastMessageTime: c.lastMessageTime,
        unreadCount: c.unreadCount,
        pinned: next,
        silent: c.silent,
      );
    }).toList()
      ..sort((a, b) => a.compareTo(b));
    notifyListeners();
  }

  /// 循环拉取私聊消息（minId 游标，升序；缓存非空时仅拉新增）。
  Future<List<ImPrivateMessage>> _pullAllPrivate() async {
    final all = <ImPrivateMessage>[];
    var minId = _privateMsgs.isNotEmpty ? _privateMsgs.last.id : 0;
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

  /// 循环拉取群聊消息（minId 游标，升序；缓存非空时仅拉新增）。
  Future<List<ImGroupMessage>> _pullAllGroup() async {
    final all = <ImGroupMessage>[];
    var minId = _groupMsgs.isNotEmpty ? _groupMsgs.last.id : 0;
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

  /// 循环拉取频道消息（minId 游标，升序；缓存非空时仅拉新增）。
  Future<List<ImChannelMessage>> _pullAllChannel() async {
    final all = <ImChannelMessage>[];
    var minId = _channelMsgs.isNotEmpty ? _channelMsgs.last.id : 0;
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

  /// 群广播事件人名解析（会话摘要用）：自己 > 好友备注/昵称 > 用户N。
  String _resolveUserName(int userId) {
    final me = AuthManager.instance.userId;
    if (me != null && userId == me) {
      final n = AuthManager.instance.nickname ?? '';
      return n.isNotEmpty ? n : '用户$userId';
    }
    final friend = friends[userId];
    if (friend != null && friend.shownName.isNotEmpty) return friend.shownName;
    return '用户$userId';
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
        pinned: (friend?.pinned ?? false) ||
            _localPinned.contains('${ImConversationType.private.value}_$peerId'),
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
        lastMessageText: last.textContent(nameResolver: _resolveUserName),
        lastMessageTime: last.sendTime,
        unreadCount: unread,
        pinned: _localPinned.contains('${ImConversationType.group.value}_$groupId'),
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
        pinned: _localPinned.contains('${ImConversationType.channel.value}_$channelId'),
        silent: false,
      ));
    }

    result.sort((a, b) => a.compareTo(b));
    return result;
  }
}
