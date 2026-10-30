import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
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
    // - bringToFront：点击系统通知后激活本应用并把主窗口还原置前
    let channel = FlutterMethodChannel(
      name: "im/desktop_notify",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { (call: FlutterMethodCall, result: @escaping FlutterResult) in
      switch call.method {
      case "playSound":
        let exeURL = Bundle.main.executableURL
          ?? URL(fileURLWithPath: CommandLine.arguments[0])
        let wavURL = exeURL
          .deletingLastPathComponent()
          .appendingPathComponent(
            "../Frameworks/App.framework/Resources/flutter_assets/assets/sounds/notify.wav")
          .standardizedFileURL
        if let sound = NSSound(contentsOf: wavURL) {
          sound.volume = 0.9
          sound.play()
          result(nil)
        } else {
          result(FlutterError(code: "SOUND_NOT_FOUND", message: wavURL.path, details: nil))
        }
      case "bringToFront":
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.mainWindow ?? NSApp.windows.first { !$0.isMiniaturized }
        if let window = window {
          if window.isMiniaturized {
            window.deminiaturize()
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
