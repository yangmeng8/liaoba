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

  /// list 会话快照单次条数上限（接口 max 200，无翻页游标）。
  static const int _readListLimit = 200;

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

  /// 会话读位置快照表（key: type_targetId → 服务端 conversation-read 记录）：
  /// 未读数、服务端置顶、免打扰的数据源。冷启动走 list 快照全量重建，
  /// 之后 WS 重连/断线补偿走 pull 变更流 merge（userDeleted=1 的不进表）。
  final Map<String, ImConversationRead> _readMap = {};

  /// 用户已删除的会话集合（key: type_targetId；pull 的 userDeleted=1 标记 +
  /// 冷启动快照差集推导），_rebuild 聚合时过滤不显示。
  final Set<String> _deletedKeys = {};

  /// 读位置增量游标：上次拉取到的最新 updateTime（毫秒）与最后一条记录 id。
  /// null = 未初始化（冷启动/切账号/下拉刷新，下次同步走 list 快照）。
  int? _readCursorTime;
  int _readCursorId = 0;

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
    } else if (n.contentType == ImSystemMessageType.groupMsgDelete) {
      // 群消息批量删除（2206）：按 payload.messageIds 批量移除缓存
      final ids = (n.payload['messageIds'] as List?)
              ?.map((e) => asInt(e))
              .where((id) => id > 0)
              .toSet() ??
          const <int>{};
      if (ids.isNotEmpty) _groupMsgs.removeWhere((m) => ids.contains(m.id));
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

  /// 本地即时更新读位置（聊天室已读上报成功后调用）：
  /// 直接写内存读位并重建会话——未读数立即清零，
  /// 无需等 WS 推送或下次全量拉取（否则返回消息列表仍显示旧未读）。
  void markReadLocally(
      ImConversationType type, int targetId, int messageId) {
    final key = '${type.value}_$targetId';
    final old = _readMap[key];
    if (old != null) {
      if (old.messageId >= messageId) return;
      // 仅提升读位（id/updateTime 保留服务端值，不干扰增量游标推导）
      _readMap[key] = ImConversationRead(
        id: old.id,
        conversationType: old.conversationType,
        targetId: old.targetId,
        messageId: messageId,
        updateTime: old.updateTime,
        userDeleted: old.userDeleted,
        isTop: old.isTop,
        topTime: old.topTime,
        readTime: old.readTime,
        isMute: old.isMute,
      );
    } else {
      // 服务端记录尚未拉到（新会话首次已读）：本地先记，后续 merge 覆盖
      _readMap[key] = ImConversationRead(
        id: 0,
        conversationType: type,
        targetId: targetId,
        messageId: messageId,
      );
    }
    conversations = _rebuild(_privateMsgs, _groupMsgs, _channelMsgs,
        AuthManager.instance.userId);
    notifyListeners();
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
  /// [refreshReads] true 时读位置放弃增量游标、改走 list 全量快照
  /// （下拉刷新/失败重试用；冷启动与切账号由游标自动判定）。
  Future<void> load({bool refreshReads = false}) async {
    if (_loading) return; // 并发保护：在途拉取直接跳过
    _loading = true;
    try {
      await _doLoad(refreshReads: refreshReads);
      _loadedOnce = true;
    } finally {
      _loading = false;
    }
  }

  Future<void> _doLoad({bool refreshReads = false}) async {
    final myUserId = AuthManager.instance.userId;

    // 账号切换：清空消息与读位置缓存（防上个账号的数据串入重建结果）
    if (_ownerUserId != myUserId) {
      _privateMsgs.clear();
      _groupMsgs.clear();
      _channelMsgs.clear();
      _readMap.clear();
      _deletedKeys.clear();
      _readCursorTime = null;
      _readCursorId = 0;
      _ownerUserId = myUserId;
    }

    // 本地置顶标记（首次惰性加载）
    await _ensureLocalPinnedLoaded();

    // ① 元数据 + 读位置 + 消息增量（并行；元数据小数据全量，消息走游标增量
    // ——缓存非空时只拉新增，推送补拉秒级完成；
    // 读位置无游标走 list 快照、有游标走 pull 变更流）
    final results = await Future.wait([
      ImApi.getFriendList(),
      ImApi.getGroupList(),
      ImApi.getChannelSimpleList(),
      _syncReads(refresh: refreshReads),
      _pullAllPrivate(),
      _pullAllGroup(),
      _pullAllChannel(),
    ]);
    final friendList = results[0] as List<ImFriend>;
    final groupList = results[1] as List<ImGroup>;
    final channelList = results[2] as List<ImChannel>;
    final isReadSnapshot = results[3] as bool;
    final privateMsgs = results[4] as List<ImPrivateMessage>;
    final groupMsgs = results[5] as List<ImGroupMessage>;
    final channelMsgs = results[6] as List<ImChannelMessage>;

    // ② 落内存：消息追加进累积缓存，元数据整体重建
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

    // ③ 读位置为 list 快照（冷启动/切账号/下拉刷新）时推导已删会话：
    // list 不返回用户删除的会话，消息流聚合出但快照中没有的会话即已删除，
    // 标记过滤（增量场景由 pull 的 userDeleted 增量维护）
    if (isReadSnapshot) {
      _deletedKeys
        ..clear()
        ..addAll(_messageStreamKeys(myUserId)
            .difference(_readMap.keys.toSet()));
    }

    // ④ 客户端聚合重建会话列表（基于累积消息流）
    conversations = _rebuild(_privateMsgs, _groupMsgs, _channelMsgs, myUserId);
    notifyListeners();
  }

  /// 消息流中出现的全部会话 key（type_targetId；与 _rebuild 分组同构）。
  Set<String> _messageStreamKeys(int? myUserId) {
    final me = myUserId ?? -1;
    final keys = <String>{};
    for (final m in _privateMsgs) {
      keys.add(
          '${ImConversationType.private.value}_${m.senderId == me ? m.receiverId : m.senderId}');
    }
    for (final m in _groupMsgs) {
      keys.add('${ImConversationType.group.value}_${m.groupId}');
    }
    for (final m in _channelMsgs) {
      keys.add('${ImConversationType.channel.value}_${m.channelId}');
    }
    return keys;
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

  /// 会话是否置顶（私聊 = 好友表 pinned；会话级 = 服务端 isTop；
  /// 另兼容历史本地置顶旧标记，置顶切换时旧标记会被清掉）。
  bool isConversationTop(ImConversationType type, int targetId) {
    if (type == ImConversationType.private) {
      if (friends[targetId]?.pinned ?? false) return true;
    }
    final key = '${type.value}_$targetId';
    if (_readMap[key]?.top ?? false) return true;
    return _localPinned.contains(key);
  }

  /// 切换会话置顶：调服务端 top 接口（多端同步），成功后本地即时刷新列表
  /// （失败抛异常由调用方回滚开关状态）；本地旧置顶标记同时清除，以服务端为准。
  Future<void> setConversationTop(
    ImConversationType type,
    int targetId,
    bool top,
  ) async {
    await ImApi.setConversationTop(
      conversationType: type,
      targetId: targetId,
      top: top,
    );
    // 服务端成功后：清本地旧标记（取消置顶时保证生效），更新快照表 isTop
    await _ensureLocalPinnedLoaded();
    final key = '${type.value}_$targetId';
    if (_localPinned.remove(key)) {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setStringList(_pinnedPrefsKey, _localPinned.toList());
      } catch (_) {
        // 持久化失败不影响本次内存生效
      }
    }
    final old = _readMap[key];
    _readMap[key] = ImConversationRead(
      id: old?.id ?? 0,
      conversationType: type,
      targetId: targetId,
      messageId: old?.messageId ?? 0,
      updateTime: old?.updateTime,
      userDeleted: old?.userDeleted ?? 0,
      isTop: top ? 1 : 0,
      topTime: top ? DateTime.now() : null,
      readTime: old?.readTime,
      isMute: old?.isMute ?? 0,
    );
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

  /// 读位置同步：无游标（冷启动/切账号）或 [refresh] 强制时走 list 全量快照
  /// （服务端已排序、已过滤已删除会话），否则走 pull 增量变更流 merge
  /// （变更含 userDeleted=1 的删除记录：标记过滤并清该会话消息缓存，
  /// 防删除后新消息到来时旧消息重显；userDeleted=0 恢复显示）。
  /// 返回是否为快照模式（调用方做已删会话差集推导）。
  Future<bool> _syncReads({bool refresh = false}) async {
    if (refresh) {
      _readCursorTime = null;
      _readCursorId = 0;
    }
    if (_readCursorTime == null) {
      final snapshot = await ImApi.getConversationReadList(limit: _readListLimit);
      _readMap.clear();
      for (final r in snapshot) {
        _readMap[r.mapKey] = r;
      }
      // 游标 = 快照中 (updateTime, id) 字典序最大者
      //（list 按置顶优先排序，不按 updateTime，需全表扫描）
      var t = 0, i = 0;
      for (final r in snapshot) {
        if (r.updateTimeMs > t || (r.updateTimeMs == t && r.id > i)) {
          t = r.updateTimeMs;
          i = r.id;
        }
      }
      _readCursorTime = t;
      _readCursorId = i;
      return true;
    }
    // 增量：变更流按 updateTime ASC, id ASC；末条即游标新值
    while (true) {
      final batch = await ImApi.pullConversationReads(
        lastUpdateTime: _readCursorTime,
        lastId: _readCursorId,
        limit: _readPageSize,
      );
      if (batch.isEmpty) break;
      for (final r in batch) {
        if (r.deleted) {
          _readMap.remove(r.mapKey);
          _deletedKeys.add(r.mapKey);
          _dropMessagesOf(r.conversationType, r.targetId);
        } else {
          _readMap[r.mapKey] = r;
          _deletedKeys.remove(r.mapKey);
        }
      }
      // 防御：updateTime 缺失时保持原游标（避免回退导致重复拉取）
      if (batch.last.updateTimeMs > 0 &&
          batch.last.updateTimeMs >= (_readCursorTime ?? 0)) {
        _readCursorTime = batch.last.updateTimeMs;
        _readCursorId = batch.last.id;
      }
      if (batch.length < _readPageSize) break;
    }
    return false;
  }

  /// 清指定会话的消息内存缓存（会话被删除时防旧消息随新消息重显）。
  void _dropMessagesOf(ImConversationType type, int targetId) {
    final me = _ownerUserId ?? -1;
    switch (type) {
      case ImConversationType.private:
        _privateMsgs.removeWhere((m) =>
            (m.senderId == me ? m.receiverId : m.senderId) == targetId);
        break;
      case ImConversationType.group:
        _groupMsgs.removeWhere((m) => m.groupId == targetId);
        break;
      case ImConversationType.channel:
        _channelMsgs.removeWhere((m) => m.channelId == targetId);
        break;
    }
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
      final key = '${ImConversationType.private.value}_$peerId';
      if (_deletedKeys.contains(key)) continue; // 用户已删除该会话
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final friend = friends[peerId];
      final readId = _readMap[key]?.messageId ?? 0;
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
            (_readMap[key]?.top ?? false) ||
            _localPinned.contains(key),
        silent: friend?.silent ?? false,
      ));
    }

    for (final entry in groupById.entries) {
      final groupId = entry.key;
      final key = '${ImConversationType.group.value}_$groupId';
      if (_deletedKeys.contains(key)) continue; // 用户已删除该会话
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final group = groups[groupId];
      final readId = _readMap[key]?.messageId ?? 0;
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
        pinned: (_readMap[key]?.top ?? false) ||
            _localPinned.contains(key),
        silent: group?.silent ?? false,
      ));
    }

    for (final entry in channelById.entries) {
      final channelId = entry.key;
      final key = '${ImConversationType.channel.value}_$channelId';
      if (_deletedKeys.contains(key)) continue; // 用户已删除该会话
      final msgs = entry.value;
      final last = msgs.reduce((a, b) =>
          (a.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
                  .isAfter(b.sendTime ?? DateTime.fromMillisecondsSinceEpoch(0))
              ? a
              : b);
      final channel = channels[channelId];
      // 频道为广播消息（无发送人概念），未读 = id 超过读位置的消息数
      final readId = _readMap[key]?.messageId ?? 0;
      final unread = msgs.where((m) => m.id > readId).length;

      result.add(ImConversation(
        type: ImConversationType.channel,
        targetId: channelId,
        title: channel?.name.isNotEmpty == true ? channel!.name : '频道$channelId',
        avatar: channel?.avatar ?? '',
        lastMessageText: last.summaryText,
        lastMessageTime: last.sendTime,
        unreadCount: unread,
        pinned: (_readMap[key]?.top ?? false) ||
            _localPinned.contains(key),
        silent: false,
      ));
    }

    result.sort((a, b) => a.compareTo(b));
    return result;
  }
}
