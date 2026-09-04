import 'package:flutter/material.dart';
import '../../shared/app_theme.dart';
import 'my_qrcode_page.dart';

/// 个人资料页面。
class ProfilePage extends StatelessWidget {
  const ProfilePage({super.key});

  void _toast(BuildContext context, String msg) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(msg)));

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    // 模拟当前用户资料（实际应从状态层读取）
    const nickname = '李猛';
    const liaoBaId = '97160mek';
    const phone = '18589854829';

    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          // 顶栏：返回 + 标题
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
                      '个人资料',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: colors.surfaceText,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),

          // 资料项：头像 / 昵称 / 聊吧号 / 手机 / 二维码 / 签名
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 12),
              children: [
                Container(
                  color: colors.card,
                  child: Column(
                    children: [
                      _ProfileRow(
                        title: '头像',
                        colors: colors,
                        showDivider: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _avatar,
                            const SizedBox(width: 8),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: () => _toast(context, '更换头像'),
                      ),
                      _ProfileRow(
                        title: '昵称',
                        colors: colors,
                        showDivider: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(nickname,
                                style: TextStyle(
                                    fontSize: 16, color: colors.muted)),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: () => _toast(context, '修改昵称'),
                      ),
                      _ProfileRow(
                        title: '聊吧号',
                        colors: colors,
                        showDivider: true,
                        trailing: Text(liaoBaId,
                            style: TextStyle(
                                fontSize: 16, color: colors.muted)),
                      ),
                      _ProfileRow(
                        title: '手机号码',
                        colors: colors,
                        showDivider: true,
                        trailing: Text(phone,
                            style: TextStyle(
                                fontSize: 16, color: colors.muted)),
                      ),
                      _ProfileRow(
                        title: '我的二维码',
                        colors: colors,
                        showDivider: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.qr_code_2,
                                size: 28, color: colors.text),
                            const SizedBox(width: 8),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: () => Navigator.of(context).push(
                              MaterialPageRoute(
                                  builder: (_) => const MyQrcodePage()),
                            ),
                      ),
                      _ProfileRow(
                        title: '个性签名',
                        colors: colors,
                        showDivider: false,
                        trailing: Icon(Icons.chevron_right,
                            size: 26, color: colors.muted),
                        onTap: () => _toast(context, '修改个性签名'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 圆形头像占位：淡蓝渐变 + 人物图标（模拟截图中的卡通头像）。
  Widget get _avatar => Container(
        width: 46,
        height: 46,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFBDE7FF), Color(0xFF93D5C3)],
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: const Icon(
          Icons.person,
          color: Color(0xFF304B73),
          size: 32,
        ),
      );
}

/// 单条资料行。
class _ProfileRow extends StatelessWidget {
  final String title;
  final ThemeColors colors;
  final bool showDivider;
  final Widget trailing;
  final VoidCallback? onTap;

  const _ProfileRow({
    required this.title,
    required this.colors,
    required this.showDivider,
    required this.trailing,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final row = Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: colors.divider))
            : null,
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
                fontSize: 18,
                color: colors.text,
                fontWeight: FontWeight.w500),
          ),
          const Spacer(),
          trailing,
        ],
      ),
    );
    return onTap == null
        ? row
        : InkWell(
            onTap: onTap,
            child: row,
          );
  }
}
