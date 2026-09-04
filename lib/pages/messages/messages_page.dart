import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/widgets.dart';

class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start, // 强制整列子项左对齐，避免默认 center 居中
    children: [
      AppHeader(
        title: '消息',
        showSearch: true,
        actions: [
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.edit_outlined, size: 24),
          ),
          IconButton(
            onPressed: () {},
            icon: const Icon(Icons.add_circle_outline, size: 25),
          ),
        ],
      ),
      // 父级控制 FilterChips 的左边距（与 AppHeader 的 20 接近，但更靠左 2px）
      Padding(
        padding: const EdgeInsets.only(left: 18),
        child: const FilterChips(),
      ),
      const Expanded(child: EmptyState(label: '暂无任何消息')),
    ],
  );
}

class FilterChips extends StatelessWidget {
  const FilterChips({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final labels = ['全部', '特别关注', '未读', '群聊', '+'];
    return Container(
      color: colors.bg,
      // left=0：左边距已由父级 Padding(left:18) 接管；右 14 与 AppHeader 右侧一致
      padding: const EdgeInsets.fromLTRB(0, 10, 14, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: i == 4 ? 18 : 12,
                    vertical: 6, // 统一高度，避免 + 号高出其他 chip
                  ),
                  decoration: BoxDecoration(
                    color: i == 0 ? AppColors.lime : colors.divider,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: i == 4 ? 15 : 13, // + 号字号稍收，与其他 chip 视觉高度一致
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                      color: i == 0 ? Colors.black : colors.muted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
