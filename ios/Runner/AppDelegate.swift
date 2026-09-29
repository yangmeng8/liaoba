import Flutter
import UIKit
import UserNotifications

// 极光推送 iOS 侧（迁移自 app_im 的 AppDelegate，去掉安装检测/消息提示音等无关模块）：
// - 启动时注册 APNs（查权限→请求→registerForRemoteNotifications）
// - im/notification_visibility channel：接收 Flutter 同步的聊天页可见状态与推送开关
// - 前台通知（willPresent）：按当前会话 targetId 精确控制显示/隐藏
// - 进入后台清角标；didRegister/didFail 打日志便于排查
@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var isChatPageVisible = false
  private let pushEnabledKey = "im_push_enabled"
  private var isPushEnabled = UserDefaults.standard.object(forKey: "im_push_enabled") as? Bool ?? true
  private var activeTargetId: String?
  private let notificationVisibilityChannelName = "im/notification_visibility"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // 注册推送通知权限（应用级生命周期，仍可在 didFinishLaunching 中处理）
    _registerForRemoteNotifications(application)
    // 插件注册已迁移至 didInitializeImplicitFlutterEngine（UIScene 启动顺序要求）
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  /// UIScene 生命周期下，在此注册 Flutter 插件（见 flutter.dev/to/uiscene-migration）
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    _rebindNotificationDelegate(reason: "didInitializeImplicitFlutterEngine")
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "NotificationVisibilityChannel") {
      let channel = FlutterMethodChannel(
        name: notificationVisibilityChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "setChatPageVisible":
          let args = call.arguments as? [String: Any]
          let visible = args?["visible"] as? Bool ?? false
          self.isChatPageVisible = visible
          self.activeTargetId = visible
            ? (args?["targetId"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
          print("[极光推送] 聊天页可见状态已更新: \(visible), targetId=\(self.activeTargetId ?? "")")
          result(nil)
        case "setPushEnabled":
          let args = call.arguments as? [String: Any]
          self.isPushEnabled = args?["enabled"] as? Bool ?? true
          UserDefaults.standard.set(self.isPushEnabled, forKey: self.pushEnabledKey)
          print("[极光推送] Flutter 推送处理状态已更新: \(self.isPushEnabled)")
          if !self.isPushEnabled {
            DispatchQueue.main.async {
              UIApplication.shared.applicationIconBadgeNumber = 0
            }
          }
          result(nil)
        case "rebindNotificationDelegate":
          self._rebindNotificationDelegate(reason: "flutter_method_call")
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }
  }

  override func applicationDidBecomeActive(_ application: UIApplication) {
    super.applicationDidBecomeActive(application)
    _rebindNotificationDelegate(reason: "applicationDidBecomeActive")
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    application.applicationIconBadgeNumber = 0
    print("[极光推送] 已清空 iOS 应用角标, reason=applicationDidEnterBackground")
  }

  /// 注册远程推送通知
  private func _registerForRemoteNotifications(_ application: UIApplication) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self

    // 先检查当前权限状态
    center.getNotificationSettings { settings in
      print("[极光推送] iOS 通知权限状态: \(settings.authorizationStatus.rawValue)（0=未决定, 1=拒绝, 2=授权）")
      if settings.authorizationStatus == .authorized {
        DispatchQueue.main.async {
          application.registerForRemoteNotifications()
        }
      } else {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
          if granted {
            print("[极光推送] 用户授权了通知权限")
            DispatchQueue.main.async {
              application.registerForRemoteNotifications()
            }
          } else {
            print("[极光推送] 用户拒绝了通知权限: \(error?.localizedDescription ?? "未知错误")")
          }
        }
      }
    }
  }

  /// 极光插件可能抢走 UNUserNotificationCenter 代理，需重新接管
  private func _rebindNotificationDelegate(reason: String) {
    UNUserNotificationCenter.current().delegate = self
    print("[极光推送] 重新接管 UNUserNotificationCenter.delegate = AppDelegate, reason=\(reason)")
  }

  /// 注册 APNs 成功
  override func application(_ application: UIApplication,
                          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    // 调用 super，确保极光推送插件能正确处理 deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    print("[极光推送] APNs 注册成功, DeviceToken=\(tokenString)")
  }

  /// 注册 APNs 失败
  override func application(_ application: UIApplication,
                          didFailToRegisterForRemoteNotificationsWithError error: Error) {
    print("[极光推送] APNs 注册失败: \(error.localizedDescription)（检查证书/权限/模拟器）")
  }

  /// 收到推送通知（应用在前台时）：按当前会话决定是否展示系统横幅
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // 先调用 super 让极光插件处理通知（其不会调 completionHandler，需自行调用）
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: { _ in })
    let userInfo = notification.request.content.userInfo
    print("[极光推送][iOS willPresent] payload=\(userInfo)")

    guard isPushEnabled else {
      print("[极光推送] 当前账号已退出，忽略前台通知")
      completionHandler([])
      return
    }

    if _shouldSuppressForegroundNotification(userInfo) {
      print("[极光推送] 当前正在查看对应会话，前台通知不展示")
      completionHandler([])
      return
    }

    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound, .badge])
    } else {
      completionHandler([.alert, .sound, .badge])
    }
  }

  /// 用户点击通知
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse,
                                       withCompletionHandler completionHandler: @escaping () -> Void) {
    print("[极光推送][iOS didReceive] payload=\(response.notification.request.content.userInfo)")
    guard isPushEnabled else {
      print("[极光推送] 当前账号已退出，忽略通知点击")
      completionHandler()
      return
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// 正在查看某会话时，抑制该会话的前台通知（其余会话正常展示）
  private func _shouldSuppressForegroundNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard isChatPageVisible else {
      return false
    }

    let targetId = _resolveTargetId(userInfo)
    print("[极光推送] 会话命中检查: activeTargetId=\(activeTargetId ?? ""), payloadTargetId=\(targetId)")

    if let activeTargetId, !activeTargetId.isEmpty, !targetId.isEmpty, activeTargetId == targetId {
      print("[极光推送] 命中 targetId，抑制当前聊天页通知")
      return true
    }
    return false
  }

  /// 从通知 payload 多层结构解析 targetId（群=groupId，私聊=发送者 userId）
  private func _resolveTargetId(_ userInfo: [AnyHashable: Any]) -> String {
    let sources = _structuredSources(userInfo)
    if let groupId = _readString(
      from: sources,
      keys: ["GroupId", "groupId", "groupID", "toGroupId"]
    ), !groupId.isEmpty {
      return groupId
    }

    if let peerId = _readString(
      from: sources,
      keys: [
        "From_Account", "fromAccount", "userId", "userID",
        "fromUserId", "fromUserID", "peerId", "peerID",
        "senderId", "senderID", "from"
      ]
    ), !peerId.isEmpty {
      return peerId
    }

    // 兜底：从 conversationId（group_/c2c_ 前缀）还原 targetId
    if let conversationId = _readString(
      from: sources,
      keys: ["conversationId", "conversationID", "conversation_id", "convId", "sessionId"]
    ), !conversationId.isEmpty {
      if conversationId.hasPrefix("group_") {
        return String(conversationId.dropFirst("group_".count))
      }
      if conversationId.hasPrefix("c2c_") {
        return String(conversationId.dropFirst("c2c_".count))
      }
      return conversationId
    }
    return ""
  }

  private func _structuredSources(_ userInfo: [AnyHashable: Any]) -> [[String: Any]] {
    let raw = _asStringKeyedDictionary(userInfo)
    let extras = _asMap(raw["extras"])
    let message = _asMap(raw["message"])
    let content = _asMap(raw["content"])
    return [message, content, extras, raw]
  }

  private func _asStringKeyedDictionary(_ value: [AnyHashable: Any]) -> [String: Any] {
    var result: [String: Any] = [:]
    for (key, val) in value {
      result[String(describing: key)] = val
    }
    return result
  }

  private func _asMap(_ value: Any?) -> [String: Any] {
    guard let value else {
      return [:]
    }
    if let map = value as? [String: Any] {
      return map
    }
    if let map = value as? [AnyHashable: Any] {
      return _asStringKeyedDictionary(map)
    }
    if let text = value as? String {
      let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard (trimmed.hasPrefix("{") && trimmed.hasSuffix("}")) ||
            (trimmed.hasPrefix("[") && trimmed.hasSuffix("]")) else {
        return [:]
      }
      guard let data = trimmed.data(using: .utf8),
            let decoded = try? JSONSerialization.jsonObject(with: data) else {
        return [:]
      }
      if let map = decoded as? [String: Any] {
        return map
      }
      if let map = decoded as? [AnyHashable: Any] {
        return _asStringKeyedDictionary(map)
      }
    }
    return [:]
  }

  private func _readString(from sources: [[String: Any]], keys: [String]) -> String? {
    for source in sources {
      for key in keys {
        guard let value = source[key] else {
          continue
        }
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty {
            return trimmed
          }
          continue
        }
        if !(value is [Any]) && !(value is [String: Any]) && !(value is [AnyHashable: Any]) {
          let text = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines)
          if !text.isEmpty {
            return text
          }
        }
      }
    }
    return nil
  }
}
