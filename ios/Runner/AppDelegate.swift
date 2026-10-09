import AVFoundation
import CallKit
import Flutter
import PushKit
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

  // MARK: - VoIP Push + CallKit（iOS 系统级全屏来电）
  private let callkitChannelName = "im/callkit"
  private var callkitChannel: FlutterMethodChannel?
  private var callProvider: CXProvider?
  private var voipRegistry: PKPushRegistry?
  private var currentCallUuid: UUID?
  private var currentCallPayload: [String: Any] = [:]
  /// engine 未就绪时缓存的 CallKit 事件（冷启动点接听：incoming → answer 依次入队）
  private var pendingCallkitEvents: [[String: Any]] = []

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // 注册推送通知权限（普通 APNs，与 PushKit VoIP 并行）
    _registerForRemoteNotifications(application)
    // PushKit 注册放在 super 之后（Flutter implicit engine 场景的启动时序更稳）
    _setupCallKit()
    _setupVoipPush()
    return result
  }

  /// UIScene 生命周期下，在此注册 Flutter 插件（见 flutter.dev/to/uiscene-migration）
  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    _rebindNotificationDelegate(reason: "didInitializeImplicitFlutterEngine")
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "CallKitChannel") {
      let channel = FlutterMethodChannel(
        name: callkitChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        guard let self = self else {
          result(nil)
          return
        }
        switch call.method {
        case "endCall":
          // Flutter 侧通话结束（对方挂断/超时/取消）→ 同步结束 CallKit 界面
          if let uuid = self.currentCallUuid {
            // iOS 26 SDK：reportCallEnded 改名 reportCall(with:endedAt:reason:)
            self.callProvider?.reportCall(
              with: uuid,
              endedAt: nil,
              reason: CXCallEndedReason.remoteEnded
            )
          }
          self.currentCallUuid = nil
          self.currentCallPayload = [:]
          self._playRingback(false)
          result(nil)
        case "startRingback":
          self._playRingback(true)
          result(nil)
        case "stopRingback":
          self._playRingback(false)
          result(nil)
        case "startRingtone":
          self._playRingtone(true)
          result(nil)
        case "stopRingtone":
          self._playRingtone(false)
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      callkitChannel = channel
      // 冷启动缓存事件 flush（按序：incoming → answer/reject）
      if !pendingCallkitEvents.isEmpty {
        let events = pendingCallkitEvents
        pendingCallkitEvents.removeAll()
        DispatchQueue.main.async {
          for event in events {
            channel.invokeMethod("onCallkitEvent", arguments: event)
          }
        }
        print("[CallKit] 已 flush 缓存事件 \(events.count) 条")
      }
    }
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

  // MARK: - VoIP Push + CallKit 实现

  /// CallKit Provider：锁屏全屏来电界面 + 系统接听/拒接按钮
  /// 回铃音播放器（主叫等待接听时循环播放）
  private var ringbackPlayer: AVAudioPlayer?

  /// 播放/停止回铃音（主叫等待接听）
  private func _playRingback(_ play: Bool) {
    if play {
      if ringbackPlayer?.isPlaying == true {
        return
      }
      guard let url = Bundle.main.url(forResource: "ringback", withExtension: "caf") else {
        print("[Ringback] 资源未找到")
        return
      }
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        ringbackPlayer = try AVAudioPlayer(contentsOf: url)
        ringbackPlayer?.numberOfLoops = -1 // 循环：1 秒嘟 + 3 秒静音
        ringbackPlayer?.play()
        print("[Ringback] 回铃音开始")
      } catch {
        print("[Ringback] 播放失败: \(error.localizedDescription)")
      }
    } else {
      ringbackPlayer?.stop()
      ringbackPlayer = nil
      print("[Ringback] 回铃音停止")
    }
  }

  /// 振铃音播放器（被叫来电页弹出时循环播放）
  private var ringtonePlayer: AVAudioPlayer?

  /// 播放/停止被叫振铃音（复用来电铃声资源 push_notification.caf）
  private func _playRingtone(_ play: Bool) {
    if play {
      if ringtonePlayer?.isPlaying == true {
        return
      }
      guard let url = Bundle.main.url(forResource: "push_notification", withExtension: "caf") else {
        print("[Ringtone] 资源未找到")
        return
      }
      do {
        try AVAudioSession.sharedInstance().setCategory(.playback)
        try AVAudioSession.sharedInstance().setActive(true)
        ringtonePlayer = try AVAudioPlayer(contentsOf: url)
        ringtonePlayer?.numberOfLoops = -1
        ringtonePlayer?.play()
        print("[Ringtone] 振铃音开始")
      } catch {
        print("[Ringtone] 播放失败: \(error.localizedDescription)")
      }
    } else {
      ringtonePlayer?.stop()
      ringtonePlayer = nil
      print("[Ringtone] 振铃音停止")
    }
  }

  private func _setupCallKit() {
    let config: CXProviderConfiguration
    if #available(iOS 14.0, *) {
      config = CXProviderConfiguration()
    } else {
      config = CXProviderConfiguration(localizedName: "IM")
    }
    config.supportsVideo = true
    config.includesCallsInRecents = false
    config.ringtoneSound = "push_notification.caf"
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    callProvider = provider
    print("[CallKit] CXProvider 已初始化")
  }

  /// PushKit VoIP 注册：拿到 VoIP deviceToken（上报 Flutter→后端）
  private func _setupVoipPush() {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    print("[CallKit] PushKit VoIP 已注册")
  }

  /// 原生 → Flutter 事件（engine 未就绪时缓存，ready 后 flush）
  private func _sendToFlutter(_ event: [String: Any]) {
    if let channel = callkitChannel {
      DispatchQueue.main.async {
        channel.invokeMethod("onCallkitEvent", arguments: event)
      }
    } else {
      pendingCallkitEvents.append(event)
      print("[CallKit] engine 未就绪，缓存事件: \(event["event"] ?? "")")
    }
  }

  /// 从 VoIP push payload 多层结构解析来电信令（顶层/aps/extras 嵌套）
  private func _parseCallPayload(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
    let raw = _asStringKeyedDictionary(userInfo)
    let aps = _asMap(raw["aps"])
    let extras = _asMap(raw["extras"])
    let sources = [raw, aps, extras, _asMap(raw["payload"])]
    var data: [String: Any] = [:]
    if let v = _readString(from: sources, keys: ["roomId", "room"]) { data["roomId"] = v }
    if let v = _readString(from: sources, keys: ["messageType", "msgType"]) { data["messageType"] = v }
    if let v = _readString(from: sources, keys: ["inviterUserId"]) { data["inviterUserId"] = v }
    if let v = _readString(from: sources, keys: ["inviterNickname", "nickname", "senderName"]) { data["inviterNickname"] = v }
    if let v = _readString(from: sources, keys: ["inviterAvatar", "avatar"]) { data["inviterAvatar"] = v }
    if let v = _readString(from: sources, keys: ["mediaType"]) { data["mediaType"] = v }
    if let v = _readString(from: sources, keys: ["conversationType"]) { data["conversationType"] = v }
    return data
  }
}

