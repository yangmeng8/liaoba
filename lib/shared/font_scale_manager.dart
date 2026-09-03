import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 全局字体缩放管理器。
///
/// 三档：小(0.85) / 标准(1.0) / 大(1.2)。
/// 通过 [indexNotifier] 通知 MaterialApp.builder 重新注入 textScaler，
/// 选择结果用 SharedPreferences 持久化，重启后保持。
class FontScaleManager {
  FontScaleManager._();

  static final FontScaleManager instance = FontScaleManager._();

  static const String _spKey = 'font_scale_index';

  /// 档位：0 小 / 1 标准 / 2 大。默认标准(1)。
  final ValueNotifier<int> indexNotifier = ValueNotifier<int>(1);

  static const List<String> labels = ['小', '标准', '大'];
  static const List<double> scales = [0.85, 1.0, 1.2];

  int get index => indexNotifier.value;
  String get label => labels[indexNotifier.value];
  double get scale => scales[indexNotifier.value];

  /// App 启动时恢复上次选择的档位。
  Future<void> load() async {
    try {
      final sp = await SharedPreferences.getInstance();
      final i = sp.getInt(_spKey) ?? 1;
      indexNotifier.value = i.clamp(0, 2);
    } catch (_) {
      // 持久化不可用时保持默认"标准"
    }
  }

  /// 设置档位并持久化。
  Future<void> setIndex(int i) async {
    final v = i.clamp(0, 2);
    indexNotifier.value = v;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setInt(_spKey, v);
    } catch (_) {
      // 忽略持久化失败，内存中仍生效
    }
  }
}
