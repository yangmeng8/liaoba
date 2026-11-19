import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

/// 设备唯一标识（多端同振接听感知用）：
///
/// - deviceId：安装时生成 UUID 持久化到 SharedPreferences（重装会变，
///   卸载重装视为新设备可接受；同账号多端登录时各端各自唯一）
/// - deviceType：平台标识 ios/android/macos/windows，接听时随 accept
///   上报后端，后端 1602 广播带 deviceId，各端对比判断是否本设备接听
class DeviceIdentity {
  DeviceIdentity._();

  static const String _prefsKey = 'im_device_id';

  static String? _cached;

  /// 已生成的 deviceId 缓存（未生成过返回 null；1602 对比用，同步访问）。
  static String? get cachedDeviceId => _cached;

  /// 设备唯一标识（首次调用生成并持久化，之后直接返回缓存）。
  static Future<String> deviceId() async {
    final cached = _cached;
    if (cached != null && cached.isNotEmpty) return cached;
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString(_prefsKey);
    if (id == null || id.isEmpty) {
      // 首次：生成 UUID v4（不引额外依赖，用 Random 简易拼装）
      final now = DateTime.now().microsecondsSinceEpoch.toRadixString(16);
      final rnd = DateTime.now().hashCode;
      id = '$now-${(rnd ^ now.hashCode).toUnsigned(32).toRadixString(16)}-'
          '${Platform.operatingSystem}';
      await prefs.setString(_prefsKey, id);
    }
    _cached = id;
    return id;
  }

  /// 设备类型标识（app-api/im/rtc/accept 约定的整型枚举）：
  /// 1-安卓 2-苹果 3-Win 4-Mac 5-Web。
  static int deviceType() {
    if (Platform.isAndroid) return 1;
    if (Platform.isIOS) return 2;
    if (Platform.isWindows) return 3;
    if (Platform.isMacOS) return 4;
    return 5;
  }
}
