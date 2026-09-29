import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 极光推送 Dart 封装（与 jpush_flutter 3.4.0 原生侧通过 MethodChannel('jpush') 通信）。
///
/// 不直接用 pub 包的 Dart 实现的原因：
/// 1. Android 端原生会先发 `onPluginAttached`，Dart 必须回传 bindingId 完成
///    `is_jpush_plugin` 握手，否则原生 channel 为 null（此处已修复）；
/// 2. `onNotifyMessageUnShow` 回调未注册时 pub 版会空指针崩溃，此处兜底转
///    `onReceiveNotification`。
///
/// 使用方式：必须先 [addEventHandler] 再 [setup]（握手依赖回调先行注册）。
typedef EventHandler = Future<dynamic> Function(Map<String, dynamic> event);

class JPush {
  static const String flutterLog = '| JPUSH | Flutter | ';

  factory JPush() => _instance;

  final MethodChannel _channel;

  @visibleForTesting
  JPush.private(MethodChannel channel) : _channel = channel;

  static final JPush _instance = JPush.private(const MethodChannel('jpush'));

  EventHandler? _onReceiveNotification;
  EventHandler? _onNotifyMessageUnShow;
  EventHandler? _onOpenNotification;
  EventHandler? _onReceiveMessage;
  EventHandler? _onReceiveNotificationAuthorization;

  void setup({
    String appKey = '',
    bool production = false,
    String channel = '',
    bool debug = false,
  }) {
    _channel.invokeMethod('setup', {
      'appKey': appKey,
      'channel': channel,
      'production': production,
      'debug': debug,
    });
  }

  /// 注册推送回调。必须在 [setup] 之前调用。
  void addEventHandler({
    EventHandler? onReceiveNotification,
    EventHandler? onNotifyMessageUnShow,
    EventHandler? onOpenNotification,
    EventHandler? onReceiveMessage,
    EventHandler? onReceiveNotificationAuthorization,
  }) {
    _onReceiveNotification = onReceiveNotification;
    _onNotifyMessageUnShow = onNotifyMessageUnShow;
    _onOpenNotification = onOpenNotification;
    _onReceiveMessage = onReceiveMessage;
    _onReceiveNotificationAuthorization = onReceiveNotificationAuthorization;
    _channel.setMethodCallHandler(_handleMethod);
  }

  Future<dynamic> _handleMethod(MethodCall call) async {
    switch (call.method) {
      // jpush_flutter 3.4+ Android：必须先回传 bindingId，原生才能把
      // MethodChannel 交给 JPushHelper，否则会报 channel is null。
      case 'onPluginAttached':
        final String bindingId = call.arguments as String;
        await _channel.invokeMethod('is_jpush_plugin', bindingId);
        return null;
      case 'onReceiveNotification':
        return _onReceiveNotification?.call(
            call.arguments.cast<String, dynamic>());
      case 'onNotifyMessageUnShow':
        final handler = _onNotifyMessageUnShow ?? _onReceiveNotification;
        return handler?.call(call.arguments.cast<String, dynamic>());
      case 'onOpenNotification':
        return _onOpenNotification?.call(
            call.arguments.cast<String, dynamic>());
      case 'onReceiveMessage':
        return _onReceiveMessage?.call(
            call.arguments.cast<String, dynamic>());
      case 'onReceiveNotificationAuthorization':
        return _onReceiveNotificationAuthorization?.call(
            call.arguments.cast<String, dynamic>());
      default:
        throw UnsupportedError('Unrecognized Event');
    }
  }

  /// iOS：申请推送权限（只弹一次，拒绝后只能去系统设置开启）。
  void applyPushAuthority(
      [NotificationSettingsIOS iosSettings = const NotificationSettingsIOS()]) {
    if (!Platform.isIOS) return;
    _channel.invokeMethod('applyPushAuthority', iosSettings.toMap());
  }

