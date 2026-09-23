import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../../services/auth_manager.dart';
import 'friend_apply_page.dart';

/// 扫一扫页（添加好友）：
/// 相机识别好友二维码（内容格式 IM:im号）→ 跳转添加好友页自动搜索。
/// 非本应用二维码仅轻提示并继续扫；扫到自己提示不能添加。
class QrScanPage extends StatefulWidget {
  const QrScanPage({super.key});

  @override
  State<QrScanPage> createState() => _QrScanPageState();
}

class _QrScanPageState extends State<QrScanPage> {
  /// 已识别到有效码标记（防同一码连续触发多次跳转）。
  bool _handled = false;

  /// 无效码提示节流（同帧多次识别只 toast 一次）。
  DateTime _lastBadToast = DateTime.fromMillisecondsSinceEpoch(0);

  /// 手电筒开关。
  bool _torchOn = false;

  final MobileScannerController _controller = MobileScannerController(
    facing: CameraFacing.back,
    detectionSpeed: DetectionSpeed.normal,
    torchEnabled: false,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    final now = DateTime.now();
    if (now.difference(_lastBadToast).inMilliseconds < 1500) return;
    _lastBadToast = now;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: const Color(0xB3000000),
      ));
  }

  /// 识别回调：IM:前缀取 im号 → 添加好友页（自动搜索）。
  void _onDetect(BarcodeCapture capture) {
    if (_handled || !mounted) return;
    final raw = capture.barcodes.firstOrNull?.rawValue;
    if (raw == null || raw.isEmpty) return;
    if (!raw.startsWith('IM:')) {
      _toast('不是有效的IM二维码');
      return;
    }
    final code = raw.substring(3).trim();
    if (code.isEmpty) {
      _toast('二维码内容无效');
      return;
    }
    if (code == (AuthManager.instance.imCode ?? '')) {
      _toast('不能添加自己为好友');
      return;
    }
    _handled = true;
    // 替换当前扫码页：从添加好友页返回时直接回到入口页
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => FriendApplyPage(initialKeyword: code)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          // 相机预览（铺满全屏）
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
          ),
          // 四周半透明遮罩 + 中央取景框
          _buildMask(),
          // 顶部返回
          SafeArea(
            child: Align(
              alignment: Alignment.topLeft,
              child: IconButton(
                icon: const Icon(Icons.close, size: 28, color: Colors.white),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
            ),
          ),
          // 底部提示 + 手电筒
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 48),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '将二维码放入框内，即可自动扫描',
                      style: TextStyle(fontSize: 14, color: Colors.white70),
                    ),
                    const SizedBox(height: 28),
                    GestureDetector(
                      onTap: () {
                        setState(() => _torchOn = !_torchOn);
                        _controller.toggleTorch();
                      },
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _torchOn ? Icons.flash_on : Icons.flash_off,
                            size: 30,
                            color: _torchOn ? Colors.yellow : Colors.white54,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _torchOn ? '轻触关闭' : '轻触照亮',
                            style:
                                const TextStyle(fontSize: 12, color: Colors.white54),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 中央取景框：256x256 白色圆角边框 + 四角加重（微信风格，居中略偏上）。
  Widget _buildMask() {
    const double boxSize = 256;
    const double radius = 16;
    return IgnorePointer(
      child: Center(
        child: Padding(
          padding: const EdgeInsets.only(bottom: 80),
          child: Container(
            width: boxSize,
            height: boxSize,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(radius),
              border: Border.all(color: Colors.white54, width: 1.5),
            ),
            child: Stack(
              children: const [
                Align(alignment: Alignment.topLeft, child: _Corner(cornerSide: _CornerSide.tl)),
                Align(alignment: Alignment.topRight, child: _Corner(cornerSide: _CornerSide.tr)),
                Align(alignment: Alignment.bottomLeft, child: _Corner(cornerSide: _CornerSide.bl)),
                Align(alignment: Alignment.bottomRight, child: _Corner(cornerSide: _CornerSide.br)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 取景框四角 L 型装饰。
enum _CornerSide { tl, tr, bl, br }

class _Corner extends StatelessWidget {
  final _CornerSide cornerSide;
  const _Corner({required this.cornerSide});

  @override
  Widget build(BuildContext context) {
    const len = 26.0;
    const thick = 3.5;
    const color = Colors.white;
    final isTop = cornerSide == _CornerSide.tl || cornerSide == _CornerSide.tr;
    final isLeft = cornerSide == _CornerSide.tl || cornerSide == _CornerSide.bl;
    return SizedBox(
      width: len,
      height: len,
      child: Stack(children: [
        Align(
          alignment: isLeft ? Alignment.centerLeft : Alignment.centerRight,
          child: Container(width: thick, height: double.infinity, color: color),
        ),
        Align(
          alignment: isTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: Container(width: double.infinity, height: thick, color: color),
        ),
      ]),
    );
  }
}
