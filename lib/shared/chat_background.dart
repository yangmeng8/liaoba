import 'package:flutter/material.dart';

/// 聊天背景数据模型（渐变 + 点阵底纹颜色）。
class ChatBg {
  final int id;
  final Gradient gradient;
  final Color patternColor;

  const ChatBg({
    required this.id,
    required this.gradient,
    required this.patternColor,
  });
}

/// 9 张预设聊天背景（外观设置-聊天背景 与 聊天页 共用）。
const List<ChatBg> chatBackgrounds = [
  ChatBg(
    id: 0,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF5EEE5), Color(0xFFEDE4D8)]),
    patternColor: Color(0xFFD7CCC0),
  ),
  ChatBg(
    id: 1,
    gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFF8F3E8), Color(0xFFE8D9B4), Color(0xFFC9E2C4)]),
    patternColor: Color(0xFFD8CDA8),
  ),
  ChatBg(
    id: 2,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFEEF5E8), Color(0xFFDDEBCE)]),
    patternColor: Color(0xFFC2D8B0),
  ),
  ChatBg(
    id: 3,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFEAF1F8), Color(0xFFD6E4F3)]),
    patternColor: Color(0xFFB8CCDF),
  ),
  ChatBg(
    id: 4,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF6F0F2), Color(0xFFEADFE3)]),
    patternColor: Color(0xFFD0C1C7),
  ),
  ChatBg(
    id: 5,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF5EFE2), Color(0xFFE8DDBF)]),
    patternColor: Color(0xFFD5C49D),
  ),
  ChatBg(
    id: 6,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF7E9D4), Color(0xFFE8CF9F), Color(0xFFD1AE7A)]),
    patternColor: Color(0xFFC89F6B),
  ),
  ChatBg(
    id: 7,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFF2F5F0), Color(0xFFD8E4DD), Color(0xFFEAF0EC)]),
    patternColor: Color(0xFFB8CDC3),
  ),
  ChatBg(
    id: 8,
    gradient: LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFFEDF5FA), Color(0xFFD6E6EE), Color(0xFFBED8E5)]),
    patternColor: Color(0xFFA0C2D3),
  ),
];

/// 默认聊天背景：外观设置中默认选中的第 0 张。
final ChatBg defaultChatBackground = chatBackgrounds[0];

/// 运动图标点阵底纹（选择页/预览页/聊天页三处共用）。
/// alpha 由调用方通过 color.withValues 控制。
class SportsIconPatternPainter extends CustomPainter {
  final Color color;
  SportsIconPatternPainter(this.color);

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
  bool shouldRepaint(covariant SportsIconPatternPainter old) =>
      old.color != color;
}

/// 聊天背景层：渐变底 + 点阵，铺满父容器（放在 Stack 的 Positioned.fill）。
class ChatBackgroundLayer extends StatelessWidget {
  final ChatBg bg;

  const ChatBackgroundLayer({super.key, required this.bg});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(gradient: bg.gradient),
      child: CustomPaint(
        painter: SportsIconPatternPainter(
          bg.patternColor.withValues(alpha: 0.35),
        ),
      ),
    );
  }
}
