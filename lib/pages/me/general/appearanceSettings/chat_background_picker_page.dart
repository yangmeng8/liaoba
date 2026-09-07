import 'package:flutter/material.dart';

import '../../../../shared/app_colors.dart';
import '../../../../shared/app_theme.dart';
import '../../../../shared/chat_background.dart';
import 'chat_background_preview_page.dart';

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

  /// 点击卡片 → 直接进入全屏预览；
  /// 仅当在预览页点击"设置"并确认后返回，才更新选中项。
  Future<void> _onTapCard(int index) async {
    final result = await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ChatBackgroundPreviewPage(
          backgrounds: chatBackgrounds,
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
                itemCount: chatBackgrounds.length,
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 12,
                  crossAxisSpacing: 12,
                  childAspectRatio: 0.55, // 模拟手机竖长卡片
                ),
                itemBuilder: (context, index) {
                  final bg = chatBackgrounds[index];
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
                    painter: SportsIconPatternPainter(
                      bg.patternColor.withValues(alpha: 0.35),
                    ),
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
