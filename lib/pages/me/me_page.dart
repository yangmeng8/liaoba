import 'package:flutter/material.dart';
import 'general/general_settings_page.dart';
import 'general/appearanceSettings/appearance_settings_page.dart';

class MePage extends StatelessWidget {
  const MePage({super.key});

  static VoidCallback? _onItemTap(String title, BuildContext context) {
    switch (title) {
      case '外观设置':
        return () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const AppearanceSettingsPage()),
            );
      case '通用':
        return () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const GeneralSettingsPage()),
            );
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final items = [
      (Icons.badge_outlined, '个人资料'),
      (Icons.inventory_2_outlined, '我的收藏'),
      (Icons.notifications_none, '通知设置'),
      (Icons.chat_outlined, '聊天设置'),
      (Icons.palette_outlined, '外观设置'),
      (Icons.smart_toy_outlined, '通用'),
    ];
    return Column(
      children: [
        Container(
          height: 210,
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              colors: [Color(0xFF6D747B), Color(0xFF34404C)],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
          ),
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 22, 18, 0),
              child: Row(
                children: [
                  Container(
                    width: 74,
                    height: 74,
                    decoration: const BoxDecoration(
                      color: Color(0xFFBDE7FF),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person,
                      size: 50,
                      color: Color(0xFF304B73),
                    ),
                  ),
                  const SizedBox(width: 18),
                  const Text(
                    '李猛',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  const Icon(Icons.qr_code_2, color: Colors.white, size: 26),
                  const SizedBox(width: 10),
                  const Icon(
                    Icons.chevron_right,
                    color: Colors.white,
                    size: 26,
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            color: const Color(0xFFF8F8F8),
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: const BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
              ),
              child: ListView.builder(
                padding: const EdgeInsets.only(top: 8),
                itemCount: items.length,
                itemBuilder: (context, i) => ListTile(
                  onTap: _onItemTap(items[i].$2, context),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 0,
                  ),
                  leading: Icon(items[i].$1, size: 24),
                  title: Text(
                    items[i].$2,
                    style: const TextStyle(fontSize: 18),
                  ),
                  trailing: const Icon(
                    Icons.chevron_right,
                    size: 24,
                    color: Color(0xFFB6BBC2),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
