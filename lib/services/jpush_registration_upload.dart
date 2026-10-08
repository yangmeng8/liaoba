import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'api_client.dart';
import 'auth_manager.dart';
import 'chat_push_service.dart';
import 'push_service.dart';

/// 将极光 [registrationID] 上报后端，供服务端按设备定向推送。
///
/// 同一 ID 已成功上报过则跳过；失败不写入本地记录，便于登录后或下次启动重试。
class JPushRegistrationUpload {
  JPushRegistrationUpload._();

  static const String _lastUploadedRidKey =
      'jpush_last_uploaded_registration_id';

  /// 后端上报接口路径（后端提供：/app-api/member/user/getRegistrationID/{rid}；
  /// 失败仅打印日志不影响功能）。
  static const String _reportPathPrefix =
      '/app-api/member/user/getRegistrationID/';

  static bool get _supportsCurrentPlatform =>
      Platform.isAndroid || Platform.isIOS;
  static bool _isPollingRegistrationId = false;

  static bool _hasLoginInfo() => AuthManager.instance.isLoggedIn;

  /// 申请通知权限：iOS 弹授权弹窗；Android 13+ 走极光运行时权限请求。
  static Future<void> requestNotificationPermissionIfNeeded({
    JPush? jpush,
  }) async {
    if (!_supportsCurrentPlatform) return;

    final JPush client = jpush ?? JPush();
    if (Platform.isIOS) {
      client.applyPushAuthority(
        const NotificationSettingsIOS(sound: true, alert: true, badge: true),
      );
      return;
    }

    try {
      client.requestRequiredPermission();
      debugPrint('[极光 Push] 已请求 Android 通知权限');
    } catch (e, st) {
      debugPrint('[极光 Push] 请求通知权限异常: $e\n$st');
    }
  }

  /// 已登录则轮询 RegistrationID（1s 起最多 20 次 × 3s）并上报后端。
  /// 极光 SDK 初始化异步，rid 可能延迟就绪，故需轮询。
  static Future<bool> pollAndReportRegistrationIdIfLoggedIn({
    JPush? jpush,
    Duration initialDelay = const Duration(seconds: 1),
    int maxAttempts = 20,
    Duration retryDelay = const Duration(seconds: 3),
    bool forceReport = false,
  }) async {
    if (!_supportsCurrentPlatform) return false;

    if (!_hasLoginInfo()) {
      debugPrint('[极光 Push] 当前无登录信息，跳过 RegistrationID 轮询与上报');
      return false;
    }

    // 已有轮询在进行（如启动时的旧轮询，最长 ~61s）：等待其结束再跑本轮，
    // 避免账号切换后的上报请求被旧轮询的并发锁直接拒绝导致漏传
    final DateTime waitDeadline =
        DateTime.now().add(const Duration(seconds: 30));
    while (_isPollingRegistrationId &&
        DateTime.now().isBefore(waitDeadline)) {
      await Future<void>.delayed(const Duration(seconds: 1));
    }

    final JPush client = jpush ?? JPush();
    _isPollingRegistrationId = true;
    try {
      await Future<void>.delayed(initialDelay);

      for (var i = 0; i < maxAttempts; i++) {
        try {
          final String rid = await client.getRegistrationID();
          if (rid.isNotEmpty) {
            debugPrint('[极光 Push] RegistrationID: $rid');
            final bool reported =
                await reportRegistrationIdIfNeeded(rid, force: forceReport);
            if (reported) return true;
            // 拿到 rid 但上报失败（网络异常等）：不提前退出，
            // 留在轮询循环里每 3s 重试一次上报
            debugPrint('[极光 Push] 上报未成功，${retryDelay.inSeconds}s 后重试');
          } else {
            debugPrint('[极光 Push] 第 ${i + 1} 次轮询 RegistrationID 为空');
          }
        } catch (e, st) {
          debugPrint('[极光 Push] getRegistrationID 异常: $e\n$st');
        }
        await Future<void>.delayed(retryDelay);
      }

      debugPrint('[极光 Push] RegistrationID 仍为空，请检查推送权限与网络');
      return false;
    } finally {
      _isPollingRegistrationId = false;
    }
  }

