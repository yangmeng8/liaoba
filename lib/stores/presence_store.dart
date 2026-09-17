import 'dart:async';

import '../models/im_conversation.dart';
import '../models/im_ws_frame.dart';
import '../services/im_websocket.dart';

/// 好友在线状态（内存 + 广播）：
/// - 初始化：/im/friend/list 返回的 online 字段全量覆盖；
/// - 实时：WS FRIEND_ONLINE / FRIEND_OFFLINE 推送增量更新；
/// - 消费：消息列表/通讯录头像角标、私聊页在线文案（订阅 [changes] 刷新）。
class PresenceStore {
  PresenceStore._();

  static final instance = PresenceStore._();

  final _ctrl = StreamController<void>.broadcast();

  /// userId → 是否在线（缺省 false）。
  final Map<int, bool> _online = {};

  StreamSubscription<ImWsPresence>? _wsSub;

  /// 状态变更通知流（UI 订阅后 setState 刷新）。
  Stream<void> get changes => _ctrl.stream;

  /// 指定好友是否在线（无记录按离线处理）。
  bool isOnline(int userId) => _online[userId] ?? false;

  /// 应用启动时挂载：订阅 WS 在线推送。
  void attach() {
    _wsSub ??= ImWebSocket.instance.presenceStream.listen((p) {
      setOnline(p.userId, p.online);
    });
  }

  /// 好友列表全量初始化（用户上线/刷新时经 /im/friend/list 拉取）。
  void initFromFriends(List<ImFriend> friends) {
    _online
      ..clear()
      ..addEntries(friends.map((f) => MapEntry(f.friendUserId, f.online)));
    _notify();
  }

  /// WS 推送增量更新单人。
  void setOnline(int userId, bool online) {
    if (_online[userId] == online) return;
    _online[userId] = online;
    _notify();
  }

  /// 退出登录清空（防切换账号串号）。
  void clear() {
    _online.clear();
    _notify();
  }

  void _notify() {
    if (!_ctrl.isClosed) _ctrl.add(null);
  }
}
