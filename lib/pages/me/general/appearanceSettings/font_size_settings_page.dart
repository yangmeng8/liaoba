import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import '../../../../shared/font_scale_manager.dart';

/// 设置字体大小页面。
///
/// 拖动滑块在 小/标准/大 三档间切换，气泡预览文字实时缩放；
/// 点击"完成"保存并全局生效，点击"取消"不保存。
class FontSizeSettingsPage extends StatefulWidget {
  const FontSizeSettingsPage({super.key});

  @override
  State<FontSizeSettingsPage> createState() => _FontSizeSettingsPageState();
}

class _FontSizeSettingsPageState extends State<FontSizeSettingsPage> {
  /// 进入页面时的档位（取消时用于还原判断）。
  late int _index = FontScaleManager.instance.index;

  double get _scale => FontScaleManager.scales[_index];

  void _onCancel() => Navigator.of(context).pop(false);

  Future<void> _onDone() async {
    await FontScaleManager.instance.setIndex(_index);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
        backgroundColor: colors.bg,
        body: Column(
          children: [
            // 顶部导航栏：取消 | 设置字体大小 | 完成
            Container(
              color: colors.surface,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: 64,
                  child: Row(
                    children: [
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
                      Expanded(
                        child: Center(
                          child: Text(
                            '设置字体大小',
                            style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: colors.surfaceText),
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: _onDone,
                            child: Text(
                              '完成',
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

            // 预览区域（聊天底纹 + 气泡）
            Expanded(
              child: Stack(
                children: [
                  const Positioned.fill(
                    child: CustomPaint(painter: _PatternPainter()),
                  ),
                  SafeArea(
                    top: false,
                    child: ListView(
                      padding: const EdgeInsets.fromLTRB(16, 20, 16, 24),
                      children: [
                        // 我的消息（lime 气泡 + 头像）
                        _Row(
                          isMe: true,
                          scale: _scale,
                          bubbleColor: AppColors.lime,
                          text: '预览字体大小',
                        ),
                        const SizedBox(height: 40),

                        // 对方消息 1
                        _Row(
                          isMe: false,
                          scale: _scale,
                          bubbleColor: colors.card,
                          text: '拖动下面的滑块，可设置字体大小',
                        ),
                        const SizedBox(height: 40),

                        // 对方消息 2
                        _Row(
                          isMe: false,
                          scale: _scale,
                          bubbleColor: colors.card,
                          text:
                              '设置后，会改变APP中的字体大小。如果在使用过程中存在问题或意见，可反馈给我们。',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 底部滑块面板
            Container(
              color: colors.card,
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 刻度标签：A 小 标准 大 A
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          Text('A',
                              style: TextStyle(
                                  fontSize: 13, color: colors.muted)),
                          for (var i = 0; i < 3; i++)
                            Text(
                              FontScaleManager.labels[i],
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: _index == i
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                                color: _index == i
                                    ? colors.text
                                    : colors.muted,
                              ),
                            ),
                          Text(
                            'A',
                            style: TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.w600,
                                color: colors.text),
                          ),
                        ],
                      ),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 2,
                          activeTrackColor: colors.muted,
                          inactiveTrackColor: colors.muted
                              .withValues(alpha: 0.35),
                          thumbColor: colors.card,
                          overlayShape: SliderComponentShape.noOverlay,
                          thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 14),
                        ),
                        child: Slider(
                          value: _index.toDouble(),
                          min: 0,
                          max: 2,
                          divisions: 2,
                          onChanged: (v) =>
                              setState(() => _index = v.round().clamp(0, 2)),
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
}

/// 一行预览气泡（含头像）。
class _Row extends StatelessWidget {
  final bool isMe;
  final double scale;
  final Color bubbleColor;
  final String text;

  const _Row({
    required this.isMe,
    required this.scale,
    required this.bubbleColor,
    required this.text,
  });

  @override
  Widget build(BuildContext context) {
    final bubble = Flexible(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: bubbleColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16 * scale,
            height: 1.4,
            color: Colors.black87,
          ),
        ),
      ),
    );

    return Row(
      mainAxisAlignment:
          isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: isMe
          ? [bubble, const SizedBox(width: 8), _avatar(isMe)]
          : [_avatar(isMe), const SizedBox(width: 8), bubble],
    );
  }

  Widget _avatar(bool isMe) => isMe
      // 我的头像（蓝色圆 + 人像）
      ? Container(
          width: 42,
          height: 42,
          decoration: const BoxDecoration(
            color: Color(0xFFBFE3EE),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.person, color: Colors.white, size: 28),
        )
      // 对方头像（lime 圆 + 18 logo 占位）
      : Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.lime,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.black, width: 2),
          ),
          child: const Text(
            '18',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
          ),
        );
}

/// 米色运动图标底纹。
class _PatternPainter extends CustomPainter {
  const _PatternPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFFD8CFC4).withValues(alpha: 0.5)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const step = 48.0;
    for (double y = 24; y < size.height; y += step) {
      for (double x = 24; x < size.width; x += step) {
        canvas.drawCircle(Offset(x, y), 8, paint);
        canvas.drawLine(Offset(x - 6, y), Offset(x + 6, y), paint);
        canvas.drawLine(Offset(x, y - 6), Offset(x, y + 6), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