// MARK: - PKPushRegistryDelegate（VoIP 推送到达 → CallKit 上报来电）
extension AppDelegate: PKPushRegistryDelegate {
  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    let token = pushCredentials.token.map { String(format: "%02.2hhx", $0) }.joined()
    print("[CallKit] VoIP Token(\(token.count)字符): \(token)")
    _sendToFlutter(["event": "voipToken", "token": token])
  }

  /// 诊断：VoIP token 失效回调（注册被系统拒绝时触发）
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    print("[CallKit] ❌ VoIP Token 失效（注册被系统拒绝）: type=\(type.rawValue)")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: [AnyHashable: Any],
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    print("[CallKit] 收到 VoIP 推送: \(payload)")
    let data = _parseCallPayload(payload)
    guard let roomId = data["roomId"] as? String, !roomId.isEmpty else {
      // 非来电 VoIP 推送：直接放行（苹果要求 report，但极光仅来电场景发 VoIP）
      print("[CallKit] VoIP 推送缺少 roomId，忽略")
      completion()
      return
    }
    currentCallUuid = UUID()
    currentCallPayload = data
    let uuid = currentCallUuid!
    let update = CXCallUpdate()
    let nickname = (data["inviterNickname"] as? String) ?? "IM"
    update.remoteHandle = CXHandle(type: .generic, value: nickname)
    update.localizedCallerName = nickname
    let mediaType = Int(data["mediaType"] as? String ?? "") ?? 1
    update.hasVideo = mediaType == 2
    callProvider?.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        print("[CallKit] 上报来电失败: \(error.localizedDescription)")
      } else {
        print("[CallKit] 系统来电界面已弹出: \(nickname) roomId=\(roomId)")
      }
      // PushKit completion 必须在 reportNewIncomingCall 回调后调用（苹果红线）
      completion()
    }
    // 通知 Flutter 弹 App 内来电页（CallKit 接听后直接进通话）
    _sendToFlutter(["event": "incoming", "payload": data])
  }
}

// MARK: - CXProviderDelegate（系统来电界面的接听/拒接回调）
extension AppDelegate: CXProviderDelegate {
  /// 用户点「接听」：App 自动回前台，通知 Flutter 执行接听
  func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
    print("[CallKit] 用户点击接听")
    _sendToFlutter(["event": "answer", "payload": currentCallPayload])
    action.fulfill()
  }

  /// 用户点「拒接」/「挂断」：通知 Flutter 拒绝
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    print("[CallKit] 用户点击拒接/挂断")
    _sendToFlutter(["event": "reject", "payload": currentCallPayload])
    action.fulfill()
    currentCallUuid = nil
    currentCallPayload = [:]
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // LiveKit 自管音频会话，无需处理
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    action.fulfill()
  }

  func providerDidReset(_ provider: CXProvider) {
    currentCallUuid = nil
    currentCallPayload = [:]
  }
}
