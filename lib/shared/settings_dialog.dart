import 'package:flutter/material.dart';

/// 桌面端设置类页面居中弹框（微信/Telegram PC 风格）：
/// - 弹框内嵌套独立 Navigator，页面内部所有 push/pop 都发生在弹框内，
///   子页面（账户安全/改密码/意见反馈/关于等）在弹框内切换，不覆盖整个 App；
/// - 弹框内栈只剩首页时再「返回」→ 自动关闭整个弹框；
/// - 页面内部 showDialog 默认走根 Navigator，确认框仍居中覆盖全屏。
Future<void> showSettingsDialog(
  BuildContext context, {
  required Widget page,
  double width = 440,
  double maxHeight = 620,
}) {
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) => Dialog(
      backgroundColor: Colors.transparent,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: width, maxHeight: maxHeight),
          child: Navigator(
            initialRoute: '/',
            observers: [
              _AutoCloseObserver(() {
                // 弹框内最后一页被 pop：关闭弹框本身
                final root = Navigator.of(dialogCtx);
                if (root.canPop()) root.pop();
              }),
            ],
            // 首页路由；后续页面由页面内部 MaterialPageRoute.push 直传，不经过这里
            onGenerateRoute: (settings) => MaterialPageRoute(
              settings: settings,
              builder: (_) => page,
            ),
          ),
        ),
      ),
    ),
  );
}

/// 弹框内导航观察者：栈被 pop 到空（最后一页返回）时回调关闭弹框。
class _AutoCloseObserver extends NavigatorObserver {
  _AutoCloseObserver(this.onEmpty);

  final VoidCallback onEmpty;

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute == null) onEmpty();
  }
}
