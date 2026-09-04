import 'package:flutter/material.dart';

import 'app_colors.dart';

/// 语义色集合（随亮/暗主题切换），挂在 ThemeData.extensions 上。
class ThemeColors extends ThemeExtension<ThemeColors> {
  final Color bg; // 页面背景
  final Color card; // 卡片（列表项容器）
  final Color surface; // 顶部头部 + 底部导航栏
  final Color surfaceText; // surface 上的文字 / 图标色
  final Color sectionBg; // section 标题条
  final Color divider; // 分割线 / 关闭态开关轨道
  final Color text; // 主文字
  final Color muted; // 次要文字 / 图标

  const ThemeColors({
    required this.bg,
    required this.card,
    required this.surface,
    required this.surfaceText,
    required this.sectionBg,
    required this.divider,
    required this.text,
    required this.muted,
  });

  @override
  ThemeColors copyWith({
    Color? bg,
    Color? card,
    Color? surface,
    Color? surfaceText,
    Color? sectionBg,
    Color? divider,
    Color? text,
    Color? muted,
  }) =>
      ThemeColors(
        bg: bg ?? this.bg,
        card: card ?? this.card,
        surface: surface ?? this.surface,
        surfaceText: surfaceText ?? this.surfaceText,
        sectionBg: sectionBg ?? this.sectionBg,
        divider: divider ?? this.divider,
        text: text ?? this.text,
        muted: muted ?? this.muted,
      );

  @override
  ThemeColors lerp(ThemeColors? other, double t) => other == null
      ? this
      : ThemeColors(
          bg: Color.lerp(bg, other.bg, t)!,
          card: Color.lerp(card, other.card, t)!,
          surface: Color.lerp(surface, other.surface, t)!,
          surfaceText: Color.lerp(surfaceText, other.surfaceText, t)!,
          sectionBg: Color.lerp(sectionBg, other.sectionBg, t)!,
          divider: Color.lerp(divider, other.divider, t)!,
          text: Color.lerp(text, other.text, t)!,
          muted: Color.lerp(muted, other.muted, t)!,
        );
}

/// 快捷取语义色。
extension ThemeColorsX on BuildContext {
  ThemeColors get colors => Theme.of(this).extension<ThemeColors>()!;
}

/// 应用主题（亮 / 暗）。
class AppTheme {
  AppTheme._();

  static const _lime = AppColors.lime;

  static ThemeData get lightTheme => _base(
        brightness: Brightness.light,
        colors: const ThemeColors(
          bg: Color(0xFFF8F8F8),
          card: Colors.white,
          surface: AppColors.lime,
          surfaceText: Color(0xFF1A1A1A), // lime 头配黑字
          sectionBg: Color(0xFFF0F0F0),
          divider: Color(0xFFE9E9E9),
          text: Color(0xFF1A1A1A),
          muted: Color(0xFF9A9A9A),
        ),
      );

  static ThemeData get darkTheme => _base(
        brightness: Brightness.dark,
        colors: const ThemeColors(
          bg: Color(0xFF141414),
          card: Color(0xFF1F1F23),
          surface: Color(0xFF2D2D30),
          surfaceText: Colors.white,
          sectionBg: Color(0xFF2C2C2E),
          divider: Color(0xFF3A3A3C),
          text: Colors.white,
          muted: Color(0xFF9E9E9E),
        ),
      );

  static ThemeData _base({
    required Brightness brightness,
    required ThemeColors colors,
  }) =>
      ThemeData(
        useMaterial3: true,
        brightness: brightness,
        scaffoldBackgroundColor: colors.bg,
        fontFamily: 'PingFang SC',
        colorScheme: (brightness == Brightness.light
                ? ColorScheme.light()
                : ColorScheme.dark())
            .copyWith(
              primary: _lime,
              secondary: _lime,
              surface: colors.card,
              onSurface: colors.text,
            ),
        extensions: [colors],
      );
}
