import 'package:shared_preferences/shared_preferences.dart';

/// 「已在其他设备接听」的通话 room 标记（多端同振场景）：
///
/// 本端来电被同账号其他设备接听时（1620 信令）记录该 room；
/// 通话结束后聊天室里的 1611 通话消息由服务端统一下发文案
/// （「通话时长 xx:xx」），本端被动收尾的通话应显示
/// 「已在其他设备接听」——渲染时命中本标记即替换文案。
class RtcCallMarks {
  RtcCallMarks._();

  static const String _prefsKey = 'im_rtc_other_device_rooms';

  /// 内存缓存（load 后可用；应用启动时加载一次）。
  static final Set<String> _rooms = <String>{};

  static bool _loaded = false;

  /// 启动时加载历史标记（幂等）。
  static Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _rooms
        ..clear()
        ..addAll(prefs.getStringList(_prefsKey) ?? const <String>[]);
    } catch (_) {
      // 读盘失败：当作空集合，仅影响历史标记命中
    }
  }

  /// 同步查询：该 room 的通话是否由其他设备接听（本端被动收尾）。
  static bool isOtherDeviceAccepted(String room) =>
      room.isNotEmpty && _rooms.contains(room);

  /// 记录 room（1620 收尾时调用）；持久化并限制容量防无限增长。
  static Future<void> markOtherDeviceAccepted(String room) async {
    if (room.isEmpty || _rooms.contains(room)) return;
    _rooms.add(room);
    // 超量裁剪：只保留最近 100 条（Set 无序，直接转 List 截断足够）
    if (_rooms.length > 100) {
      final list = _rooms.toList()..removeRange(0, _rooms.length - 100);
      _rooms
        ..clear()
        ..addAll(list);
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_prefsKey, _rooms.toList());
    } catch (_) {
      // 写盘失败：仅本次会话内生效
    }
  }
}
