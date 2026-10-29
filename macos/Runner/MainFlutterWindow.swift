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

    super.awakeFromNib()
  }
}
