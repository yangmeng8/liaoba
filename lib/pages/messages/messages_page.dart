import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
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
    final labels = ['全部', '特别关注', '未读', '群聊', '+'];
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.fromLTRB(18, 10, 14, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 20),
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: i == 4 ? 13 : 17,
                    vertical: 7,
                  ),
                  decoration: BoxDecoration(
                    color: i == 0 ? AppColors.lime : const Color(0xFFF7F7F7),
                    borderRadius: BorderRadius.circular(30),
                  ),
                  child: Text(
                    labels[i],
                    style: TextStyle(
                      fontSize: i == 4 ? 22 : 16,
                      fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w500,
                      color: i == 0 ? Colors.black : AppColors.muted,
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
