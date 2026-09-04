import 'dart:async';
import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import 'register_page.dart';
import 'reset_password_page.dart';

/// 登录页：支持「快捷登录」与「密码登录」两种模式切换。
class LoginPage extends StatefulWidget {
  const LoginPage({super.key});

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // 快捷登录
  final _quickPhoneController = TextEditingController();
  final _codeController = TextEditingController();
  int _codeCountdown = 0;
  Timer? _codeTimer;

  // 密码登录
  final _passwordAccountController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _showPassword = false;

  // 协议勾选
  bool _agreeTerms = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _tabController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _codeTimer?.cancel();
    _tabController.dispose();
    _quickPhoneController.dispose();
    _codeController.dispose();
    _passwordAccountController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  bool get _isQuickMode => _tabController.index == 0;

  bool get _isPhoneValid {
    final phone = (_isQuickMode ? _quickPhoneController : _passwordAccountController)
        .text
        .trim();
    return RegExp(r'^1[3-9]\d{9}$').hasMatch(phone);
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

  void _onGetCode() {
    if (_codeCountdown > 0) return;
    if (!_isPhoneValid) {
      _toast('请输入正确的手机号');
      return;
    }
    // TODO: 调用发送短信验证码接口
    _toast('验证码已发送');
    _startCountdown();
  }

  void _onLogin() {
    if (!_agreeTerms) {
      _toast('请先阅读并同意使用协议和隐私政策');
      return;
    }

    if (_isQuickMode) {
      final phone = _quickPhoneController.text.trim();
      final code = _codeController.text.trim();
      if (phone.isEmpty || code.isEmpty) {
        _toast('请填写完整信息');
        return;
      }
      if (!_isPhoneValid) {
        _toast('请输入正确的手机号');
        return;
      }
      // TODO: 调用快捷登录接口
      _toast('快捷登录提交');
    } else {
      final account = _passwordAccountController.text.trim();
      final password = _passwordController.text.trim();
      if (account.isEmpty || password.isEmpty) {
        _toast('请填写完整信息');
        return;
      }
      // TODO: 调用密码登录接口
      _toast('密码登录提交');
    }
  }

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final tabSelectedColor = colors.text;
    final tabUnselectedColor = colors.muted;

    return Scaffold(
      backgroundColor: colors.bg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 60),

            // Logo + 聊吧 标题
            Container(
              width: 90,
              height: 90,
              decoration: const BoxDecoration(
                color: AppColors.lime,
                shape: BoxShape.circle,
              ),
              child: const Center(
                child: Text(
                  '聊吧',
                  style: TextStyle(
                    fontSize: 38,
                    fontWeight: FontWeight.w800,
                    color: Colors.black,
                    fontFamily: 'PingFang SC',
                  ),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              '聊吧',
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w800,
                color: colors.text,
              ),
            ),
            const SizedBox(height: 20),

            // Tab：快捷登录 / 密码登录
            SizedBox(
              width: 240,
              child: TabBar(
                controller: _tabController,
                dividerColor: Colors.transparent, // 去掉 TabBar 默认底部分割线
                indicator: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppColors.lime, width: 3),
                  ),
                ),
                indicatorSize: TabBarIndicatorSize.label,
                labelColor: tabSelectedColor,
                unselectedLabelColor: tabUnselectedColor,
                labelStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
                unselectedLabelStyle: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w400,
                ),
                tabs: const [
                  Tab(text: '快捷登录'),
                  Tab(text: '密码登录'),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // Tab 内容
            Expanded(
              child: TabBarView(
                controller: _tabController,
                physics: const NeverScrollableScrollPhysics(),
                children: [
                  _buildQuickLoginTab(colors),
                  _buildPasswordLoginTab(colors),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 快捷登录 Tab：手机号 + 验证码。
  Widget _buildQuickLoginTab(ThemeColors colors) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ListView(
          children: [
            _InputBox(
              controller: _quickPhoneController,
              hint: '请输入您的手机号码',
              keyboardType: TextInputType.phone,
              maxLength: 11,
              colors: colors,
            ),
            const SizedBox(height: 16),
            _InputBox(
              controller: _codeController,
              hint: '请输入验证码',
              keyboardType: TextInputType.number,
              maxLength: 6,
              colors: colors,
              suffix: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: GestureDetector(
                  onTap: _onGetCode,
                  child: Text(
                    _codeCountdown > 0 ? '${_codeCountdown}s 后重试' : '获取验证码',
                    style: TextStyle(
                      fontSize: 16,
                      color: _codeCountdown > 0
                          ? colors.muted
                          : const Color(0xFF4ECDC4),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 10),
            _buildLoginFooter(colors),
          ],
        ),
      );

  /// 密码登录 Tab：账号 + 密码（含明文切换）。
  Widget _buildPasswordLoginTab(ThemeColors colors) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: ListView(
          children: [
            _InputBox(
              controller: _passwordAccountController,
              hint: '请输入您的手机号码/聊吧号',
              colors: colors,
            ),
            const SizedBox(height: 16),
            _InputBox(
              controller: _passwordController,
              hint: '请输入密码',
              obscure: !_showPassword,
              colors: colors,
              suffix: IconButton(
                onPressed: () => setState(() => _showPassword = !_showPassword),
                icon: Icon(
                  _showPassword ? Icons.visibility : Icons.visibility_off,
                  color: colors.muted,
                ),
              ),
            ),
            const SizedBox(height: 20),
            _buildLoginFooter(colors),
          ],
        ),
      );

  /// 两种登录共享：注册用户/忘记密码 + 立即登录 + 协议勾选。
  Widget _buildLoginFooter(ThemeColors colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RegisterPage()),
                  );
                },
                child: Text(
                  '注册用户',
                  style: TextStyle(fontSize: 16, color: colors.muted),
                ),
              ),
              TextButton(
                onPressed: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const ResetPasswordPage()),
                  );
                },
                child: Text(
                  '忘记密码？',
                  style: TextStyle(fontSize: 16, color: colors.muted),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 56,
            child: ElevatedButton(
              onPressed: _onLogin,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(28),
                ),
              ),
              child: const Text(
                '立即登录',
                style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600),
              ),
            ),
          ),
          const SizedBox(height: 32),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const SizedBox(width: 8),
              SizedBox(
                width: 22,
                height: 22,
                child: Checkbox(
                  value: _agreeTerms,
                  activeColor: AppColors.lime,
                  checkColor: Colors.black,
                  shape: const CircleBorder(),
                  side: BorderSide(color: colors.muted, width: 2),
                  onChanged: (v) => setState(() => _agreeTerms = v ?? false),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: RichText(
                  text: TextSpan(
                    style: TextStyle(fontSize: 14, color: colors.muted),
                    children: const [
                      TextSpan(text: '请阅读并同意'),
                      TextSpan(
                        text: '使用协议',
                        style: TextStyle(color: Color(0xFF4ECDC4)),
                      ),
                      TextSpan(text: '和'),
                      TextSpan(
                        text: '隐私政策',
                        style: TextStyle(color: Color(0xFF4ECDC4)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
        ],
      );
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