  /// iOS：应用前台时是否不展示系统远程通知横幅。
  /// false = 仍由系统直接展示（本项目由 AppDelegate 按当前会话精确控制）。
  void setUnShowAtTheForeground({bool unShow = true}) {
    if (!Platform.isIOS) return;
    _channel.invokeMethod(
      'setUnShowAtTheForeground',
      <String, bool>{'UnShow': unShow},
    );
  }

  /// Android：通过极光申请运行时权限（含 Android 13+ 通知权限）。
  void requestRequiredPermission() {
    if (!Platform.isAndroid) return;
    _channel.invokeMethod('requestRequiredPermission');
  }

  /// 设置 Tag（覆盖式）。
  Future<Map<dynamic, dynamic>> setTags(List<String> tags) async =>
      await _channel.invokeMethod('setTags', tags);

  /// 清空所有 tags。
  Future<Map<dynamic, dynamic>> cleanTags() async =>
      await _channel.invokeMethod('cleanTags');

  /// 设置 alias。
  Future<Map<dynamic, dynamic>> setAlias(String alias) async =>
      await _channel.invokeMethod('setAlias', alias);

  /// 删除 alias。
  Future<Map<dynamic, dynamic>> deleteAlias() async =>
      await _channel.invokeMethod('deleteAlias');

  /// 设置应用角标（Android 仅华为系支持）。
  Future setBadge(int badge) async {
    await _channel.invokeMethod('setBadge', {'badge': badge});
  }

  /// 清除角标。
  Future<void> clearBadge() async {
    await setBadge(0);
  }

  /// 停止接收推送（登出时调用；登录后用 [resumePush] 恢复）。
  Future stopPush() async {
    await _channel.invokeMethod('stopPush');
  }

  /// 恢复推送功能。
  Future resumePush() async {
    await _channel.invokeMethod('resumePush');
  }

  /// 清空通知栏上的所有通知。
  Future clearAllNotifications() async {
    await _channel.invokeMethod('clearAllNotifications');
  }

  /// 获取 RegistrationId（服务端按设备定向推送用）。
  Future<String> getRegistrationID() async {
    final String rid = await _channel.invokeMethod('getRegistrationID');
    return rid;
  }

  /// 发送本地通知（含 fireTime 延时触发与角标）。
  Future<String> sendLocalNotification(LocalNotification notification) async {
    await _channel.invokeMethod('sendLocalNotification', notification.toMap());
    return notification.toMap().toString();
  }

  /// 检测通知授权状态是否打开。
  Future<bool> isNotificationEnabled() async {
    final Map<dynamic, dynamic> result =
        await _channel.invokeMethod('isNotificationEnabled');
    return result['isEnabled'];
  }
}

class NotificationSettingsIOS {
  final bool sound;
  final bool alert;
  final bool badge;

  const NotificationSettingsIOS({
    this.sound = true,
    this.alert = true,
    this.badge = true,
  });

  Map<String, dynamic> toMap() {
    return <String, bool>{'sound': sound, 'alert': alert, 'badge': badge};
  }
}

/// 本地通知实体：id 用于取消；fireTime 为触发时间；badge 仅 iOS。
class LocalNotification {
  final int? buildId;
  final int? id;
  final String? title;
  final String? content;
  final Map<String, String>? extra;
  final DateTime? fireTime;
  final int? badge;
  final String? soundName;
  final String? subtitle;

  const LocalNotification({
    required this.id,
    required this.title,
    required this.content,
    required this.fireTime,
    this.buildId,
    this.extra,
    this.badge = 0,
    this.soundName,
    this.subtitle,
  });

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'content': content,
      'fireTime': fireTime?.millisecondsSinceEpoch,
      'buildId': buildId,
      'extra': extra,
      'badge': badge,
      'soundName': soundName,
      'subtitle': subtitle,
    }..removeWhere((key, value) => value == null);
  }
}
