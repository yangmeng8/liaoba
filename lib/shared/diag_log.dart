import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 真机诊断日志：既写 stdout（Xcode → Devices 控制台可见），
/// 又转发给原生落到 App 沙盒 Documents/im_diag.log。
///
/// 锁屏接听、杀进程后接听这类场景很难实时盯住控制台，日志落盘后可以事后
/// 从「文件」App / Finder（Info.plist 已开 UIFileSharingEnabled）取出排查。
class DiagLog {
  DiagLog._();

  static const MethodChannel _channel = MethodChannel('im/callkit');

  static void log(String message) {
    debugPrint(message);
    if (!Platform.isIOS) return;
    try {
      unawaited(
        _channel
            .invokeMethod<void>('appendDiagLog', <String, dynamic>{
              'line': message,
            })
            .catchError((Object _) {}),
      );
    } catch (_) {
      // 原生未实现（例如刚启动 handler 还没注册）：忽略
    }
  }
}
