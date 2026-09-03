import 'package:flutter/material.dart';
import '../../../shared/app_colors.dart';
import '../../../shared/app_theme.dart';
import 'security/account_security_page.dart';
import 'feedback_page.dart';
import 'about_page.dart';

class GeneralSettingsPage extends StatelessWidget {
  const GeneralSettingsPage({super.key});

  Future<void> _showLogoutConfirm(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _LogoutConfirmDialog(),
    );
    if (confirmed == true) {
      // TODO: 调用退出登录接口，清除登录态，跳转到登录页
      if (context.mounted) {
        Navigator.of(context).pop(); // 关闭当前设置页
        // Navigator.of(context).pushReplacement(...)
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: context.colors.bg,
        body: Column(
          children: [
            // 顶部导航栏
            Container(
              color: context.colors.surface,
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
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(Icons.chevron_left,
                              size: 34, color: context.colors.surfaceText),
                        ),
                      ),
                      Text(
                        '通用设置',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w500,
                            color: context.colors.surfaceText),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 可滚动列表
            Expanded(
              child: ListView(
                padding: EdgeInsets.zero,
                children: [
                  _SettingGroup(
                    children: [
                      _SettingRow(
                        title: '账户安全',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const AccountSecurityPage(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const _SectionLabel('其他设置'),
                  _SettingGroup(
                    children: [
                      _SettingRow(
                        title: '意见反馈',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const FeedbackPage()),
                        ),
                      ),
                      _SettingRow(
                        title: '关于我们',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const AboutPage()),
                        ),
                      ),
                      const _SettingRow(title: '清理缓存'),
                      const _SettingRow(
                          title: '网络错误线路优化', trailing: '线路 1'),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(28, 10, 28, 0),
                    child: Text(
                      '网络链接正常时出现报错可尝试点击此按钮优化线路',
                      style:
                          TextStyle(fontSize: 14, color: context.colors.muted),
                    ),
                  ),
                ],
              ),
            ),

            // 固定在底部的退出登录按钮
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 16, 26, 0),
                child: SizedBox(
                  width: double.infinity,
                  height: 50,
                  child: FilledButton(
                    onPressed: () => _showLogoutConfirm(context),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.colors.card,
                      foregroundColor: const Color(0xFFFF3B5C),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    child: const Text(
                      '退出登录',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

/// 退出登录确认弹框。
class _LogoutConfirmDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Dialog(
        backgroundColor: context.colors.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '提示',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.colors.text,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '是否退出登录',
                style: TextStyle(fontSize: 16, color: context.colors.muted),
              ),
              const SizedBox(height: 32),
              Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: context.colors.bg,
                          foregroundColor: context.colors.text,
                          elevation: 0,
                          side: BorderSide(color: context.colors.divider),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: context.colors.text,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: SizedBox(
                      height: 46,
                      child: ElevatedButton(
                        onPressed: () => Navigator.of(context).pop(true),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: const Text(
                          '确定',
                          style: TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
}

class _SettingGroup extends StatelessWidget {
  final List<Widget> children;
  const _SettingGroup({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        color: context.colors.card,
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
          style: TextStyle(fontSize: 19, color: context.colors.muted),
        ),
      );
}

class _SettingRow extends StatelessWidget {
  final String title;
  final String? trailing;
  final VoidCallback? onTap;
  const _SettingRow({required this.title, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 60,
        padding: const EdgeInsets.symmetric(horizontal: 20),
        decoration: BoxDecoration(
          border: Border(bottom: BorderSide(color: colors.divider)),
        ),
        child: Row(
          children: [
            Expanded(
                child: Text(title,
                    style: TextStyle(fontSize: 21, color: colors.text))),
            if (trailing != null)
              Text(
                trailing!,
                style: TextStyle(fontSize: 17, color: colors.muted),
              ),
            const SizedBox(width: 10),
            Icon(Icons.chevron_right, size: 28, color: colors.muted),
          ],
        ),
      ),
    );
  }
}
