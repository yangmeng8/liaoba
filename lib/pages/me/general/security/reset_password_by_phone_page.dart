import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import 'change_bound_phone_page.dart';

/// 通过短信验证重置密码（忘记密码）页面。
class ResetPasswordByPhonePage extends StatefulWidget {
  const ResetPasswordByPhonePage({super.key});

  @override
  State<ResetPasswordByPhonePage> createState() =>
      _ResetPasswordByPhonePageState();
}

class _ResetPasswordByPhonePageState extends State<ResetPasswordByPhonePage> {
  final _codeController = TextEditingController();
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _showNew = false;
  bool _showConfirm = false;

  Timer? _countdownTimer;
  int _countdown = 0;

  static const _boundPhone = '185****4829';

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _codeController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  bool get _isCounting => _countdown > 0;

  void _startCountdown() {
    setState(() => _countdown = 60);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _countdown--;
        if (_countdown <= 0) {
          timer.cancel();
          _countdownTimer = null;
        }
      });
    });
  }

  void _onGetCode() {
    if (_isCounting) return;
    // TODO: 调用发送短信验证码接口（入参 phone = _boundPhone）
    _showToast('验证码已发送');
    _startCountdown();
  }

  void _submit() {
    final code = _codeController.text.trim();
    final newPwd = _newPasswordController.text.trim();
    final confirmPwd = _confirmPasswordController.text.trim();

    if (code.isEmpty || newPwd.isEmpty || confirmPwd.isEmpty) {
      _showToast('请填写完整信息');
      return;
    }
    if (newPwd != confirmPwd) {
      _showToast('两次输入的新密码不一致');
      return;
    }
    // TODO: 调用重置密码接口
    _showToast('密码重置成功');
    // 清空路由栈回到账户安全页
    Navigator.of(context).popUntil((route) => route.isFirst);
  }

  void _showToast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
        backgroundColor: colors.bg,
        body: Column(
          children: [
            // 顶部导航栏
            Container(
              color: colors.surface,
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
                          icon: Icon(Icons.chevron_left,
                              size: 34, color: colors.surfaceText),
                        ),
                      ),
                      Text(
                        '修改密码',
                        style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colors.surfaceText),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 可滚动区域
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
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const SizedBox(height: 20),

                            // 当前绑定手机号行
                            Row(
                              children: [
                                Text(
                                  '当前绑定：',
                                  style: TextStyle(
                                      fontSize: 15, color: colors.muted),
                                ),
                                Text(
                                  _boundPhone,
                                  style: TextStyle(
                                      fontSize: 15, color: colors.muted),
                                ),
                                const Spacer(),
                                GestureDetector(
                                  onTap: () => Navigator.of(context).push(
                                    MaterialPageRoute(
                                        builder: (_) =>
                                            const ChangeBoundPhonePage()),
                                  ),
                                  child: const Text(
                                    '更换手机号',
                                    style: TextStyle(
                                      fontSize: 15,
                                      color: Color(0xFF4ECDC4),
                                    ),
                                  ),
                                ),
                              ],
                            ),

                            const SizedBox(height: 16),

                            // 验证码输入框
                            _CodeField(
                              controller: _codeController,
                              isCounting: _isCounting,
                              countdown: _countdown,
                              onGetCode: _onGetCode,
                            ),
                            const SizedBox(height: 12),

                            // 新密码
                            _PasswordField(
                              controller: _newPasswordController,
                              hint: '请输入新密码',
                              obscure: !_showNew,
                              onToggleObscure: () =>
                                  setState(() => _showNew = !_showNew),
                            ),
                            const SizedBox(height: 12),

                            // 确认新密码
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
                                  foregroundColor: Colors.black,
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
}

/// 短信验证码输入框 + 获取按钮。
class _CodeField extends StatelessWidget {
  final TextEditingController controller;
  final bool isCounting;
  final int countdown;
  final VoidCallback onGetCode;

  const _CodeField({
    required this.controller,
    required this.isCounting,
    required this.countdown,
    required this.onGetCode,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.mark_email_read_outlined,
                color: colors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                style: TextStyle(fontSize: 16, color: colors.text),
                decoration: InputDecoration(
                  hintText: '请输入短信验证码',
                  hintStyle:
                      TextStyle(color: colors.muted, fontSize: 16),
                  border: InputBorder.none,
                ),
              ),
            ),
            GestureDetector(
              onTap: isCounting ? null : onGetCode,
              child: Text(
                isCounting ? '${countdown}s 后重试' : '获取验证码',
                style: TextStyle(
                  fontSize: 15,
                  color: isCounting
                      ? colors.muted
                      : const Color(0xFF4ECDC4),
                ),
              ),
            ),
          ],
        ),
      );
  }
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
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: colors.card,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(Icons.lock_outline, color: colors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                obscureText: obscure,
                style: TextStyle(fontSize: 16, color: colors.text),
                decoration: InputDecoration(
                  hintText: hint,
                  hintStyle:
                      TextStyle(color: colors.muted, fontSize: 16),
                  border: InputBorder.none,
                ),
              ),
            ),
            GestureDetector(
              onTap: onToggleObscure,
              child: Icon(
                obscure ? Icons.visibility_off : Icons.visibility,
                color: colors.muted,
                size: 24,
              ),
            ),
          ],
        ),
      );
  }
}
