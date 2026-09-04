import 'dart:async';
import 'package:flutter/material.dart';
import '../../main.dart';
import '../../services/api_client.dart';
import '../../services/auth_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';

/// 注册页。
class RegisterPage extends StatefulWidget {
  const RegisterPage({super.key});

  @override
  State<RegisterPage> createState() => _RegisterPageState();
}

class _RegisterPageState extends State<RegisterPage> {
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _nicknameController = TextEditingController();
  final _codeController = TextEditingController();

  bool _showPassword = false;
  bool _agreeTerms = false;
  bool _sendingCode = false;
  bool _registering = false;

  int _codeCountdown = 0;
  Timer? _codeTimer;

  @override
  void dispose() {
    _codeTimer?.cancel();
    _phoneController.dispose();
    _passwordController.dispose();
    _nicknameController.dispose();
    _codeController.dispose();
    super.dispose();
  }

  bool get _isPhoneValid =>
      RegExp(r'^1[3-9]\d{9}$').hasMatch(_phoneController.text.trim());

  bool get _isPasswordValid {
    final p = _passwordController.text;
    return RegExp(r'^[A-Za-z0-9]{6,16}$').hasMatch(p);
  }

  void _startCountdown() {
    setState(() => _codeCountdown = 60);
    _codeTimer?.cancel();
    _codeTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      setState(() {
        _codeCountdown--;
        if (_codeCountdown <= 0) {
          timer.cancel();
          _codeTimer = null;
        }
      });
    });
  }

  Future<void> _onSendCode() async {
    if (_codeCountdown > 0 || _sendingCode) return;
    if (!_isPhoneValid) {
      _toast('请输入正确的手机号');
      return;
    }
    setState(() => _sendingCode = true);
    try {
      await AuthApi.sendSmsCode(
        mobile: _phoneController.text.trim(),
        scene: SmsScene.memberLogin,
      );
      _toast('验证码已发送');
      _startCountdown();
    } catch (e) {
      _toast(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _sendingCode = false);
    }
  }

  Future<void> _onRegister() async {
    if (_registering) return;
    if (!_agreeTerms) {
      _toast('请先阅读并同意用户注册协议');
      return;
    }
    if (_phoneController.text.trim().isEmpty ||
        _passwordController.text.isEmpty ||
        _nicknameController.text.trim().isEmpty ||
        _codeController.text.trim().isEmpty) {
      _toast('请填写完整信息');
      return;
    }
    if (!_isPhoneValid) {
      _toast('请输入正确的手机号');
      return;
    }
    if (!_isPasswordValid) {
      _toast('密码需为 6-16 位字母或数字');
      return;
    }

    setState(() => _registering = true);
    try {
      // 注册成功后，AuthApi 内部已把 userId/accessToken/refreshToken/
      // expiresTime/openid 保存到 AuthManager（含持久化）
      await AuthApi.smsRegister(
        mobile: _phoneController.text.trim(),
        code: _codeController.text.trim(),
        password: _passwordController.text,
        nickname: _nicknameController.text.trim(),
      );
      if (!mounted) return;
      _toast('注册成功');
      // 清空导航栈直接进入主框架（消息页），不返回登录页
      Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute(builder: (_) => const HomeShell()),
        (route) => false,
      );
    } catch (e) {
      _toast(ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => FocusScope.of(context).unfocus(),
        child: SafeArea(
          child: Column(
            children: [
              // 顶栏
              Container(
                color: colors.bg,
                child: SizedBox(
                  height: 56,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Align(
                        alignment: Alignment.centerLeft,
                        child: IconButton(
                          tooltip: '返回',
                          onPressed: () => Navigator.of(context).pop(),
                          icon: Icon(
                            Icons.chevron_left,
                            size: 34,
                            color: colors.text,
                          ),
                        ),
                      ),
                      Text(
                        '注册',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w600,
                          color: colors.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 内容区
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  children: [
                    Text(
                      '欢迎使用聊吧',
                      style: TextStyle(
                        fontSize: 30,
                        fontWeight: FontWeight.w700,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(height: 28),

                    _InputBox(
                      controller: _phoneController,
                      hint: '请输入您的手机号码',
                      keyboardType: TextInputType.phone,
                      maxLength: 11,
                      colors: colors,
                    ),
                    const SizedBox(height: 16),

                    _InputBox(
                      controller: _passwordController,
                      hint: '请输入6-16位字母或数字密码',
                      obscure: !_showPassword,
                      colors: colors,
                      suffix: IconButton(
                        onPressed: () =>
                            setState(() => _showPassword = !_showPassword),
                        icon: Icon(
                          _showPassword
                              ? Icons.visibility
                              : Icons.visibility_off,
                          color: colors.muted,
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    _InputBox(
                      controller: _nicknameController,
                      hint: '请输入昵称',
                      colors: colors,
                    ),
                    const SizedBox(height: 16),

                    _InputBox(
                      controller: _codeController,
                      hint: '请输入短信验证码',
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      colors: colors,
                      suffix: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: GestureDetector(
                          onTap: _onSendCode,
                          child: Text(
                            _sendingCode
                                ? '发送中...'
                                : _codeCountdown > 0
                                ? '${_codeCountdown}s 后重试'
                                : '发送验证码',
                            style: TextStyle(
                              fontSize: 16,
                              color: _codeCountdown > 0 || _sendingCode
                                  ? colors.muted
                                  : const Color(0xFF4ECDC4),
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // 协议勾选
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        const SizedBox(width: 4),
                        SizedBox(
                          width: 20,
                          height: 20,
                          child: Checkbox(
                            value: _agreeTerms,
                            activeColor: AppColors.lime,
                            checkColor: Colors.black,
                            shape: const CircleBorder(),
                            side: BorderSide(color: colors.muted, width: 2),
                            visualDensity: VisualDensity.compact,
                            onChanged: (v) =>
                                setState(() => _agreeTerms = v ?? false),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => _agreeTerms = !_agreeTerms),
                            child: RichText(
                              text: TextSpan(
                                style: TextStyle(
                                  fontSize: 14,
                                  color: colors.muted,
                                ),
                                children: const [
                                  TextSpan(text: '同意《'),
                                  TextSpan(
                                    text: '用户注册协议',
                                    style: TextStyle(color: Color(0xFF4ECDC4)),
                                  ),
                                  TextSpan(text: '》'),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 28),

                    // 注册按钮
                    SizedBox(
                      height: 56,
                      child: ElevatedButton(
                        onPressed: _registering ? null : _onRegister,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppColors.lime,
                          disabledBackgroundColor: AppColors.lime,
                          disabledForegroundColor: Colors.black,
                          foregroundColor: Colors.black,
                          elevation: 0,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(28),
                          ),
                        ),
                        child: _registering
                            ? const SizedBox(
                                width: 22,
                                height: 22,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2.5,
                                  color: Colors.black,
                                ),
                              )
                            : const Text(
                                '注册',
                                style: TextStyle(
                                  fontSize: 19,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 统一圆角输入框。
class _InputBox extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ThemeColors colors;
  final TextInputType? keyboardType;
  final int? maxLength;
  final bool obscure;
  final Widget? suffix;

  const _InputBox({
    required this.controller,
    required this.hint,
    required this.colors,
    this.keyboardType,
    this.maxLength,
    this.obscure = false,
    this.suffix,
  });

  @override
  Widget build(BuildContext context) {
    final textColor = colors.text;
    final hintColor = colors.muted;

    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: colors.card,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const SizedBox(width: 18),
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              obscureText: obscure,
              style: TextStyle(fontSize: 16, color: textColor),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: 16, color: hintColor),
                border: InputBorder.none,
                counterText: '',
              ),
              maxLength: maxLength,
            ),
          ),
          // ignore: use_null_aware_elements
          if (suffix != null) suffix!,
        ],
      ),
    );
  }
}
