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
  /// APNs 环境探测 channel：Dart 侧初始化极光前先问一次包内真实的 aps-environment
  private let pushEnvChannelName = "im/push_env"
  private var pushEnvChannel: FlutterMethodChannel?

  // MARK: - VoIP Push + CallKit（iOS 系统级全屏来电）
  private let callkitChannelName = "im/callkit"
  /// 来电通知分类（微信风格：通知/横幅上直接显示「接听 / 拒绝」按钮；
  /// 后端推送需带 category=im_call_invite，见 docs/ios 对接说明）
  private let callInviteCategoryId = "im_call_invite"
  private let callAnswerActionId = "im_call_answer"
  private let callRejectActionId = "im_call_reject"
  private var callkitChannel: FlutterMethodChannel?
  private var callProvider: CXProvider?
  private var voipRegistry: PKPushRegistry?
  /// 最近一次已上报的 VoIP token（PushKit 可能对同一 token 多次回调）
  private var lastVoipTokenHex: String?
  /// 已上报极光的 VoIP token（避免重复上报刷屏）
  private var lastVoipTokenSentToJPush: String?
  private var currentCallUuid: UUID?
  private var currentCallPayload: [String: Any] = [:]
  /// engine 未就绪时缓存的 CallKit 事件（冷启动点接听：incoming → answer 依次入队）
  private var pendingCallkitEvents: [[String: Any]] = []
  /// 缓存来电事件的写入时间（超过 90s 视为过期，避免下次启动误处理上一通旧来电）
  private var pendingCallkitEventsSince: Date?
  /// Dart 侧是否已注册 onCallkitEvent handler（由 consumePendingCallkitEvents 首次调用确认）。
  /// 在这个握手完成前，原生事件必须继续缓存：channel 虽然已经建好，
  /// 但 Dart 还没 setMethodCallHandler，此时 invokeMethod 会被直接丢弃
  /// —— 冷启动点「接听」就是这样丢的（表现：App 起来了却没有通话页）。
  private var dartCallkitHandlerReady = false
  /// CallKit 通话的生命周期 = 真实通话的生命周期。
  ///
  /// 之前是「App 回到前台 / 通话页上屏就立刻 reportCall(endedAt:) 收起系统来电界面」，
  /// 真机验证下来这条路是错的：锁屏接听时系统并不会因为「通话还在 active」就把 App
  /// 切到前台（iOS 26.3 实测），收得太早反而让锁屏上连「通话中」的界面都没了，
  /// 用户解锁后无处可点、也看不出电话还在。
  /// 现在的做法：接听后一直保持通话 active，只在通话真的结束（App 内挂断 /
  /// 对方挂断 / 用户从系统界面挂断）时才收起——这也是系统对 VoIP 应用的预期用法。
  /// 最近一通来电 payload 的持久化 key：冷启动点「接听」时进程内的
  /// currentCallPayload 已丢失（上次进程早就被系统回收），只能靠它还原 roomId
  private let pendingCallPayloadKey = "im_callkit_pending_call_payload"
  /// 来电写入时间戳：兜底恢复时超过 90s 视为过期来电，避免拉起早就结束的通话
  private let pendingCallAtKey = "im_callkit_pending_call_at"
  /// 用户是否已经点过「接听」：App 被杀/锁屏时事件桥可能丢事件，
  /// Dart 侧靠这个标记决定是「只弹来电页」还是「直接接听」
  private let pendingCallAnsweredKey = "im_callkit_call_answered"

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    // 注册推送通知权限（普通 APNs，与 PushKit VoIP 并行）
    _registerForRemoteNotifications(application)
    // 注册来电通知分类（锁屏/横幅上的「接听 / 拒绝」按钮）
    _registerCallNotificationCategory()
    // PushKit 注册放在 super 之后（Flutter implicit engine 场景的启动时序更稳）
    _setupCallKit()
    _setupVoipPush()
    // 冷启动：还原上一通来电信息（用户可能在 App 被杀后才点「接听」）
    if let saved = UserDefaults.standard.dictionary(forKey: pendingCallPayloadKey),
       !saved.isEmpty {
      currentCallPayload = saved
      imLog("[CallKit] 已还原上次来电信息: roomId=\(saved["roomId"] ?? "")")
    }
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
          // 通话结束同时释放通话音频会话，否则 .playAndRecord 会一直占用着
          // （其它 App 的音乐被压低、麦克风指示灯不灭）。
          self._deactivateCallAudioSession(reason: "endCall")
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
          self._clearPersistedCallPayload()
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
        case "getVoipToken":
          // Flutter 侧主动拉取：PushKit 回调可能早于 Dart handler 注册（启动竞态），
          // 也便于排查「token 是否真的拿到过」。
          if let token = self.voipRegistry?.pushToken(for: .voIP) {
            result(AppDelegate._hexToken(token))
          } else {
            result(nil)
          }
        case "consumePendingCallkitEvents":
          // 冷启动点通知里的「接听」：事件早于 Dart handler 注册，交给 Dart 启动后主动取走
          let expired = self.pendingCallkitEventsSince
            .map { Date().timeIntervalSince($0) > 90 } ?? false
          let events = expired ? [] : self.pendingCallkitEvents
          self.pendingCallkitEvents.removeAll()
          self.pendingCallkitEventsSince = nil
          // Dart 已注册 handler：之后的来电/接听事件可以直接推送，不再缓存
          self.dartCallkitHandlerReady = true
          imLog("[CallKit] Dart 取走缓存事件 \(events.count) 条")
          result(events)
        case "getPendingCall":
          // 持久化的来电信息 + 「用户是否已点接听」：App 被系统回收后再点接听时，
          // 事件桥可能整条丢失（进程换了），Dart 启动后靠这份存档还原来电页，
          // 已点接听则直接接听。
          let pendingPayload = UserDefaults.standard.dictionary(forKey: self.pendingCallPayloadKey) ?? [:]
          let pendingAnswered = UserDefaults.standard.bool(forKey: self.pendingCallAnsweredKey)
          let pendingAt = UserDefaults.standard.double(forKey: self.pendingCallAtKey)
          imLog("[CallKit] Dart 拉取待处理来电: roomId=\(pendingPayload["roomId"] ?? ""), answered=\(pendingAnswered)")
          result([
            "payload": pendingPayload,
            "answered": pendingAnswered,
            "at": pendingAt,
          ])
        case "clearPendingCall":
          self._clearPersistedCallPayload()
          result(nil)
        case "appendDiagLog":
          // Dart 侧来电链路日志落盘（与原生 imLog 写同一个文件），
          // 锁屏接听/杀进程接听这类场景事后可直接取出文件排查
          let args = call.arguments as? [String: Any]
          if let line = args?["line"] as? String, !line.isEmpty {
            appendDiagLogLine(line)
          }
          result(nil)
        case "getDiagLogPath":
          result(diagLogURL()?.path)
        case "callPageShown":
          // Dart 侧通话页已经 push 上屏。系统来电界面不再在这里收起：
          // CallKit 通话与真实通话同生命周期（见 currentCallUuid 上的说明），
          // 锁屏/后台接听后系统可能还没把 App 切到前台，收起系统界面会让
          // 用户解锁后连「通话中」的入口都没有。
          imLog("[CallKit] Dart 侧通话页已上屏")
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      callkitChannel = channel
      // 注意：这里不能主动 flush 缓存事件 —— 此刻 Dart 侧还没注册 handler，
      // invokeMethod 会被直接丢弃，紧接着 Dart 调 consumePendingCallkitEvents
      // 又发现缓存已清空，冷启动点「接听」就彻底没反应（表现：点了接听不跳转）。
      // 事件一直缓存，直到 Dart 主动取走。
      imLog("[CallKit] channel 就绪，缓存待 Dart 取走事件 \(pendingCallkitEvents.count) 条")
    }
    // APNs 环境探测：极光 setup 的 production 必须与包内 aps-environment 一致，
    // 否则「Release 配置 + 开发签名」会把沙箱令牌按生产环境上报，APNs 直接拒收。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "PushEnvChannel") {
      let channel = FlutterMethodChannel(
        name: pushEnvChannelName,
        binaryMessenger: registrar.messenger()
      )
      channel.setMethodCallHandler { [weak self] call, result in
        switch call.method {
        case "getApsEnvironment":
          result(self?._detectApsEnvironment() ?? "unknown")
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      pushEnvChannel = channel
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
          imLog("[极光推送] 聊天页可见状态已更新: \(visible), targetId=\(self.activeTargetId ?? "")")
          result(nil)
        case "setPushEnabled":
          let args = call.arguments as? [String: Any]
          self.isPushEnabled = args?["enabled"] as? Bool ?? true
          UserDefaults.standard.set(self.isPushEnabled, forKey: self.pushEnabledKey)
          imLog("[极光推送] Flutter 推送处理状态已更新: \(self.isPushEnabled)")
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
    imLog("[CallKit] App 已进入前台(applicationDidBecomeActive)，"
      + "callActive=\(currentCallUuid != nil)")
    // 注意：这里不再收起 CallKit 通话界面。通话还在进行时收起它，用户再锁屏
    // 就没有系统通话界面可用了；通话结束由 Dart 侧 endCall / 用户挂断触发。
    // 极光 SDK setup 可能覆盖通知分类，回到前台时补齐
    _registerCallNotificationCategory()
  }

  override func applicationWillEnterForeground(_ application: UIApplication) {
    super.applicationWillEnterForeground(application)
    // 锁屏接听链路的关键节点：系统把 App 拉起时先走 willEnterForeground，
    // 之前日志里缺失这一行 = App 根本没被系统拉起（或很晚才拉起）。
    imLog("[CallKit] App 即将回到前台(applicationWillEnterForeground)，"
      + "callActive=\(currentCallUuid != nil)")
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    super.applicationDidEnterBackground(application)
    application.applicationIconBadgeNumber = 0
    imLog("[极光推送] 已清空 iOS 应用角标, reason=applicationDidEnterBackground")
  }

  /// 注册远程推送通知
  private func _registerForRemoteNotifications(_ application: UIApplication) {
    let center = UNUserNotificationCenter.current()
    center.delegate = self

    // 先检查当前权限状态
    center.getNotificationSettings { settings in
      imLog("[极光推送] iOS 通知权限状态: \(settings.authorizationStatus.rawValue)（0=未决定, 1=拒绝, 2=授权）")
      if settings.authorizationStatus == .authorized {
        DispatchQueue.main.async {
          application.registerForRemoteNotifications()
        }
      } else {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
          if granted {
            imLog("[极光推送] 用户授权了通知权限")
            DispatchQueue.main.async {
              application.registerForRemoteNotifications()
            }
          } else {
            imLog("[极光推送] 用户拒绝了通知权限: \(error?.localizedDescription ?? "未知错误")")
          }
        }
      }
    }
  }

  /// 极光插件可能抢走 UNUserNotificationCenter 代理，需重新接管
  private func _rebindNotificationDelegate(reason: String) {
    UNUserNotificationCenter.current().delegate = self
    imLog("[极光推送] 重新接管 UNUserNotificationCenter.delegate = AppDelegate, reason=\(reason)")
  }

  /// 注册来电通知分类：来电推送带上 category=im_call_invite 后，
  /// 锁屏/横幅通知会直接出现「接听」「拒绝」按钮（对齐微信体验，避免 CallKit 全屏滑动接听）。
  private func _registerCallNotificationCategory() {
    let answer = UNNotificationAction(
      identifier: callAnswerActionId,
      title: "接听",
      options: [.foreground]
    )
    let reject = UNNotificationAction(
      identifier: callRejectActionId,
      title: "拒绝",
      options: [.destructive]
    )
    let category = UNNotificationCategory(
      identifier: callInviteCategoryId,
      actions: [answer, reject],
      intentIdentifiers: [],
      options: [.customDismissAction]
    )
    let center = UNUserNotificationCenter.current()
    center.getNotificationCategories { existing in
      var merged = existing
      merged.insert(category)
      center.setNotificationCategories(merged)
      imLog("[CallKit] 来电通知分类已注册: \(self.callInviteCategoryId)（接听 / 拒绝）")
    }
  }

  /// 读取包内真实的 APNs 环境（aps-environment）。
  /// 「Release 配置 + 开发签名（Development profile）」是一种常见组合，
  /// 此时令牌仍是沙箱令牌，如果极光按生产环境上报，APNs 会以 BadDeviceToken 拒收，
  /// 表现为「Debug 跑得好好的，打成 IPA 后一条推送都收不到」。
  /// iOS SDK 不提供 SecTask API，这里直接解析包内 embedded.mobileprovision 的 Entitlements。
  private func _detectApsEnvironment() -> String {
    guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url),
          let text = String(data: data, encoding: .isoLatin1),
          let start = text.range(of: "<?xml"),
          let end = text.range(of: "</plist>", range: start.upperBound..<text.endIndex),
          let plistData = String(text[start.lowerBound..<end.upperBound]).data(using: .isoLatin1),
          let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil)
            as? [String: Any],
          let entitlements = plist["Entitlements"] as? [String: Any],
          let environment = entitlements["aps-environment"] as? String,
          !environment.isEmpty
    else {
      // App Store 分发包不含 embedded.mobileprovision，此时必然是生产环境
      imLog("[极光推送] 未读到 aps-environment，按构建模式推断")
      return "unknown"
    }
    imLog("[极光推送] 包内实际 aps-environment=\(environment)")
    return environment
  }

  /// 注册 APNs 成功
  override func application(_ application: UIApplication,
                          didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    // 调用 super，确保极光推送插件能正确处理 deviceToken
    super.application(application, didRegisterForRemoteNotificationsWithDeviceToken: deviceToken)
    let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
    imLog("[极光推送] APNs 注册成功, DeviceToken=\(tokenString)")
  }

  /// 注册 APNs 失败
  override func application(_ application: UIApplication,
                          didFailToRegisterForRemoteNotificationsWithError error: Error) {
    imLog("[极光推送] APNs 注册失败: \(error.localizedDescription)（检查证书/权限/模拟器）")
  }

  /// 收到推送通知（应用在前台时）：按当前会话决定是否展示系统横幅
  override func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification,
                                       withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    // 先调用 super 让极光插件处理通知（其不会调 completionHandler，需自行调用）
    super.userNotificationCenter(center, willPresent: notification, withCompletionHandler: { _ in })
    let userInfo = notification.request.content.userInfo
    imLog("[极光推送][iOS willPresent] payload=\(userInfo)")

    guard isPushEnabled else {
      imLog("[极光推送] 当前账号已退出，忽略前台通知")
      completionHandler([])
      return
    }

    if _shouldSuppressForegroundNotification(userInfo) {
      imLog("[极光推送] 当前正在查看对应会话，前台通知不展示")
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
    imLog("[极光推送][iOS didReceive] payload=\(response.notification.request.content.userInfo)")
    let actionId = response.actionIdentifier
    // 来电通知的「接听 / 拒绝」按钮（分类 im_call_invite）
    if actionId == callAnswerActionId || actionId == callRejectActionId {
      let userInfo = response.notification.request.content.userInfo
      let event = actionId == callAnswerActionId ? "answer" : "reject"
      // 通知 payload 的字段命名与 VoIP 推送不一定一致（可能解析不到 roomId）。
      // 解析不到时回退到 VoIP 推送阶段持久化的来电信息，否则 Dart 拿不到
      // roomId → 表现就是「点接听跳进 App 了，却没有通话页」。
      var payload = _parseCallPayload(userInfo)
      if (payload["roomId"] as? String ?? "").isEmpty {
        if let saved = UserDefaults.standard.dictionary(forKey: pendingCallPayloadKey),
           !saved.isEmpty {
          imLog("[CallKit] 通知未带房间号，回退持久化来电信息")
          payload = saved
        }
      }
      imLog("[CallKit] 来电通知按钮:\(event), payload=\(payload)")
      if event == "answer" {
        // 先落盘再通知 Dart：Dart 可能还没就绪（冷启动），靠这份存档兜底
        if !payload.isEmpty {
          UserDefaults.standard.set(payload, forKey: pendingCallPayloadKey)
          UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: pendingCallAtKey)
          currentCallPayload = payload
        }
        UserDefaults.standard.set(true, forKey: pendingCallAnsweredKey)
      } else {
        _clearPersistedCallPayload()
      }
      _sendToFlutter(["event": event, "payload": payload])
      completionHandler()
      return
    }
    guard isPushEnabled else {
      imLog("[极光推送] 当前账号已退出，忽略通知点击")
      completionHandler()
      return
    }
    // 来电通知点「正文」（不是接听/拒绝按钮）：直接转给 Dart 弹来电页。
    // 不走极光插件的 onOpenNotification 冷启动链路 —— 那条链路在本进程刚被
    // 推送拉起时不一定能及时送达，表现就是「点了通知跳进 App 却没有通话页」。
    if actionId == UNNotificationDefaultActionIdentifier {
      let callPayload = _parseCallPayload(response.notification.request.content.userInfo)
      let roomId = callPayload["roomId"] as? String ?? ""
      let msgType = (callPayload["messageType"] as? String ?? "").lowercased()
      // 只有「确实是来电」才走这条捷径（普通聊天推送偶尔也可能带 room 字段）
      let looksLikeCall = msgType == "rtc_call" || msgType == "call_invite"
        || (!roomId.isEmpty
            && (callPayload["mediaType"] != nil || callPayload["inviterUserId"] != nil))
      if !roomId.isEmpty, looksLikeCall {
        imLog("[CallKit] 点击来电通知正文，直接补入来电页 roomId=\(roomId)")
        if UserDefaults.standard.dictionary(forKey: pendingCallPayloadKey) == nil {
          UserDefaults.standard.set(callPayload, forKey: pendingCallPayloadKey)
          UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: pendingCallAtKey)
          UserDefaults.standard.set(false, forKey: pendingCallAnsweredKey)
        }
        _sendToFlutter(["event": "incoming", "payload": callPayload])
      }
    }
    super.userNotificationCenter(center, didReceive: response, withCompletionHandler: completionHandler)
  }

  /// 正在查看某会话时，抑制该会话的前台通知（其余会话正常展示）
  ///
  /// 命中判定用「候选 id 集合」而不是单一解析结果：同一条推送里往往同时带
  /// userId（可能是被叫本人）、senderId / fromUserId（对方）等多个 id，按字段
  /// 顺序只取一个时会出现「同一个会话有时被抑制、有时弹出通知」。
  /// 群聊只认 groupId，避免群消息里带上的成员 id 误命中正在看的私聊。
  private func _shouldSuppressForegroundNotification(_ userInfo: [AnyHashable: Any]) -> Bool {
    guard isChatPageVisible, let active = activeTargetId, !active.isEmpty else {
      imLog("[极光推送] 聊天页可见标记未生效（visible=\(isChatPageVisible), "
        + "activeTargetId=\(activeTargetId ?? "")），不抑制前台通知")
      return false
    }

    let candidates = _payloadTargetCandidates(_structuredSources(userInfo))
    let hit = candidates.contains(active)
    imLog("[极光推送] 会话命中检查: activeTargetId=\(active), "
      + "payload候选=\(candidates.sorted()), 命中=\(hit)")
    if hit {
      imLog("[极光推送] 命中 targetId，抑制当前聊天页通知")
    }
    return hit
  }

  /// 从通知 payload 多层结构解析「这条推送涉及的会话 id」候选集合：
  /// 群/频道 = groupId（唯一，没有就返回空集，不冒险用发送者 id 命中私聊）；
  /// 私聊 = 对方 id 的各种字段别名 + conversationId 里内嵌的 id。
  private func _payloadTargetCandidates(_ sources: [[String: Any]]) -> Set<String> {
    if let groupId = _readString(
      from: sources,
      keys: ["GroupId", "groupId", "groupID", "toGroupId"]
    ), !groupId.isEmpty {
      return [groupId]
    }

    // conversationType：1=私聊 2=群聊 3=频道（与后端 im-notification 一致）
    let conversationType = _readString(
      from: sources,
      keys: ["conversationType", "conversation_type", "chatType", "sessionType"]
    ) ?? ""
    if conversationType == "2" || conversationType == "3" {
      return []
    }

    var ids = Set<String>()
    for key in [
      "From_Account", "fromAccount", "userId", "userID",
      "fromUserId", "fromUserID", "peerId", "peerID",
      "senderId", "senderID", "from",
    ] {
      if let value = _readString(from: sources, keys: [key]), !value.isEmpty {
        ids.insert(value)
      }
    }

    // conversationId 兜底：c2c_123 / group_456 / 1_123
    if let conversationId = _readString(
      from: sources,
      keys: ["conversationId", "conversationID", "conversation_id", "convId", "sessionId"]
    ), !conversationId.isEmpty {
      for prefix in ["c2c_", "group_"] where conversationId.hasPrefix(prefix) {
        ids.insert(String(conversationId.dropFirst(prefix.count)))
      }
    }
    return ids
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

  /// 系统自带电话铃声（「倒影」/Reflection）候选路径。
  /// 后台/锁屏来电由 CallKit 播系统默认铃声，App 在前台时没有 CallKit 界面，
  /// 只能自己播 —— 优先用同一个系统铃声文件，读不到再回落到包内 call_ringtone.caf。
  private static let systemRingtonePaths = [
    "/System/Library/Audio/UISounds/Ringtones/Reflection.caf",
    "/System/Library/Audio/UISounds/Ringtones/Reflection.m4r",
    "/System/Library/Audio/UISounds/ringtones/Reflection.caf",
    "/System/Library/Ringtones/Reflection.m4r",
    "/Library/Ringtones/Reflection.m4r",
  ]

  /// 前台来电振铃音频：系统电话铃声优先，沙盒读不到时回落包内资源。
  private func _ringtoneURL() -> URL? {
    for path in AppDelegate.systemRingtonePaths
    where FileManager.default.isReadableFile(atPath: path) {
      imLog("[Ringtone] 使用系统电话铃声: \(path)")
      return URL(fileURLWithPath: path)
    }
    imLog("[Ringtone] 未读到系统铃声文件，回落到包内 call_ringtone.caf")
    return Bundle.main.url(forResource: "call_ringtone", withExtension: "caf")
  }

  /// 播放/停止被叫振铃音（来电铃声资源 call_ringtone.caf）
  private func _playRingtone(_ play: Bool) {
    if play {
      if ringtonePlayer?.isPlaying == true {
        return
      }
      guard let url = _ringtoneURL() else {
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
    // 来电铃声交给系统：ringtoneSound 留空 = CallKit 播系统默认电话铃声（「倒影」）。
    // 之前指定包内 call_ringtone.caf（自制的嘟嘟声），来电听感与系统电话不一致。
    // 注意：普通推送 payload 里 sound 仍是 "push_notification.caf"，包内不再提供
    // 这个文件后普通推送会走系统默认提示音（iOS 找不到指定声音文件时播放默认声）。
    config.ringtoneSound = nil
    let provider = CXProvider(configuration: config)
    provider.setDelegate(self, queue: nil)
    callProvider = provider
    imLog("[CallKit] CXProvider 已初始化")
  }

  /// PushKit VoIP 注册：拿到 VoIP deviceToken（上报 Flutter→后端）
  private func _setupVoipPush() {
    let registry = PKPushRegistry(queue: .main)
    registry.delegate = self
    registry.desiredPushTypes = [.voIP]
    voipRegistry = registry
    let backgroundModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") ?? "nil"
    imLog("[CallKit] PushKit VoIP 已注册, UIBackgroundModes=\(backgroundModes)")
    _scheduleVoipTokenCheck(attempt: 1)
  }

  /// PushKit 注册失败不会回调任何错误，只会静默无 token；
  /// 这里按间隔复查 + 重新触发注册，并在放弃时打印排查清单。
  private func _scheduleVoipTokenCheck(attempt: Int) {
    guard attempt <= 6 else {
      imLog("[CallKit] ❌ 多次重试仍未拿到 VoIP Token，请依次检查："
        + "1) Info.plist UIBackgroundModes 含 voip；"
        + "2) 描述文件含 Push Notifications（aps-environment）；"
        + "3) 真机可访问 APNs（非模拟器、网络未拦截 5223/443）；"
        + "4) 卸载重装 App 后重新注册")
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 1 ? 3 : 8)) { [weak self] in
      guard let self, let registry = self.voipRegistry else { return }
      if let token = registry.pushToken(for: .voIP) {
        imLog("[CallKit] 第 \(attempt) 次复查命中本地缓存的 VoIP Token")
        self._handleVoipToken(token)
        return
      }
      imLog("[CallKit] ⚠️ 第 \(attempt) 次复查仍无 VoIP Token，重新触发 PushKit 注册")
      registry.desiredPushTypes = []
      registry.desiredPushTypes = [.voIP]
      self._scheduleVoipTokenCheck(attempt: attempt + 1)
    }
  }

  /// VoIP token 去重上报（PushKit 对同一 token 会多次回调）
  private func _handleVoipToken(_ token: Data) {
    let hex = AppDelegate._hexToken(token)
    guard hex != lastVoipTokenHex else {
      imLog("[CallKit] VoIP Token 未变化，跳过重复上报")
      return
    }
    lastVoipTokenHex = hex
    imLog("[CallKit] VoIP Token(\(hex.count)字符): \(hex)")
    _sendToFlutter(["event": "voipToken", "token": hex])
    _registerVoipTokenToJPush(token)
  }

  /// 把 PushKit 的 VoIP token 上报极光服务器。
  /// 极光只有拿到这台设备的 VoIP token，才会用 notification.voip 下发 VoIP 推送；
  /// 没上报时 REST 接口照样返回 200，但投递报告里 ios_apns_sent=0（推不出去）。
  private func _registerVoipTokenToJPush(_ token: Data) {
    let hex = AppDelegate._hexToken(token)
    guard hex != lastVoipTokenSentToJPush else {
      return
    }
    lastVoipTokenSentToJPush = hex
    JPUSHService.registerVoipToken(token)
    imLog("[CallKit] VoIP Token 已上报极光服务器(registerVoipToken), 长度=\(token.count)")
    // 极光 SDK 的 setup 由 Dart 侧在启动后调用；若本次上报早于 setup 可能被忽略，补一次
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
      guard let self, self.lastVoipTokenSentToJPush == hex else { return }
      JPUSHService.registerVoipToken(token)
      imLog("[CallKit] VoIP Token 已二次上报极光服务器(兜底)")
    }
  }

  private static func _hexToken(_ token: Data) -> String {
    token.map { String(format: "%02.2hhx", $0) }.joined()
  }

  /// 原生 → Flutter 事件（engine 未就绪时缓存，ready 后 flush）
  private func _sendToFlutter(_ event: [String: Any]) {
    if dartCallkitHandlerReady, let channel = callkitChannel {
      DispatchQueue.main.async {
        channel.invokeMethod("onCallkitEvent", arguments: event)
      }
    } else {
      pendingCallkitEvents.append(event)
      pendingCallkitEventsSince = Date()
      imLog("[CallKit] Dart handler 未就绪，缓存事件: \(event["event"] ?? "")")
    }
  }

  /// 从推送 payload 解析来电信令。
  ///
  /// 之前的实现只看「顶层 / aps / extras / payload」这四个固定层级，且字段名大小写
  /// 敏感。实际上各推送通道（VoIP 推送、极光通知）的字段层级差异很大：可能嵌在
  /// extras.params、message.content 的 JSON 字符串里，或用 roomid/roomNo 等别名。
  /// 解析不到 roomId 的后果是静默的——点「接听」跳进 App 却没有通话页，所以这里
  /// 改成整棵 payload 深度遍历 + 键名大小写归一 + JSON 字符串展开。
  private func _parseCallPayload(_ userInfo: [AnyHashable: Any]) -> [String: Any] {
    let flat = _flattenPayloadKeys(userInfo)

    func pick(_ keys: [String]) -> String? {
      for key in keys {
        guard let value = flat[key] else { continue }
        if let text = value as? String {
          let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
          if !trimmed.isEmpty { return trimmed }
          continue
        }
        if let number = value as? NSNumber { return number.stringValue }
      }
      return nil
    }

    var data: [String: Any] = [:]
    if let v = pick(["roomid", "room", "roomno", "roomcode", "callroom",
                     "callroomid", "roomname", "livekitroom"]) {
      data["roomId"] = v
    }
    if let v = pick(["messagetype", "msgtype", "businesstype", "business_type"]) {
      data["messageType"] = v
    }
    // 注意：这里刻意不收 "userid" 这类泛化键——推送里它常常是「被推送人自己」的
    // id，误当发起人会触发 App 侧的「自己发起的回声」判断，来电被静默丢弃。
    if let v = pick(["inviteruserid", "inviter_user_id", "from_account", "fromaccount",
                     "fromuserid", "from_user_id", "callerid", "caller_id",
                     "senderid", "sender_id"]) {
      data["inviterUserId"] = v
    }
    if let v = pick(["inviternickname", "inviter_nickname", "nickname", "sendername",
                     "sender_name", "callername", "invitername", "fromname"]) {
      data["inviterNickname"] = v
    }
    if let v = pick(["inviteravatar", "inviter_avatar", "avatar", "senderavatar",
                     "headimage", "headimg"]) {
      data["inviterAvatar"] = v
    }
    if let v = pick(["mediatype", "media_type", "calltype", "call_type"]) {
      data["mediaType"] = v
    }
    if let v = pick(["conversationtype", "conversation_type", "chattype", "chat_type"]) {
      data["conversationType"] = v
    }
    if let v = pick(["groupid", "group_id", "togroupid"]) {
      data["groupId"] = v
    }
    if let v = pick(["livekiturl", "livekit_url", "serverurl"]) {
      data["livekitUrl"] = v
    }
    // inviteeIds 可能是数组或 JSON 字符串：原样交给 Dart 侧解析
    if let v = flat["inviteeids"] ?? flat["inviteeid"] {
      data["inviteeIds"] = v
    }
    return data
  }

  /// 深度遍历 payload，把所有层级的键名小写后铺平（先出现的外层优先）。
  /// 字典、数组、以及「长得像 JSON 的字符串」（message.content / extras 常常是
  /// 序列化后的 JSON）都会被展开。预算上限防止异常 payload 拖垮主线程。
  private func _flattenPayloadKeys(_ value: Any?) -> [String: Any] {
    var flat: [String: Any] = [:]
    var work: [(Any, Int)] = [(value as Any, 0)]
    var cursor = 0
    var visited = 0
    while cursor < work.count, visited < 400 {
      let (node, depth) = work[cursor]
      cursor += 1
      visited += 1
      guard depth < 5 else { continue }
      if let dict = node as? [AnyHashable: Any] {
        for (key, val) in dict {
          let name = String(describing: key).lowercased()
          if flat[name] == nil { flat[name] = val }
          work.append((val, depth + 1))
        }
      } else if let list = node as? [Any] {
        for item in list { work.append((item, depth + 1)) }
      } else if let text = node as? String {
        let inner = _asMap(text)
        if !inner.isEmpty {
          for (key, val) in inner {
            let name = key.lowercased()
            if flat[name] == nil { flat[name] = val }
            work.append((val, depth + 1))
          }
        }
      }
    }
    return flat
  }
}

