import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      children: [
        AppHeader(
          title: '通讯录',
          showSearch: true,
          actions: [
            IconButton(
              onPressed: () {},
              icon: const Icon(Icons.add_circle_outline, size: 25),
            ),
          ],
        ),
        Container(
          decoration: BoxDecoration(
            color: colors.card,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              ContactAction(icon: Icons.person_add_alt_1_outlined, title: '新的朋友'),
              Divider(height: 1, indent: 80, color: colors.divider),
              ContactAction(icon: Icons.groups_outlined, title: '群聊'),
            ],
          ),
        ),
        Expanded(
          child: Center(
            child: Text(
              '0位好友',
              style: TextStyle(fontSize: 18, color: colors.muted),
            ),
          ),
        ),
      ],
    );
  }
}

class ContactAction extends StatelessWidget {
  final IconData icon;
  final String title;
  const ContactAction({super.key, required this.icon, required this.title});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return SizedBox(
      height: 60,
      child: Row(
        children: [
          const SizedBox(width: 18),
          Container(
            width: 45,
            height: 45,
            decoration: const BoxDecoration(
              color: AppColors.lime,
              shape: BoxShape.circle,
            ),
            // lime 底为亮色，图标固定深色，不随主题切换
            child: Icon(icon, size: 25, color: const Color(0xFF1A1A1A)),
          ),
          const SizedBox(width: 22),
          Text(
            title,
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w500,
                color: colors.text),
          ),
        ],
      ),
    );
  }
}
