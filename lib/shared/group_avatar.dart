import 'package:flutter/material.dart';

import '../models/im_conversation.dart';
import '../services/im_api.dart';
import 'im_avatar.dart';

/// 群聊九宫格合成头像（对应 H5 group-avatar.vue），三级降级：
/// ① 群自定义头像非空 → 整格单图（同 ImAvatar）
/// ② 无自定义头像 且 成员表已加载 → 前 9 名有效成员拼九宫格，
///    格内成员头像继续走 ImAvatar（首字 + hash 色卡兜底）
/// ③ 成员表没有（加载失败/空群）→ 群名首字 + hash 底色（ImAvatar 兜底）
///
/// 列数公式（与 H5 group.ts 一致）：成员 ≤1 → 1 列；≤4 → 2 列；≤9 → 3 列。
class GroupAvatar extends StatefulWidget {
  /// 群编号（懒加载成员表用）。
  final int groupId;

  /// 群自定义头像（空串走九宫格）。
  final String src;

  /// 群名（九宫格整格兜底取字与配色）。
  final String name;

  final double size;

  final BorderRadius borderRadius;

  const GroupAvatar({
    super.key,
    required this.groupId,
    required this.src,
    required this.name,
    this.size = 56,
    this.borderRadius = const BorderRadius.all(Radius.circular(12)),
  });

  @override
  State<GroupAvatar> createState() => _GroupAvatarState();

  /// 成员表缓存（key: groupId）：进程级复用，滚动复用不重复请求。
  /// 会话头像聚合链每次从 store 实时解析群自定义头像（不持久化 URL），
  /// 此缓存仅服务九宫格成员头像，群成员变动由下次冷启动或重进页面刷新。
  static final Map<int, List<ImGroupMember>> _memberCache = {};

  /// 在途请求标记（防滚动时同群并发重复拉取）。
  static final Set<int> _loading = {};

  /// 清空成员缓存（登出/切号时调用）。
  static void clearCache() {
    _memberCache.clear();
    _loading.clear();
  }
}

class _GroupAvatarState extends State<GroupAvatar> {
  @override
  void initState() {
    super.initState();
    _loadMembers();
  }

  @override
  void didUpdateWidget(GroupAvatar old) {
    super.didUpdateWidget(old);
    // 换群 / 群主清掉自定义头像切九宫格时补拉
    if (old.groupId != widget.groupId ||
        (old.src.isNotEmpty && widget.src.isEmpty)) {
      _loadMembers();
    }
  }

  /// 懒加载成员表：无自定义头像、未缓存、未在途才拉。
  void _loadMembers() {
    if (widget.src.isNotEmpty) return;
    if (widget.groupId <= 0) return;
    if (GroupAvatar._memberCache.containsKey(widget.groupId)) return;
    if (GroupAvatar._loading.contains(widget.groupId)) return;
    GroupAvatar._loading.add(widget.groupId);
    ImApi.getGroupMemberList(groupId: widget.groupId).then((members) {
      GroupAvatar._memberCache[widget.groupId] = members;
      if (mounted) setState(() {}); // 拉到后宫格自动重渲染
    }).catchError((Object _) {
      // 加载失败：走群名首字兜底；下次重建若仍在视口会重试
    }).whenComplete(() => GroupAvatar._loading.remove(widget.groupId));
  }

  @override
  Widget build(BuildContext context) {
    // ① 群自定义头像
    if (widget.src.isNotEmpty) {
      return ImAvatar(
        src: widget.src,
        name: widget.name,
        size: widget.size,
        borderRadius: widget.borderRadius,
      );
    }
    // ② 前 9 名有效成员九宫格
    final members = (GroupAvatar._memberCache[widget.groupId] ?? const [])
        .where((m) => m.active)
        .take(9)
        .toList();
    if (members.isNotEmpty) {
      return _buildGrid(members);
    }
    // ③ 群名首字 + hash 底色兜底
    return ImAvatar(
      src: '',
      name: widget.name,
      size: widget.size,
      borderRadius: widget.borderRadius,
    );
  }

  /// 九宫格：外层圆角 + 灰底 + 内边距，行×列手排
  /// （底色/间距对齐 H5：#d8d8d8、padding 4rpx、gap 3rpx 按 size 等比）。
  Widget _buildGrid(List<ImGroupMember> members) {
    final cols = members.length <= 1 ? 1 : (members.length <= 4 ? 2 : 3);
    final rows = (members.length / cols).ceil();
    final gap = widget.size * 0.03;
    final padding = widget.size * 0.04;
    // 格子边长：去内边距后按列数均分（含间距）
    final cell = (widget.size - padding * 2 - gap * (cols - 1)) / cols;
    return ClipRRect(
      borderRadius: widget.borderRadius,
      child: Container(
        width: widget.size,
        height: widget.size,
        color: const Color(0xFFD8D8D8),
        padding: EdgeInsets.all(padding),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) SizedBox(height: gap),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var c = 0; c < cols; c++) ...[
                    if (c > 0) SizedBox(width: gap),
                    if (r * cols + c < members.length)
                      _buildCell(members[r * cols + c], cell)
                    else
                      SizedBox(width: cell, height: cell),
                  ],
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 单格：成员头像（无图 → 成员昵称首字 + hash 稳定底色，与 H5 同款算法；
  /// 取昵称而非组内显示名，保证跨设备 hash 一致）。
  Widget _buildCell(ImGroupMember m, double cell) {
    return ImAvatar(
      src: m.avatar,
      name: m.nickname,
      size: cell,
      borderRadius: BorderRadius.zero,
    );
  }
}
