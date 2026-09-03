import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import 'chat_background_preview_page.dart';

/// 聊天背景数据模型。
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

/// 聊天背景选择页面（九宫格）。
class ChatBackgroundPickerPage extends StatefulWidget {
  const ChatBackgroundPickerPage({super.key});

  @override
  State<ChatBackgroundPickerPage> createState() =>
      _ChatBackgroundPickerPageState();
}

class _ChatBackgroundPickerPageState extends State<ChatBackgroundPickerPage> {
  // 9 张预设聊天背景，默认选中第 0 张
  int _selectedIndex = 0;

  static const List<ChatBg> _backgrounds = [
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

  /// 点击卡片 → 直接进入全屏预览；
  /// 仅当在预览页点击"设置"并确认后返回，才更新选中项。
  Future<void> _onTapCard(int index) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatBackgroundPreviewPage(
          backgrounds: _backgrounds,
          initialIndex: index,
        ),
      ),
    );
    if (result is int && mounted) {
      setState(() => _selectedIndex = result);
    }
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
                        '选择背景图',
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

            // 背景网格
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
                itemCount: _backgrounds.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.55, // 模拟手机竖长卡片
                ),
                itemBuilder: (context, index) {
                  final bg = _backgrounds[index];
                  final selected = index == _selectedIndex;
                  return _BgCard(
                    bg: bg,
                    selected: selected,
                    onTap: () => _onTapCard(index),
                  );
                },
              ),
            ),
          ],
        ),
      );
  }
}

/// 背景图卡片（手机形状 + 选中绿框 + 底部对勾）。
class _BgCard extends StatelessWidget {
  final ChatBg bg;
  final bool selected;
  final VoidCallback onTap;

  const _BgCard({
    required this.bg,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: selected
                ? Border.all(color: AppColors.lime, width: 3)
                : Border.all(color: Colors.transparent, width: 3),
          ),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 背景渐变 + 运动图标底纹
              ClipRRect(
                borderRadius: BorderRadius.circular(11),
                child: Container(
                  decoration: BoxDecoration(gradient: bg.gradient),
                  child: CustomPaint(
                    painter: _SportsIconPatternPainter(bg.patternColor),
                  ),
                ),
              ),
              // 选中对勾
              if (selected)
                Positioned(
                  right: 6,
                  bottom: 6,
                  child: Container(
                    width: 26,
                    height: 26,
                    decoration: const BoxDecoration(
                      color: AppColors.lime,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.check,
                      size: 18,
                      color: Colors.black,
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
}

/// 运动图标底纹（简化点阵 + 运动相关符号，视觉上接近设计稿）。
class _SportsIconPatternPainter extends CustomPainter {
  final Color color;
  _SportsIconPatternPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    const step = 28.0;
    for (double y = 14; y < size.height; y += step) {
      for (double x = 14; x < size.width; x += step) {
        // 画一些小圆圈 / 十字 作为图标占位
        canvas.drawCircle(Offset(x, y), 4, paint);
        canvas.drawLine(Offset(x - 3, y), Offset(x + 3, y), paint);
        canvas.drawLine(Offset(x, y - 3), Offset(x, y + 3), paint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
