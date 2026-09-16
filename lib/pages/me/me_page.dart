import 'package:flutter/material.dart';
import '../../services/auth_api.dart';
import '../../services/auth_manager.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import 'chat_settings_page.dart';
import 'favorites_page.dart';
import 'my_qrcode_page.dart';
import 'notification_settings_page.dart';
import 'profile_page.dart';
import 'general/general_settings_page.dart';
import 'general/appearanceSettings/appearance_settings_page.dart';

class MePage extends StatefulWidget {
  const MePage({super.key});

  @override
  State<MePage> createState() => _MePageState();
}

class _MePageState extends State<MePage> {
  @override
  void initState() {
    super.initState();
    // 进页刷新用户资料（昵称/头像）；缓存兜底，失败静默
    AuthApi.loadUserProfile().then((_) {
      if (mounted) setState(() {});
    }).catchError((_) {});
  }

  static VoidCallback? _onItemTap(String title, BuildContext context) {
    switch (title) {
      case '个人资料':
        return () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ProfilePage()),
            );
      case '外观设置':
        return () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const AppearanceSettingsPage()),
            );
      case '聊天设置':
        return () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ChatSettingsPage()),
            );
      case '我的收藏':
        return () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const FavoritesPage()),
            );
      case '通知设置':
        return () => Navigator.of(context).push(
              MaterialPageRoute(
                  builder: (_) => const NotificationSettingsPage()),
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
    // 登录用户资料（磁盘缓存 + 进页刷新）；接口无昵称时兜底「我」
    final nickname =
        (AuthManager.instance.nickname ?? '').trim().isNotEmpty
            ? AuthManager.instance.nickname!.trim()
            : '我';
    final avatar = AuthManager.instance.avatar ?? '';
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
                  // 用户头像（网络头像 / 字母色卡兜底，圆形）
                  ImAvatar(
                    src: avatar,
                    name: nickname,
                    size: 74,
                    borderRadius: const BorderRadius.all(Radius.circular(37)),
                  ),
                  const SizedBox(width: 18),
                  Text(
                    nickname,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 21,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  InkWell(
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const MyQrcodePage()),
                      );
                    },
                    borderRadius: BorderRadius.circular(20),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        Icon(Icons.qr_code_2, color: Colors.white, size: 26),
                        SizedBox(width: 10),
                        Icon(
                          Icons.chevron_right,
                          color: Colors.white,
                          size: 26,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        Expanded(
          child: Container(
            color: context.colors.bg,
            child: Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: context.colors.card,
                borderRadius:
                    const BorderRadius.vertical(top: Radius.circular(22)),
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
                  iconColor: context.colors.text,
                  leading: Icon(items[i].$1, size: 24),
                  title: Text(
                    items[i].$2,
                    style: TextStyle(
                        fontSize: 18, color: context.colors.text),
                  ),
                  trailing: Icon(
                    Icons.chevron_right,
                    size: 24,
                    color: context.colors.muted,
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