  /// 上报 RegistrationID 到后端。
  ///
  /// 返回 true 表示已上报成功（或同一 ID 此前已上报过，无需重复）；
  /// 返回 false 表示上报失败（未写入本地记录，调用方可稍后重试）。
  static Future<bool> reportRegistrationIdIfNeeded(
    String registrationId, {
    bool force = false,
  }) async {
    if (!_supportsCurrentPlatform) return false;
    if (!_hasLoginInfo()) {
      debugPrint('[极光 Push] 当前无登录信息，跳过 RegistrationID 上报');
      return false;
    }

    final String id = registrationId.trim();
    if (id.isEmpty) return false;

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? last = prefs.getString(_lastUploadedRidKey);
    if (!force && last != null && last == id) {
      return true;
    }

    try {
      final String path =
          '$_reportPathPrefix${Uri.encodeComponent(id)}';
      final response = await ApiClient.dio.get<dynamic>(path);
      // 校验后端统一返回结构 {code, msg, data}（code != 0 会抛 ApiException）
      final data = ApiClient.unwrap(response);
      await prefs.setString(_lastUploadedRidKey, id);
      debugPrint('[极光 Push] RegistrationID 已上报后端: $id');
      debugPrint('[极光 Push] 上报接口返回: ${response.data} (data=$data)');
      return true;
    } catch (e, st) {
      debugPrint('[极光 Push] 上报 RegistrationID 异常: $e\n$st');
      return false;
    }
  }

  /// 登录成功后调用：恢复推送处理 → 恢复推送 → 请求通知权限 → force 上报 rid。
  ///
  /// 首轮轮询（~60s）未完成上报时，自动在 60s 后补一轮，确保 rid 不漏传；
  /// 仍失败则等 App 回前台（HomeShell lifecycle）兜底补报。
  static Future<bool> ensurePushReadyAfterLogin({
    JPush? jpush,
    Duration initialDelay = const Duration(seconds: 1),
    int maxAttempts = 20,
    Duration retryDelay = const Duration(seconds: 3),
  }) async {
    final JPush client = jpush ?? JPush();
    // enablePushHandling/resumePush 原生调用在 iOS 上可能挂起不返回
    //（与登出时 clearBadge 挂死同源），各加 3s 超时兜底，
    // 防止登录后的 rid 上报被卡死在这两步
    await ChatPushService.instance
        .enablePushHandling()
        .timeout(const Duration(seconds: 3), onTimeout: () {});
    try {
      await client
          .resumePush()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (e, st) {
      debugPrint('[极光 Push] 恢复推送异常: $e\n$st');
    }
    await requestNotificationPermissionIfNeeded(jpush: client);
    final bool ok = await pollAndReportRegistrationIdIfLoggedIn(
      jpush: client,
      initialDelay: initialDelay,
      maxAttempts: maxAttempts,
      retryDelay: retryDelay,
      forceReport: true,
    );
    if (!ok) {
      debugPrint('[极光 Push] 登录后首轮上报未完成，60s 后自动补报一轮');
      Future<void>.delayed(const Duration(seconds: 60)).then((_) {
        // 补报前再确认登录态（期间可能已登出）
        if (!_hasLoginInfo()) return;
        unawaited(pollAndReportRegistrationIdIfLoggedIn(
          forceReport: true,
        ));
      });
    }
    return ok;
  }

  /// 退出登录时调用：关推送处理 → 清角标/通知 → 清别名/标签 → 停止推送，
  /// 防止登出后设备仍收到旧账号的推送。
  ///
  /// 注意：消息处理开关（[ChatPushService.disablePushHandlingForLogout]）
  /// 在本函数第一拍同步关闭，可安全地不 await 本函数（登出流程不阻塞）；
  /// 后续原生调用各自带 3s 超时兜底，防 iOS 清角标等回调不返回导致永久挂起。
  static Future<void> stopPushOnLogout({JPush? jpush}) async {
    await ChatPushService.instance.disablePushHandlingForLogout();
    if (!_supportsCurrentPlatform) return;

    final JPush client = jpush ?? JPush();
    try {
      await client
          .clearBadge()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (e, st) {
      debugPrint('[极光 Push] 退出登录清除角标异常: $e\n$st');
    }
    try {
      await client
          .clearAllNotifications()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (e, st) {
      debugPrint('[极光 Push] 退出登录清除通知异常: $e\n$st');
    }
    // 清理设备上可能残留的别名/标签，避免服务端仍按旧账号路由推送。
    try {
      await client.deleteAlias().timeout(
            const Duration(seconds: 3),
            onTimeout: () => <dynamic, dynamic>{},
          );
      debugPrint('[极光 Push] 退出登录已清理推送 Alias');
    } catch (e, st) {
      debugPrint('[极光 Push] 退出登录清理 Alias 异常: $e\n$st');
    }
    try {
      await client.cleanTags().timeout(
            const Duration(seconds: 3),
            onTimeout: () => <dynamic, dynamic>{},
          );
      debugPrint('[极光 Push] 退出登录已清理推送 Tags');
    } catch (e, st) {
      debugPrint('[极光 Push] 退出登录清理 Tags 异常: $e\n$st');
    }
    try {
      await client
          .stopPush()
          .timeout(const Duration(seconds: 3), onTimeout: () {});
    } catch (e, st) {
      debugPrint('[极光 Push] 退出登录停用推送异常: $e\n$st');
    }
  }
}
