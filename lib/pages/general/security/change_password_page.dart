import 'package:flutter/material.dart';

import '../../../shared/app_colors.dart';
import 'reset_password_by_phone_page.dart';

/// 修改密码页面。
class ChangePasswordPage extends StatefulWidget {
  const ChangePasswordPage({super.key});

  @override
  State<ChangePasswordPage> createState() => _ChangePasswordPageState();
}

class _ChangePasswordPageState extends State<ChangePasswordPage> {
  final _oldPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _showOld = false;
  bool _showNew = false;
  bool _showConfirm = false;

  @override
  void dispose() {
    _oldPasswordController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  void _submit() {
    final oldPwd = _oldPasswordController.text.trim();
    final newPwd = _newPasswordController.text.trim();
    final confirmPwd = _confirmPasswordController.text.trim();

    if (oldPwd.isEmpty || newPwd.isEmpty || confirmPwd.isEmpty) {
      _showToast('请填写完整信息');
      return;
    }
    if (newPwd != confirmPwd) {
      _showToast('两次输入的新密码不一致');
      return;
    }
    // TODO: 调用修改密码接口
    _showToast('密码修改成功');
    Navigator.of(context).pop();
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

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
                        '修改密码',
                        style: TextStyle(
                            fontSize: 20, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 可滚动区域，键盘弹出时不会溢出
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return SingleChildScrollView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: Column(
                          children: [
                            const SizedBox(height: 16),

                            // 三个密码输入框
                            _PasswordField(
                              controller: _oldPasswordController,
                              hint: '请输入旧密码',
                              obscure: !_showOld,
                              onToggleObscure: () =>
                                  setState(() => _showOld = !_showOld),
                            ),
                            const SizedBox(height: 12),
                            _PasswordField(
                              controller: _newPasswordController,
                              hint: '请输入新密码',
                              obscure: !_showNew,
                              onToggleObscure: () =>
                                  setState(() => _showNew = !_showNew),
                            ),
                            const SizedBox(height: 12),
                            _PasswordField(
                              controller: _confirmPasswordController,
                              hint: '请再次输入新密码',
                              obscure: !_showConfirm,
                              onToggleObscure: () => setState(
                                  () => _showConfirm = !_showConfirm),
                            ),

                            const SizedBox(height: 48),

                            // 确认修改按钮
                            SizedBox(
                              width: double.infinity,
                              height: 52,
                              child: ElevatedButton(
                                onPressed: _submit,
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: AppColors.lime,
                                  foregroundColor: const Color(0xFF9EA0A4),
                                  elevation: 0,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(26),
                                  ),
                                ),
                                child: const Text(
                                  '确认修改',
                                  style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w600),
                                ),
                              ),
                            ),

                            const SizedBox(height: 16),

                            // 忘记旧密码
                            TextButton(
                              onPressed: () => Navigator.of(context).push(
                                MaterialPageRoute(
                                    builder: (_) =>
                                        const ResetPasswordByPhonePage()),
                              ),
                              child: const Text(
                                '忘记旧密码？',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Color(0xFF4ECDC4),
                                ),
                              ),
                            ),

                            const SizedBox(height: 48),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      );
}

/// 带锁图标 + 密码可见切换的输入框。
class _PasswordField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final bool obscure;
  final VoidCallback onToggleObscure;

  const _PasswordField({
    required this.controller,
    required this.hint,
    required this.obscure,
    required this.onToggleObscure,
  });

  @override
  Widget build(BuildContext context) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.lock_outline, color: AppColors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                obscureText: obscure,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      const TextStyle(color: AppColors.muted, fontSize: 16),
                  border: InputBorder.none,
                ),
              ),
            ),
            GestureDetector(
              onTap: onToggleObscure,
              child: Icon(
                obscure ? Icons.visibility_off : Icons.visibility,
                color: AppColors.muted,
                size: 24,
              ),
            ),
          ],
        ),
      );
}
