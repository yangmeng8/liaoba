import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';

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

  static const _boundPhone = '185****4829';

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

  void _onGetCode() {
    if (_isCounting) return;
    if (!_isPhoneValid) {
      _showToast('请输入正确的新手机号');
      return;
    }
    // TODO: 调用发送短信验证码接口（入参 phone = 新手机号）
    _showToast('验证码已发送');
    _startCountdown();
  }

  void _submit() {
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
    // TODO: 调用修改绑定手机号接口
    _showToast('绑定成功');
    Navigator.of(context).popUntil((route) => route.isFirst);
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
                        '修改绑定手机号',
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
                            const Text(
                              '当前绑定：$_boundPhone',
                              style: TextStyle(
                                  fontSize: 15, color: AppColors.muted),
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

/// 手机号输入框。
class _PhoneField extends StatelessWidget {
  final TextEditingController controller;
  final String hint;

  const _PhoneField({required this.controller, required this.hint});

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
            const Icon(Icons.phone_iphone, color: AppColors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.phone,
                maxLength: 11,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  counterText: '',
                  hintText: hint,
                  hintStyle: const TextStyle(
                      color: AppColors.muted, fontSize: 16),
                  border: InputBorder.none,
                ),
              ),
            ),
          ],
        ),
      );
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
  Widget build(BuildContext context) => Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            const Icon(Icons.mark_email_read_outlined,
                color: AppColors.muted, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  hintText: '请输入短信验证码',
                  hintStyle: const TextStyle(
                      color: AppColors.muted, fontSize: 16),
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
                      ? const Color(0xFFB6BBC2)
                      : const Color(0xFF4ECDC4),
                ),
              ),
            ),
          ],
        ),
      );
}