// MARK: - PKPushRegistryDelegate（VoIP 推送到达 → CallKit 上报来电）
extension AppDelegate: PKPushRegistryDelegate {
  func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
    imLog("[CallKit] didUpdate pushCredentials, type=\(type.rawValue)")
    _handleVoipToken(pushCredentials.token)
  }

  /// 诊断：VoIP token 失效回调（注册被系统拒绝时触发）
  func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
    imLog("[CallKit] ❌ VoIP Token 失效（注册被系统拒绝）: type=\(type.rawValue)")
  }

  func pushRegistry(
    _ registry: PKPushRegistry,
    didReceiveIncomingPushWith payload: PKPushPayload,
    for type: PKPushType,
    completion: @escaping () -> Void
  ) {
    // 注意：payload 必须是 PKPushPayload（协议要求），写成 [AnyHashable: Any]
    // 时不满足协议要求 → 该方法不会暴露给 ObjC 运行时，PushKit 永远回调不到，
    // 系统还会因为没上报 CallKit 而杀掉 App/停发 VoIP 推送。
    let userInfo = payload.dictionaryPayload
    imLog("[CallKit] 收到 VoIP 推送: \(userInfo)")
    // 回执给极光（送达统计/日志），失败不影响下面的 CallKit 上报
    JPUSHService.handleVoipNotification(userInfo)
    // 未登录（已退出登录）不接收 VoIP 推送：与普通推送保持一致——退出登录后
    // 原生消息处理开关（isPushEnabled）为 false，通知与点击都直接忽略；来电同理，
    // 否则锁屏会弹出一个「点接听也没法通话」的系统来电界面。
    // 后端侧的根治手段：Dart 在退出登录时会调 updateVoipToken 清掉本机 Token
    // （见 RtcController.unbindVoipToken），之后后端不再往这台设备发 VoIP 推送，
    // 能走到这里的只有登出瞬间已在途的那一条。
    // 取舍：苹果要求收到 VoIP 推送后必须 reportNewIncomingCall，这里在未登录场景
    // 选择直接忽略——未登录时用户无法通话，报告一个假来电体验更差。
    guard isPushEnabled else {
      imLog("[CallKit] 当前账号未登录/已退出，忽略 VoIP 推送（不弹系统来电界面）")
      currentCallUuid = nil
      currentCallPayload = [:]
      _clearPersistedCallPayload()
      completion()
      return
    }
    var data = _parseCallPayload(userInfo)
    guard let roomId = data["roomId"] as? String, !roomId.isEmpty else {
      // 非来电 VoIP 推送：直接放行（苹果要求 report，但极光仅来电场景发 VoIP）
      imLog("[CallKit] VoIP 推送缺少 roomId，忽略")
      completion()
      return
    }
    // 标记这通来电是否由 CallKit 承载系统来电界面（后台/锁屏场景）：
    // 那种场景下铃声由系统播，App 内再播一遍会占着 .playback 音频会话，
    // 与接听后的通话会话冲突（接听后 App 不进前台 / 没有声音）。
    data["_callkitSystemUI"] = UIApplication.shared.applicationState != .active
    // 持久化来电信息：用户可能在 App 被系统回收之后才点「接听」，
    // 那时进程内的 payload 已经没了，只能靠这份存档还原 roomId 进通话页
    UserDefaults.standard.set(data, forKey: pendingCallPayloadKey)
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: pendingCallAtKey)
    UserDefaults.standard.set(false, forKey: pendingCallAnsweredKey)
    currentCallPayload = data
    // App 已在前台（后端同时推了 WS 信令，App 内已经/即将弹通话页）：
    // 再上报 CallKit 会让屏幕顶部同时出现「系统接听框 + App 通话页」两套来电 UI。
    // 前台场景只转发事件给 Flutter，由 App 内通话页承载。
    if UIApplication.shared.applicationState == .active {
      imLog("[CallKit] App 在前台，跳过系统来电界面，只弹 App 内通话页 roomId=\(roomId)")
      currentCallUuid = nil
      _sendToFlutter(["event": "incoming", "payload": data])
      completion()
      return
    }
    currentCallUuid = UUID()
    let uuid = currentCallUuid!
    let update = CXCallUpdate()
    let nickname = (data["inviterNickname"] as? String) ?? "IM"
    update.remoteHandle = CXHandle(type: .generic, value: nickname)
    update.localizedCallerName = nickname
    let mediaType = Int(data["mediaType"] as? String ?? "") ?? 1
    update.hasVideo = mediaType == 2
    callProvider?.reportNewIncomingCall(with: uuid, update: update) { error in
      if let error = error {
        imLog("[CallKit] 上报来电失败: \(error.localizedDescription)")
      } else {
        imLog("[CallKit] 系统来电界面已弹出: \(nickname) roomId=\(roomId)")
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
    imLog("[CallKit] 用户点击接听, appState=\(UIApplication.shared.applicationState.rawValue)"
      + "(0=active,1=inactive,2=background)")
    // 1) 先停掉 App 自己的振铃/回铃音：它们用 .playback 音频会话并 setActive(true)，
    //    和下面的通话音频会话是互斥的。App 自己把会话占着，系统激活通话会话会失败，
    //    通话进不了 active，表现就是「滑动接听后没进 App / 通话页不弹 / 对方一直通话中」。
    _playRingtone(false)
    _playRingback(false)
    // 2) 在接听回调里配置并激活通话音频会话（Apple 对 CXAnswerCallAction 的要求）。
    //    通话音频会话 active 是系统把 App 切到前台、并允许后台收音放音的前提。
    _activateCallAudioSession(reason: "answer")
    // 冷启动场景：进程内的 payload 已随上个进程销毁，从存档还原
    if currentCallPayload.isEmpty,
       let saved = UserDefaults.standard.dictionary(forKey: pendingCallPayloadKey) {
      currentCallPayload = saved
      imLog("[CallKit] 接听时还原来电信息: roomId=\(saved["roomId"] ?? "")")
    }
    _sendToFlutter(["event": "answer", "payload": currentCallPayload])
    // 记录「已接听」：App 被杀 / 事件桥丢失时，Dart 启动后读这份存档直接接听。
    // 没有 payload 只有标记时（进程重启后 currentCallPayload 为空）至少让来电页能弹出来。
    if !currentCallPayload.isEmpty {
      UserDefaults.standard.set(currentCallPayload, forKey: pendingCallPayloadKey)
    }
    if UserDefaults.standard.object(forKey: pendingCallAtKey) == nil {
      UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: pendingCallAtKey)
    }
    UserDefaults.standard.set(true, forKey: pendingCallAnsweredKey)
    action.fulfill()
    // 通话保持 active 直到通话真的结束（见 currentCallUuid 上的说明）。
    // 真机日志（10-22 17:28）证明：锁屏接听后系统并不会因为通话 active 就把 App
    // 切到前台，收起通话界面也换不来前台；所以这里既不主动收起，也不设超时收起——
    // 留着通话界面，用户解锁后能从锁屏的「通话中」界面点进 App。
    currentCallUuid = action.callUUID
    // 3) 尝试把 App 拉回前台（两套手段都试，成败都记日志）。
    //    锁屏状态（isProtectedDataAvailable=false）下系统不会把 App 显示出来，
    //    只能等用户解锁；解锁时系统会自动把 App 切到前台，日志里能看到
    //    applicationWillEnterForeground / applicationDidBecomeActive。
    imLog("[CallKit] 接听时设备锁屏=\(!UIApplication.shared.isProtectedDataAvailable)"
      + "（true 表示锁屏，系统不会显示 App，需用户解锁）")
    _requestForegroundIfNeeded(reason: "answer")
    _openSelfIfPossible(reason: "answer")
  }

  /// 用户点「拒接」/「挂断」：通知 Flutter 拒绝
  func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
    imLog("[CallKit] 用户点击拒接/挂断")
    _sendToFlutter(["event": "reject", "payload": currentCallPayload])
    action.fulfill()
    currentCallUuid = nil
    currentCallPayload = [:]
    _clearPersistedCallPayload()
  }

  private func _clearPersistedCallPayload() {
    UserDefaults.standard.removeObject(forKey: pendingCallPayloadKey)
    UserDefaults.standard.removeObject(forKey: pendingCallAtKey)
    UserDefaults.standard.removeObject(forKey: pendingCallAnsweredKey)
  }

  /// 激活通话音频会话（CallKit 接听回调里必须做的一步）。
  /// 用 .playAndRecord + .voiceChat：既能收音也能放音，路由跟随系统（听筒/扬声器/
  /// 蓝牙）。LiveKit 进房后会用同样的 category 再配置一次，不冲突。
  private func _activateCallAudioSession(reason: String) {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .defaultToSpeaker]
      )
      imLog("[CallKit] 通话音频会话 category 已设置(reason=\(reason)): "
        + "category=\(session.category.rawValue), mode=\(session.mode.rawValue)")
    } catch {
      imLog("[CallKit] ❌ 通话音频会话 category 设置失败(reason=\(reason)): "
        + "\(error.localizedDescription)")
    }
    // 激活：CallKit 通话的音频会话由系统接管（激活成功会回调 didActivate）。
    // App 侧在后台/锁屏时这一步会被系统拒绝（日志里的 Session activation failed），
    // 属于预期——系统随后会自己激活并回调 didActivate，所以这里只记录不报错。
    do {
      try session.setActive(true)
      imLog("[CallKit] 通话音频会话 setActive(true) 成功(reason=\(reason))")
    } catch {
      imLog("[CallKit] 通话音频会话 setActive(true) 被拒(reason=\(reason)): "
        + "\(error.localizedDescription)（等待系统 didActivate）")
    }
  }

  /// 释放通话音频会话（通话结束/被拒接时）。
  private func _deactivateCallAudioSession(reason: String) {
    do {
      try AVAudioSession.sharedInstance().setActive(
        false,
        options: .notifyOthersOnDeactivation
      )
      imLog("[CallKit] 通话音频会话已释放(reason=\(reason))")
    } catch {
      // 通话音频会话由系统（CallKit）接管时，App 侧的 setActive(false) 会被拒，
      // 随后系统会回调 didDeactivate 把会话收掉，属于预期，不当成错误。
      imLog("[CallKit] 通话音频会话 setActive(false) 被拒(reason=\(reason)): "
        + "\(error.localizedDescription)（等待系统 didDeactivate）")
    }
  }

  /// 主动请求系统把 App 切到前台。
  ///
  /// 锁屏/后台接听时，系统「应该」把 App 拉到前台，但实测（iOS 26.3 真机）
  /// 有时不会——App 一直在后台跑，通话页虽然 push 出来了但用户看不到。
  /// 这里对已有的窗口场景发一次激活请求，让系统把 App 拉到前台；
  /// 请求失败（例如设备仍锁屏）不影响通话本身，日志里会留痕便于排查。
  private func _requestForegroundIfNeeded(reason: String) {
    let app = UIApplication.shared
    let state = app.applicationState.rawValue
    imLog("[CallKit] 请求 App 到前台(reason=\(reason)), appState=\(state)"
      + "(0=active,1=inactive,2=background), scenes=\(app.connectedScenes.count)")
    guard app.applicationState != .active else { return }
    let scene = app.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first { $0.activationState != .unattached }
    guard let scene = scene else {
      imLog("[CallKit] 没有可激活的窗口场景，无法请求前台")
      return
    }
    app.requestSceneSessionActivation(
      scene.session,
      userActivity: nil,
      options: nil
    ) { error in
      imLog("[CallKit] ❌ requestSceneSessionActivation 失败(reason=\(reason)): "
        + "\(error.localizedDescription)")
    }
  }

  /// 用自身 URL scheme 打开一次 App（"liaoba://call"）。
  ///
  /// 真机验证：requestSceneSessionActivation 在单场景 App 上直接被系统拒绝
  /// （「当前设备不支持多个场景」），所以再试一条路——open 自己的 scheme。
  /// 设备解锁状态下系统会因此把 App 拉到前台；锁屏状态下会被拒（拿不到前台，
  /// 属于 iOS 的锁屏限制），日志里会写明结果，便于判断该走哪条路。
  private func _openSelfIfPossible(reason: String) {
    guard let url = URL(string: "liaoba://call") else { return }
    imLog("[CallKit] 尝试用自身 scheme 拉起 App(reason=\(reason)): \(url.absoluteString)")
    UIApplication.shared.open(url, options: [:]) { ok in
      imLog("[CallKit] open(自身 scheme) 结果(reason=\(reason)): ok=\(ok)")
    }
  }

  func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
    // 通话音频会话已 active：这是系统「通话真的接通了」的信号，也是把 App
    // 切到前台的时机（锁屏接听时系统有时不主动拉起，这里再请求一次）。
    imLog("[CallKit] 通话音频会话已激活(系统回调 didActivate)，"
      + "appState=\(UIApplication.shared.applicationState.rawValue)"
      + "(0=active,1=inactive,2=background)，锁屏=\(!UIApplication.shared.isProtectedDataAvailable)")
    _requestForegroundIfNeeded(reason: "didActivate")
    _openSelfIfPossible(reason: "didActivate")
  }

  func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
    imLog("[CallKit] 通话音频会话已释放(系统回调 didDeactivate)")
  }

  func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
    action.fulfill()
  }

  func providerDidReset(_ provider: CXProvider) {
    currentCallUuid = nil
    currentCallPayload = [:]
  }
}

