import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// 我的二维码页面。
class MyQrcodePage extends StatelessWidget {
  const MyQrcodePage({super.key});

  // 二维码中编码的内容（前缀+聊吧号，实际应读取当前用户 id）
  static const _qrData = 'LIAOBA:97160mek';
  static const _nickname = '李猛';

  void _toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          // 全屏背景：模拟足球场模糊渐变（深蓝→绿→黑）
          _buildBackground(),
          // 顶栏 + 卡片 + 底部按钮
          SafeArea(
            child: Column(
              children: [
                _buildAppBar(context),
                const Spacer(flex: 1),
                _buildQrCard(),
                SizedBox(height: 30),
              //  const Spacer(flex: 1),
                _buildBottomActions(context),
                const Spacer(flex: 2),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBackground() => const DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF12202E),
              Color(0xFF2C3F2C),
              Color(0xFF1A3A1A),
              Color(0xFF0F2710),
            ],
            stops: [0.0, 0.45, 0.75, 1.0],
          ),
        ),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: Alignment(0.1, -0.3),
              radius: 1.2,
              colors: [
                Color(0x55FFFFFF),
                Color(0x00FFFFFF),
              ],
            ),
          ),
        ),
      );

  Widget _buildAppBar(BuildContext context) => SizedBox(
        height: 64,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: IconButton(
                tooltip: '返回',
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.chevron_left,
                    size: 34, color: Colors.white),
              ),
            ),
            const Text(
              '我的二维码',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      );

  /// 中间白色圆角卡片：二维码(嵌头像) + 昵称 + 副标题。
  Widget _buildQrCard() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Container(
          padding: const EdgeInsets.fromLTRB(28, 25, 28, 25),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 二维码 + 中心头像（Stack 叠加）
              SizedBox(
                width: 200,
                height: 200,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Positioned.fill(
                      child: QrImageView(
                        data: _qrData,
                        version: QrVersions.auto,
                        errorCorrectionLevel: QrErrorCorrectLevel.H,
                        eyeStyle: const QrEyeStyle(
                          eyeShape: QrEyeShape.square,
                          color: Colors.black,
                        ),
                        dataModuleStyle: const QrDataModuleStyle(
                          dataModuleShape: QrDataModuleShape.square,
                          color: Colors.black,
                        ),
                        embeddedImageEmitsError: true,
                      ),
                    ),
                    // 中心头像（白描边 + 灰外圈，遮挡后二维码仍可识别，因为 H 纠错）
                    Container(
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(color: Colors.white, width: 3),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.1),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: _avatar,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                _nickname,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w500,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 10),
              const Text(
                '打开聊吧 APP，扫码加我为好友',
                style: TextStyle(
                  fontSize: 15,
                  color: Color(0xFF666666),
                ),
              ),
            ],
          ),
        ),
      );

  /// 底部两个圆形按钮：扫一扫 / 保存图片
  Widget _buildBottomActions(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 60),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _ActionButton(
              icon: Icons.qr_code_scanner_rounded,
              label: '扫一扫',
              onTap: () {
                // TODO: 调起扫一扫
                _toast(context, '扫一扫');
              },
            ),
            _ActionButton(
              icon: Icons.download_rounded,
              label: '保存图片',
              onTap: () {
                // TODO: 保存二维码卡片到相册
                _toast(context, '已保存到相册');
              },
            ),
          ],
        ),
      );

  /// 渐变圆形头像（与个人资料页保持一致）。
  Widget get _avatar => Container(
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFBDE7FF), Color(0xFF93D5C3)],
          ),
        ),
        child: const Icon(
          Icons.person,
          color: Color(0xFF304B73),
          size: 36,
        ),
      );
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      customBorder: const CircleBorder(),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 50,
            height: 50,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Icon(icon, size: 32, color: const Color(0xFF222222)),
          ),
          const SizedBox(height: 10),
          Text(
            label,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w500,
              color: Colors.white,
            ),
          ),
        ],
      ),
    );
  }
}
