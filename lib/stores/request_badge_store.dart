import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/auth_manager.dart';
import '../services/im_api.dart';
import '../services/im_websocket.dart';

/// 好友申请待办数 Store（通讯录「新的朋友」行 / 主框架通讯录 Tab 角标共用）：
/// - WS 推送（申请到达/处理结果）→ 1s 防抖重拉
/// - 请求中心同意/拒绝返回后由调用方手动 [refresh]
/// - 数值变化才 notify（列表刷新由各页面自行订阅 WS）
class RequestBadgeStore with ChangeNotifier {
  RequestBadgeStore._() {
    // 单例随 App 存活不销毁，订阅无需取消
    ImWebSocket.instance.notificationStream.listen((_) {
      _debounce?.cancel();
      _debounce = Timer(const Duration(seconds: 1), refresh);
    });
    refresh();
  }

  static final RequestBadgeStore instance = RequestBadgeStore._();

  /// 收到的（toUserId=我）且未处理的好友申请数。
  int pending = 0;

  Timer? _debounce;
  bool _loading = false;

  /// 重拉待办数（失败静默保留旧值；与请求中心同 limit=50）。
  Future<void> refresh() async {
    if (_loading) return;
    _loading = true;
    try {
      final list = await ImApi.getFriendRequestList(limit: 50);
      final myUserId = AuthManager.instance.userId ?? 0;
      final n = list
          .where((r) => r.toUserId == myUserId && r.handleResult == 0)
          .length;
      if (n != pending) {
        pending = n;
        notifyListeners();
      }
    } catch (_) {
      // 静默：保留旧计数
    } finally {
      _loading = false;
    }
  }
}
