import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';

class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppColors.pageBg,
    body: Column(
      children: [
        Container(
          color: AppColors.lime,
          child: SafeArea(
            bottom: false,
            child: SizedBox(
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: IconButton(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.chevron_left, size: 34),
                    ),
                  ),
                  const Text(
                    '通用设置',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              _SettingGroup(children: [_SettingRow(title: '账户安全')]),
              const _SectionLabel('其他设置'),
              _SettingGroup(
                children: [
                  _SettingRow(title: '意见反馈'),
                  _SettingRow(title: '关于我们'),
                  _SettingRow(title: '清理缓存'),
                  _SettingRow(title: '网络错误线路优化', trailing: '线路 1'),
                ],
              ),
              const Padding(
                padding: EdgeInsets.fromLTRB(28, 10, 28, 0),
                child: Text(
                  '网络链接正常时出现报错可尝试点击此按钮优化线路',
                  style: TextStyle(fontSize: 14, color: AppColors.muted),
                ),
              ),
              const SizedBox(height: 260),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 0, 26, 26),
                child: SizedBox(
                  height: 64,
                  child: FilledButton(
                    onPressed: () {},
                    style: FilledButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: const Color(0xFFFF3B5C),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      '退出登录',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

class _SettingGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingGroup({required this.children});

  @override
  Widget build(BuildContext context) => Container(
    color: Colors.white,
    child: Column(children: children),
  );
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Container(
    height: 50,
    alignment: Alignment.centerLeft,
    padding: const EdgeInsets.symmetric(horizontal: 28),
    child: Text(
      text,
      style: const TextStyle(fontSize: 19, color: AppColors.muted),
    ),
  );
}

class _SettingRow extends StatelessWidget {
  final String title;
  final String? trailing;
  const _SettingRow({required this.title, this.trailing});

  @override
  Widget build(BuildContext context) => Container(
    height: 60,
    padding: const EdgeInsets.symmetric(horizontal: 20),
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Color(0xFFE9E9E9))),
    ),
    child: Row(
      children: [
        Expanded(child: Text(title, style: const TextStyle(fontSize: 21))),
        if (trailing != null)
          Text(
            trailing!,
            style: const TextStyle(fontSize: 17, color: AppColors.muted),
          ),
        const SizedBox(width: 10),
        const Icon(Icons.chevron_right, size: 28, color: Color(0xFF9EA3AA)),
      ],
    ),
  );
}
