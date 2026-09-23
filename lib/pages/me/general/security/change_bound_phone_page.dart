import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../services/api_client.dart';
import '../../../../services/auth_api.dart';
import '../../../../services/auth_manager.dart';
import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';

/// 修改绑定手机号页面。
class ChangeBoundPhonePage extends StatefulWidget {
  const ChangeBoundPhonePage({super.key});

  @override
  State<ChangeBoundPhonePage> createState() => _ChangeBoundPhonePageState();
}

class _ChangeBoundPhonePageState extends State<ChangeBoundPhonePage> {
  final _phoneController = TextEditingController();
  final _codeController = TextEditingController();

  Timer? _countdownTimer;
  int _countdown = 0;

  /// 提交中防连点。
  bool _submitting = false;

  /// 当前绑定手机号（登录缓存真实号码）：185****4829（不足 11 位原样，空显示 -）。
  String get _boundPhone {
    final mobile = AuthManager.instance.mobile ?? '';
    if (mobile.length < 11) {
      return mobile.isEmpty ? '-' : mobile;
    }
    return '${mobile.substring(0, 3)}****${mobile.substring(7)}';
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _phoneController.dispose();
    _codeController.dispose();
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

  bool get _isPhoneValid {
    final phone = _phoneController.text.trim();
    return RegExp(r'^1[3-9]\d{9}$').hasMatch(phone);
  }

  Future<void> _onGetCode() async {
    if (_isCounting) return;
    if (!_isPhoneValid) {
      _showToast('请输入正确的新手机号');
      return;
    }
    // 验证码发到新手机号（scene=2 修改手机号，须与 update-mobile 校验一致）
    try {
      final ok = await AuthApi.sendSmsCode(
        mobile: _phoneController.text.trim(),
        scene: SmsScene.updateMobile,
      );
      if (!mounted) return;
      _showToast(ok ? '验证码已发送' : '验证码发送失败，请稍后重试');
      if (ok) _startCountdown();
    } catch (e) {
      if (mounted) _showToast('验证码发送失败：${ApiClient.errorMessage(e)}');
    }
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final phone = _phoneController.text.trim();
    final code = _codeController.text.trim();

    if (phone.isEmpty || code.isEmpty) {
      _showToast('请填写完整信息');
      return;
    }
    if (!_isPhoneValid) {
      _showToast('请输入正确的手机号');
      return;
    }
    setState(() => _submitting = true);
    try {
      await AuthApi.updateMobile(mobile: phone, code: code);
      // 更新本地缓存（账号安全页等显示处同步）
      await AuthManager.instance.updateMobile(phone);
      if (!mounted) return;
      _showToast('绑定成功');
      // 返回上一页（账号安全页），入口手机号显示随即刷新
      Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() => _submitting = false);
        _showToast('修改失败：${ApiClient.errorMessage(e)}');
      }
    }
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
                        '修改绑定手机号',
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

                            // 当前绑定手机号
                            Text(
                              '当前绑定：$_boundPhone',
                              style: TextStyle(
                                  fontSize: 15, color: colors.muted),
                            ),

                            const SizedBox(height: 16),

                            // 新手机号
                            _PhoneField(
                              controller: _phoneController,
                              hint: '请输入新手机号',
                            ),
                            const SizedBox(height: 12),

                            // 验证码
                            _CodeField(
                              controller: _codeController,
                              isCounting: _isCounting,
                              countdown: _countdown,
                              onGetCode: _onGetCode,
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

/// 手机号输入框。
class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;

  const _PhoneField({required this.controller, required this.hint});

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
            Icon(Icons.phone_iphone, color: colors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                style: TextStyle(fontSize: 16, color: colors.text),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: hint,
                  hintStyle:
                      TextStyle(color: colors.muted, fontSize: 16),
                  border: InputBorder.none,
                ),
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
