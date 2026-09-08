import 'package:flutter/material.dart';

/// IM 统一头像组件（对应 H5 im-avatar.vue）：
/// - src 非空 → 图片裁剪填满（aspectFill）
/// - src 为空 → 文字首字符 + 按名字 hash 的稳定底色（字母色卡兜底）
///
/// 同一名字在任何设备/任何时刻兜底颜色一致（名字不变则 hash 不变），
/// 保证与 H5 端视觉统一（色板与算法原样对齐）。
class ImAvatar extends StatelessWidget {
  /// 头像图片地址（空串走字母色卡兜底）。
  final String src;

  /// 用于兜底取字与配色的名字（用真实昵称而非备注，保持跨设备一致）。
  final String name;

  final double size;

  /// 圆角：聊天室内用圆角方形（8），其他场景可传圆形。
  final BorderRadius borderRadius;

  const ImAvatar({
    super.key,
    required this.src,
    required this.name,
    this.size = 40,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
  });

  @override
  Widget build(BuildContext context) {
    final radius = borderRadius;
    if (src.isNotEmpty) {
      return ClipRRect(
        borderRadius: radius,
        child: Image.network(
          src,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          // 图片加载失败也走色卡兜底
          errorBuilder: (_, _, _) => _buildFallback(),
        ),
      );
    }
    return _buildFallback();
  }

  Widget _buildFallback() {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: avatarBgColor(name),
        borderRadius: borderRadius,
      ),
      alignment: Alignment.center,
      child: Text(
        avatarText(name),
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.42,
          fontWeight: FontWeight.w500,
          height: 1,
        ),
      ),
    );
  }
}

/// 兜底头像色板（微信风格，与 H5 AVATAR_BG_COLORS 原样对齐）。
const List<Color> kAvatarBgColors = [
  Color(0xFF07C160),
  Color(0xFF1A95FF),
  Color(0xFFFA9D3B),
  Color(0xFF9163E0),
  Color(0xFFF76760),
  Color(0xFF1ABC9C),
];

/// 按名字 hash 稳定取色（charCode 累加取模，名字不变颜色不变）。
Color avatarBgColor(String name) {
  if (name.isEmpty) return const Color(0xFF909399);
  var hash = 0;
  for (final cu in name.codeUnits) {
    hash += cu;
  }
  return kAvatarBgColors[hash % kAvatarBgColors.length];
}

/// 兜底头像取字规则（与 H5 getAvatarText 对齐）：
/// - 中文（0x4E00~0x9FA5）→ 取第一个字
/// - 含英文字母 → 取前两个字母大写（tom → TO）
/// - 无字母（纯数字/符号）→ 首字符大写（123 → 1）
String avatarText(String name) {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return '?';
  final first = trimmed.characters.first;
  final code = first.codeUnitAt(0);
  if (code >= 0x4E00 && code <= 0x9FA5) return first;
  final letters = RegExp(
    r'[a-z]',
    caseSensitive: false,
  ).allMatches(trimmed).map((m) => m.group(0)!).toList();
  if (letters.isEmpty) return first.toUpperCase();
  return letters.take(2).join().toUpperCase();
}
