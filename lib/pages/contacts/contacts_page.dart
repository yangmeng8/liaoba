import 'package:flutter/material.dart';
import '../../shared/app_colors.dart';
import '../../shared/widgets.dart';

class ContactsPage extends StatelessWidget {
  const ContactsPage({super.key});
  @override
  Widget build(BuildContext context) => Column(
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
        decoration: const BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: const Column(
          children: [
            ContactAction(icon: Icons.person_add_alt_1_outlined, title: '新的朋友'),
            Divider(height: 1, indent: 80),
            ContactAction(icon: Icons.groups_outlined, title: '群聊'),
          ],
        ),
      ),
      const Expanded(
        child: Center(
          child: Text(
            '0位好友',
            style: TextStyle(fontSize: 18, color: AppColors.muted),
          ),
        ),
      ),
    ],
  );
}

class ContactAction extends StatelessWidget {
  final IconData icon;
  final String title;
  const ContactAction({super.key, required this.icon, required this.title});
  @override
  Widget build(BuildContext context) => SizedBox(
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
          child: Icon(icon, size: 25),
        ),
        const SizedBox(width: 22),
        Text(
          title,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w500),
        ),
      ],
    ),
  );
}
