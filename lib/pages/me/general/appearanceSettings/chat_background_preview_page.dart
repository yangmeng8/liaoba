import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import 'chat_background_picker_page.dart';

/// 聊天背景预览页（全屏 PageView + 聊天气泡模拟）。
class ChatBackgroundPreviewPage extends StatefulWidget {
  final List<ChatBg> backgrounds;
  final int initialIndex;

  const ChatBackgroundPreviewPage({
    super.key,
    required this.backgrounds,
    required this.initialIndex,
  });

  @override
  State<ChatBackgroundPreviewPage> createState() =>
      _ChatBackgroundPreviewPageState();
}

class _ChatBackgroundPreviewPageState extends State<ChatBackgroundPreviewPage> {
  late PageController _pageController;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    _pageController = PageController(initialPage: _currentIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _onCancel() {
    // 取消：不选中，直接返回（不带结果）
    Navigator.of(context).pop();
  }

  void _onSet() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => _SetConfirmDialog(),
    );
    if (confirmed == true && mounted) {
      // TODO: 保存聊天背景（写入本地持久化 / 调接口）
      Navigator.of(context).pop(_currentIndex);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
        body: Column(
          children: [
            // 顶部导航栏（绿色）
            Container(
              color: colors.surface,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 64,
                  child: Row(
                    children: [
                      // 取消
                      Expanded(
                        child: TextButton(
                          onPressed: _onCancel,
                          child: Text(
                            '取消',
                            style: TextStyle(
                                fontSize: 18, color: colors.surfaceText),
                          ),
                        ),
                      ),
                      // 预览
                      Expanded(
                        child: Center(
                          child: Text(
                            '预览',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: colors.surfaceText),
                          ),
                        ),
                      ),
                      // 设置
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _onSet,
                            child: Text(
                              '设置',
                              style: TextStyle(
                                  fontSize: 18,
                                  color: colors.surfaceText,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            // 预览区域（PageView 左右滑动）
            Expanded(
              child: PageView.builder(
                controller: _pageController,
                itemCount: widget.backgrounds.length,
                onPageChanged: (i) => setState(() => _currentIndex = i),
                itemBuilder: (context, i) => _ChatPreview(bg: widget.backgrounds[i]),
              ),
            ),

            // 底部 page indicator
            SafeArea(
              top: false,
              child: Container(
                color: colors.card,
                padding:
                    const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(
                    widget.backgrounds.length,
                    (i) => Container(
                      width: i == _currentIndex ? 18 : 6,
                      height: 6,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: i == _currentIndex
                            ? AppColors.lime
                            : colors.divider,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
  }
}

/// 设置确认弹框。
class _SetConfirmDialog extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Dialog(
        backgroundColor: colors.card,
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
                  color: colors.text,
                ),
              ),
              const SizedBox(height: 24),
              Text(
                '这会替换你的现有聊天背景，只有你能看到你的聊天背景。',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 16, color: colors.muted),
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
                          backgroundColor: colors.bg,
                          foregroundColor: colors.text,
                          elevation: 0,
                          side: BorderSide(color: colors.divider),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(23),
                          ),
                        ),
                        child: Text(
                          '取消',
                          style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: colors.text),
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
}

/// 单个预览页：背景图 + 聊天气泡模拟。
class _ChatPreview extends StatelessWidget {
  final ChatBg bg;
  const _ChatPreview({required this.bg});

  @override
  Widget build(BuildContext context) => Container(
        decoration: BoxDecoration(gradient: bg.gradient),
        child: Stack(
          children: [
            // 背景底纹
            Positioned.fill(
              child: CustomPaint(
                painter: _SportsIconPatternPainter(
                  bg.patternColor.withValues(alpha: 0.35),
                ),
              ),
            ),

            // 聊天气泡
            SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                children: [
                  // 日期标签
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        '今天',
                        style: TextStyle(
                            fontSize: 12, color: Color(0xFF888888)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 对方消息（白色气泡，左）
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.65),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        '左右滑动即可预览更多背景图 🖼️✨',
                        style: TextStyle(fontSize: 15, color: Colors.black87),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // 我的消息（绿色气泡，右）
                  Align(
                    alignment: Alignment.centerRight,
                    child: Container(
                      constraints: BoxConstraints(
                          maxWidth: MediaQuery.of(context).size.width * 0.7),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.lime,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: const Text(
                        '这会替换你的现有默认聊天背景，只有你能看到你的聊天背景。',
                        style: TextStyle(fontSize: 15, color: Colors.black87),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // 已读标记
                  Align(
                    alignment: Alignment.centerRight,
                    child: const Icon(Icons.done_all,
                        size: 18, color: Color(0xFF4ECDC4)),
                  ),
                ],
              ),
            ),
          ],
        ),
      );
}

/// 底纹 painter（与选择页保持一致）。
class _SportsIconPatternPainter extends CustomPainter {
  final Color color;
  _SportsIconPatternPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const step = 36.0;
    for (double y = 18; y < size.height; y += step) {
      for (double x = 18; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 5, paint);
        canvas.drawLine(Offset(x - 4, y), Offset(x + 4, y), paint);
        canvas.drawLine(Offset(x, y - 4), Offset(x, y + 4), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
