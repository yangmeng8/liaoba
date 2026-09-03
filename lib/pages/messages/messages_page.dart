import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/widgets.dart';

class MessagesPage extends StatelessWidget {
  const MessagesPage({super.key});
  @override
  Widget build(BuildContext context) => Column(
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
      const FilterChips(),
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
                    vertical: i == 4 ? 6 : 5,
                  ),
                  decoration: BoxDecoration(
                    color: i == 0 ? AppColors.lime : colors.divider,
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: i == 4 ? 16 : 13,
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
