import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';

/// 外观模式。
enum _ThemeMode { followSystem, light, dark }

/// 外观设置页面。
class AppearanceSettingsPage extends StatefulWidget {
  const AppearanceSettingsPage({super.key});

  @override
  State<AppearanceSettingsPage> createState() =>
      _AppearanceSettingsPageState();
}

class _AppearanceSettingsPageState extends State<AppearanceSettingsPage> {
  _ThemeMode _mode = _ThemeMode.light; // 默认普通模式

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: AppColors.pageBg,
        body: Column(
          children: [
            // 顶部导航栏
            Container(
              color: AppColors.lime,
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
                          icon: const Icon(Icons.chevron_left, size: 34),
                        ),
                      ),
                      const Text(
                        '外观设置',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
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
                    color: Colors.white,
                    child: Column(
                      children: [
                        _BasicRow(
                          title: '聊天背景',
                          onTap: _onChatBackground,
                        ),
                        _BasicRow(
                          title: '字体设置',
                          trailing: '标准',
                          onTap: _onFontSettings,
                          hasBottomBorder: false,
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 12),

                  // 外观设置 section
                  Container(
                    color: Colors.white,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Padding(
                          padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
                          child: Text(
                            '外观设置',
                            style: TextStyle(
                                fontSize: 15, color: AppColors.muted),
                          ),
                        ),

                        // 跟随系统 - Switch
                        _SwitchRow(
                          title: '跟随系统',
                          subtitle: '开启后，将跟随系统打开或关闭深色模式',
                          value: _mode == _ThemeMode.followSystem,
                          onChanged: (v) => setState(
                            () => _mode =
                                v ? _ThemeMode.followSystem : _ThemeMode.light,
                          ),
                        ),

                        // 普通模式
                        _CheckRow(
                          title: '普通模式',
                          selected: _mode == _ThemeMode.light,
                          onTap: () =>
                              setState(() => _mode = _ThemeMode.light),
                        ),

                        // 深色模式
                        _CheckRow(
                          title: '深色模式',
                          selected: _mode == _ThemeMode.dark,
                          onTap: () =>
                              setState(() => _mode = _ThemeMode.dark),
                          hasBottomBorder: false,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  void _onChatBackground() {
    // TODO: 跳转聊天背景设置
  }

  void _onFontSettings() {
    // TODO: 跳转字体大小设置
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
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: hasBottomBorder ? const Color(0xFFE9E9E9) : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 21))),
              if (trailing != null)
                Text(
                  trailing!,
                  style:
                      const TextStyle(fontSize: 18, color: AppColors.muted),
                ),
              const SizedBox(width: 8),
              const Icon(Icons.chevron_right,
                  size: 30, color: Color(0xFFB6BBC2)),
            ],
          ),
        ),
      );
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
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: const BoxDecoration(
          border: Border(bottom: BorderSide(color: Color(0xFFE9E9E9))),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 21)),
                  const SizedBox(height: 4),
                  Text(
                    subtitle,
                    style:
                        const TextStyle(fontSize: 14, color: AppColors.muted),
                  ),
                ],
              ),
            ),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: AppColors.lime,
              activeTrackColor: AppColors.lime.withValues(alpha: 0.7),
              inactiveThumbColor: Colors.white,
              inactiveTrackColor: const Color(0xFFE0E0E0),
            ),
          ],
        ),
      );
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
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          height: 60,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(
                color: hasBottomBorder
                    ? const Color(0xFFE9E9E9)
                    : Colors.transparent,
              ),
            ),
          ),
          child: Row(
            children: [
              Expanded(
                  child: Text(title, style: const TextStyle(fontSize: 21))),
              if (selected)
                const Icon(Icons.check,
                    size: 28, color: AppColors.lime),
            ],
          ),
        ),
      );
}
