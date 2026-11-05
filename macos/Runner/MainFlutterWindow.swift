import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// 被叫振铃音（来电页期间循环；持有引用避免被释放中断播放）
  private var ringtoneSound: NSSound?
  /// 主叫回铃音（等待对方接听期间循环）
  private var ringbackSound: NSSound?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    // 桌面版窗口：默认 1080x720，最小 480x600（窄窗口回落手机竖屏布局）
    self.setContentSize(NSSize(width: 1080, height: 720))
    self.minSize = NSSize(width: 480, height: 600)
    self.title = "IM"

    // 桌面通知辅助通道（与 Windows runner 对齐）：
    // - playSound：播放 flutter_assets 内的 assets/sounds/notify.wav
    // - startRingtone/stopRingtone：来电振铃循环播放/停止
    //   （assets/sounds/ringtone.wav，与移动端同一段铃声素材）
    // - bringToFront：点击系统通知后激活本应用并把主窗口还原置前
    let channel = FlutterMethodChannel(
      name: "im/desktop_notify",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "playSound":
        let exeURL = Bundle.main.executableURL
          ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let wavURL = exeURL
          .deletingLastPathComponent()
          .appendingPathComponent(
            "../Frameworks/App.framework/Resources/flutter_assets/assets/sounds/notify.wav")
          .standardizedFileURL
        // macOS 26 SDK：NSSound(contentsOf:) 必须显式传 byReference
        if let sound = NSSound(contentsOf: wavURL, byReference: true) {
          sound.volume = 0.9
          sound.play()
          result(nil)
        } else {
          result(FlutterError(code: "SOUND_NOT_FOUND", message: wavURL.path, details: nil))
        }
      case "startRingtone":
        let exeURL = Bundle.main.executableURL
          ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let wavURL = exeURL
          .deletingLastPathComponent()
          .appendingPathComponent(
            "../Frameworks/App.framework/Resources/flutter_assets/assets/sounds/ringtone_reflection.wav")
          .standardizedFileURL
        if let sound = NSSound(contentsOf: wavURL, byReference: true) {
          sound.volume = 0.9
          sound.loops = true
          self?.ringtoneSound = sound
          sound.play()
          result(nil)
        } else {
          result(FlutterError(code: "SOUND_NOT_FOUND", message: wavURL.path, details: nil))
        }
      case "stopRingtone":
        self?.ringtoneSound?.stop()
        self?.ringtoneSound = nil
        result(nil)
      case "startRingback":
        let exeURL = Bundle.main.executableURL
          ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let wavURL = exeURL
          .deletingLastPathComponent()
          .appendingPathComponent(
            "../Frameworks/App.framework/Resources/flutter_assets/assets/sounds/ringback.wav")
          .standardizedFileURL
        if let sound = NSSound(contentsOf: wavURL, byReference: true) {
          sound.volume = 0.9
          sound.loops = true
          self?.ringbackSound = sound
          sound.play()
          result(nil)
        } else {
          result(FlutterError(code: "SOUND_NOT_FOUND", message: wavURL.path, details: nil))
        }
      case "stopRingback":
        self?.ringbackSound?.stop()
        self?.ringbackSound = nil
        result(nil)
      case "bringToFront":
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.mainWindow ?? NSApp.windows.first { !$0.isMiniaturized }
        if let window = window {
          if window.isMiniaturized {
            window.deminiaturize(nil)
          }
          window.makeKeyAndOrderFront(nil)
        }
        result(nil)
      case "setDockBadge":
        // macOS Dock 角标：未读总数显示为 Dock 图标右上角红底白字
        let count = call.arguments as? Int ?? 0
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    super.awakeFromNib()
  }
}