// MARK: - 日志

/// 统一日志：同时写 stdout 和系统统一日志（NSLog）。
/// Swift 的 print 只走 stdout —— 用 Xcode 的 Devices 控制台 / Console.app
/// 看真机日志时看不到它，只有 NSLog / os_log 才进系统日志，所以排查日志统一走这里。
private func imLog(_ message: String) {
  print(message)
  NSLog("%@", message)
  appendDiagLogLine(message)
}

// MARK: - 诊断日志文件

/// 诊断日志文件名（App 沙盒 Documents 下，Info.plist 已开 UIFileSharingEnabled，
/// 可从「文件」App / Finder 取出）。锁屏接听、杀进程后接听这类场景很难实时抓
/// 真机控制台，日志落盘后可以事后排查。
private let diagLogFileName = "im_diag.log"
/// 单文件体积上限：超过后只保留后半段，避免无限增长。
private let diagLogMaxBytes = 256 * 1024

/// 诊断日志内容缓存（避免每次追加重读整个文件）。
private var diagLogBuffer: String?

private let diagLogTimeFormatter: DateFormatter = {
  let formatter = DateFormatter()
  formatter.dateFormat = "MM-dd HH:mm:ss.SSS"
  return formatter
}()

private func diagLogURL() -> URL? {
  FileManager.default
    .urls(for: .documentDirectory, in: .userDomainMask)
    .first?
    .appendingPathComponent(diagLogFileName)
}

/// 追加一行诊断日志（原生 imLog 与 Dart 侧 appendDiagLog 共用）。
private func appendDiagLogLine(_ line: String) {
  guard let url = diagLogURL() else { return }
  // 注意：deployment target 是 iOS 13.0，FileHandle 的 seekToEnd/write(contentsOf:)
  // 需要 13.4+，这里用「内存缓存 + 整体重写」的写法，全版本可用。
  if diagLogBuffer == nil {
    diagLogBuffer = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
  }
  var text = diagLogBuffer ?? ""
  text += "[\(diagLogTimeFormatter.string(from: Date()))] \(line)\n"
  if text.utf8.count > diagLogMaxBytes {
    // 超限：丢前半段（尽量落在整行边界上）
    var kept = String(text.suffix(diagLogMaxBytes / 2))
    if let newline = kept.firstIndex(of: "\n") {
      kept = String(kept[kept.index(after: newline)...])
    }
    text = kept
  }
  diagLogBuffer = text
  try? text.write(to: url, atomically: true, encoding: .utf8)
}
