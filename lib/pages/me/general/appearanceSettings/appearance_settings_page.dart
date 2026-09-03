import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import '../../../../shared/font_scale_manager.dart';
import '../../../../shared/theme_manager.dart';
import 'chat_background_picker_page.dart';
import 'font_size_settings_page.dart';

/// 外观设置页面。
class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() =>
      _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  bool get _followSystem =>
      ThemeManager.instance.mode == ThemeMode.system;

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶部导航栏
          Container(
            color: colors.card,
            child: SafeArea(
              bottom: false,
              child: SizedBox(
                height: 64,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: IconButton(
                        tooltip: '返回',
                        onPressed: () => Navigator.of(context).pop(),
                        icon:
                            Icon(Icons.chevron_left, size: 34, color: colors.text),
                      ),
                    ),
                    Text(
                      '外观设置',
                      style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: colors.text),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 可滚动区域
          Expanded(
            child: ListView(
              padding: EdgeInsets.zero,
              children: [
                // 聊天背景、字体设置
                Container(
                  color: colors.card,
                  child: Column(
                    children: [
                      _BasicRow(
                        title: '聊天背景',
                        onTap: _onChatBackground,
                      ),
                      _BasicRow(
                        title: '字体设置',
                        trailing: FontScaleManager.instance.label,
                        onTap: _onFontSettings,
                        hasBottomBorder: false,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // 外观设置 section
                Container(
                  color: colors.card,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // section 标题条
                      Container(
                        width: double.infinity,
                        color: colors.sectionBg,
                        padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                        child: Text(
                          '外观设置',
                          style:
                              TextStyle(fontSize: 15, color: colors.muted),
                        ),
                      ),

                      // 跟随系统 - Switch
                      _SwitchRow(
                        title: '跟随系统',
                        subtitle: '开启后，将跟随系统打开或关闭深色模式',
                        value: _followSystem,
                        onChanged: (v) => _setMode(
                          v ? ThemeMode.system : ThemeMode.light,
                        ),
                      ),

                      // 跟随系统开启时，隐藏普通/深色模式两行
                      if (!_followSystem) ...[
                        // 普通模式
                        _CheckRow(
                          title: '普通模式',
                          selected:
                              ThemeManager.instance.mode == ThemeMode.light,
                          onTap: () => _setMode(ThemeMode.light),
                        ),

                        // 深色模式
                        _CheckRow(
                          title: '深色模式',
                          selected:
                              ThemeManager.instance.mode == ThemeMode.dark,
                          onTap: () => _setMode(ThemeMode.dark),
                          hasBottomBorder: false,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _setMode(ThemeMode mode) {
    setState(() {});
    ThemeManager.instance.setMode(mode);
  }

  void _onChatBackground() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ChatBackgroundPickerPage()),
    );
  }

  Future<void> _onFontSettings() async {
    // 从字体设置页返回后，刷新右侧档位显示
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const FontSizeSettingsPage()),
    );
    if (mounted) setState(() {});
  }
}

/// 基础设置行（聊天背景 / 字体设置）。
class _BasicRow extends StatelessWidget {
  final String title;
  final String? trailing;
  final VoidCallback? onTap;
  final bool hasBottomBorder;

  const _BasicRow({
    required this.title,
    this.trailing,
    this.onTap,
    this.hasBottomBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: hasBottomBorder ? colors.divider : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
                child:
                    Text(title, style: TextStyle(fontSize: 21, color: colors.text))),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(fontSize: 18, color: colors.muted),
              ),
            const SizedBox(width: 8),
            Icon(Icons.chevron_right, size: 30, color: colors.muted),
          ],
        ),
      ),
    );
  }
}

/// 带副标题 + Switch 的行（跟随系统）。
class _SwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: colors.divider)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: TextStyle(fontSize: 21, color: colors.text)),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 14, color: colors.muted),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.lime,
            activeTrackColor: AppColors.lime.withValues(alpha: 0.7),
            inactiveThumbColor: colors.card,
            inactiveTrackColor: colors.divider,
          ),
        ],
      ),
    );
  }
}

/// 带右侧对勾的行（普通模式 / 深色模式）。
class _CheckRow extends StatelessWidget {
  final String title;
  final bool selected;
  final VoidCallback? onTap;
  final bool hasBottomBorder;

  const _CheckRow({
    required this.title,
    required this.selected,
    this.onTap,
    this.hasBottomBorder = true,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: hasBottomBorder ? colors.divider : Colors.transparent,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
                child:
                    Text(title, style: TextStyle(fontSize: 21, color: colors.text))),
            if (selected)
              const Icon(Icons.check, size: 28, color: AppColors.lime),
          ],
        ),
      ),
    );
  }
}
