import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../shared/app_theme.dart';
import 'my_qrcode_page.dart';
import 'nickname_edit_page.dart';
import 'signature_edit_page.dart';

/// 个人资料页面。
class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  /// 用户选择的头像文件；null 时显示默认占位。
  XFile? _avatarFile;

  /// 当前昵称（可从编辑页回写）。
  String _nickname = '李猛';

  /// 当前个性签名。
  String _signature = '';

  final _picker = ImagePicker();

  void _toast(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  /// 点击头像行 → 弹出底部选择框。
  void _onAvatarTap() {
    final colors = context.colors;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: colors.card,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        final sheetColors = ctx.colors;
        return SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SheetItem(
                label: '在线拍照',
                colors: sheetColors,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAvatar(ImageSource.camera);
                },
              ),
              Container(height: 0.5, color: sheetColors.divider),
              _SheetItem(
                label: '本地相册',
                colors: sheetColors,
                onTap: () {
                  Navigator.pop(ctx);
                  _pickAvatar(ImageSource.gallery);
                },
              ),
              const SizedBox(height: 8),
              _SheetItem(
                label: '取消',
                colors: sheetColors,
                isDestructive: true,
                onTap: () => Navigator.pop(ctx),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  /// 调用 image_picker 拍照 / 选相册。
  Future<void> _pickAvatar(ImageSource source) async {
    try {
      final picked = await _picker.pickImage(
        source: source,
        imageQuality: 85,
        maxWidth: 512,
        maxHeight: 512,
      );
      if (picked != null) {
        setState(() => _avatarFile = picked);
        _toast('头像已更新');
      }
    } catch (e) {
      // 用户拒绝权限或取消时 image_picker 会抛异常，这里兜底提示。
      _toast('无法获取图片：$e');
    }
  }

  /// 点击签名行 → 跳转编辑页，保存后回写。
  Future<void> _onSignatureTap() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => SignatureEditPage(initialSignature: _signature),
      ),
    );
    if (result != null && mounted) {
      setState(() => _signature = result);
    }
  }

  /// 点击昵称行 → 跳转编辑页，保存后回写。
  Future<void> _onNicknameTap() async {
    final result = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => NicknameEditPage(initialNickname: _nickname),
      ),
    );
    if (result != null && mounted) {
      setState(() => _nickname = result);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;

    // 模拟当前用户资料（实际应从状态层读取）
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
                            _buildAvatar(),
                            const SizedBox(width: 8),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: _onAvatarTap,
                      ),
                      _ProfileRow(
                        title: '昵称',
                        colors: colors,
                        showDivider: true,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_nickname,
                                style: TextStyle(
                                    fontSize: 16, color: colors.muted)),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: _onNicknameTap,
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
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                _signature.isEmpty ? '添加个性签名' : _signature,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  color: _signature.isEmpty
                                      ? colors.muted
                                      : colors.muted,
                                ),
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(Icons.chevron_right,
                                size: 26, color: colors.muted),
                          ],
                        ),
                        onTap: _onSignatureTap,
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

  /// 头像：有选择的图片用 FileImage，否则显示默认占位。
  Widget _buildAvatar() {
    const placeholder = _AvatarPlaceholder();
    if (_avatarFile == null) return placeholder;
    return Container(
      width: 46,
      height: 46,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        image: DecorationImage(
          image: FileImage(File(_avatarFile!.path)),
          fit: BoxFit.cover,
        ),
      ),
    );
  }
}

/// 默认头像占位：淡蓝渐变 + 人物图标。
class _AvatarPlaceholder extends StatelessWidget {
  const _AvatarPlaceholder();

  @override
  Widget build(BuildContext context) => Container(
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

/// 底部弹框的单条按钮。
class _SheetItem extends StatelessWidget {
  final String label;
  final ThemeColors colors;
  final VoidCallback onTap;
  final bool isDestructive;

  const _SheetItem({
    required this.label,
    required this.colors,
    required this.onTap,
    this.isDestructive = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: double.infinity,
        height: 56,
        alignment: Alignment.center,
        color: colors.card,
        child: Text(
          label,
          style: TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w500,
            color: isDestructive ? colors.muted : colors.text,
          ),
        ),
      ),
    );
  }
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
