import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../shared/app_colors.dart';
import '../../../shared/app_theme.dart';

/// 关于我们 / 版本信息页面。
class AboutPage extends StatefulWidget {
  const AboutPage({super.key});

  @override
  State<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends State<AboutPage> {
  String _version = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    setState(() => _version = info.version);
  }

  void _showComingSoon() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('功能即将上线')),
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
                        '版本信息',
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

            // 中间内容区
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Logo（绿色圆形背景 + "聊吧"文字占位）
                    Container(
                      width: 120,
                      height: 120,
                      decoration: const BoxDecoration(
                        color: AppColors.lime,
                        shape: BoxShape.circle,
                      ),
                      // TODO: 替换为真实 App Logo
                      child: const Center(
                        child: Text(
                          '聊吧',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),

                    // App 名称
                    Text(
                      '聊吧',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                    const SizedBox(height: 6),

                    // 版本号（从 pubspec.yaml 动态读取）
                    Text(
                      _version.isEmpty ? '' : 'v$_version',
                      style: TextStyle(
                        fontSize: 18,
                        color: colors.muted,
                      ),
                    ),
                    const SizedBox(height: 20),

                    // 检查新版本
                    GestureDetector(
                      onTap: _showComingSoon,
                      child: const Text(
                        '检查新版本',
                        style: TextStyle(
                          fontSize: 16,
                          color: Color(0xFF4ECDC4),
                          decoration: TextDecoration.underline,
                          decorationColor: Color(0xFF4ECDC4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      );
  }
}
