import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局主题模式管理器。
///
/// 跟随系统 / 普通模式 / 深色模式，选择结果持久化，
/// 通过 [modeNotifier] 通知 MaterialApp 切换 themeMode。
class ThemeManager {
  ThemeManager._();

  static final ThemeManager instance = ThemeManager._();

  static const String _spKey = 'theme_mode';

  /// 默认普通模式。
  final ValueNotifier<ThemeMode> modeNotifier =
      ValueNotifier<ThemeMode>(ThemeMode.light);

  ThemeMode get mode => modeNotifier.value;

  /// App 启动时恢复上次选择的主题模式。
  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final name = sp.getString(_spKey);
      if (name != null) {
        modeNotifier.value =
            ThemeMode.values.firstWhere((m) => m.name == name);
      }
    } catch (_) {
      // 持久化不可用时保持默认普通模式
    }
  }

  /// 设置主题模式并持久化。
  Future<void> setMode(ThemeMode mode) async {
    modeNotifier.value = mode;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setString(_spKey, mode.name);
    } catch (_) {
      // 忽略持久化失败，内存中仍生效
    }
  }
}
