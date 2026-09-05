import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/api_client.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/widgets.dart';
import '../../stores/conversation_store.dart';

/// 消息 Tab：会话列表（客户端由消息流聚合，对应 H5 conversationStore）。
class MessagesPage extends StatefulWidget {
  const MessagesPage({super.key});

  @override
  State<MessagesPage> createState() => _MessagesPageState();
}

class _MessagesPageState extends State<MessagesPage> {
  bool _loading = false;
  String? _error;

  /// 过滤条件：0=全部 1=特别关注 2=未读 3=群聊。
  int _filterIndex = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ConversationStore.instance.load();
    } catch (e) {
      if (mounted) setState(() => _error = ApiClient.errorMessage(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 按当前 chip 过滤会话列表。
  List<ImConversation> get _filtered {
    final list = ConversationStore.instance.conversations;
    return switch (_filterIndex) {
      1 => list.where((c) => c.pinned).toList(),
      2 => list.where((c) => c.unreadCount > 0).toList(),
      3 => list.where((c) => c.type == ImConversationType.group).toList(),
      _ => list,
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start, // 强制整列子项左对齐，避免默认 center 居中
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
        // 父级控制 FilterChips 的左边距（与 AppHeader 的 20 接近，但更靠左 2px）
        Padding(
          padding: const EdgeInsets.only(left: 18),
          child: FilterChips(
            selectedIndex: _filterIndex,
            onChanged: (i) => setState(() => _filterIndex = i),
          ),
        ),
        Expanded(
          child: _buildBody(colors),
        ),
      ],
    );
  }

  Widget _buildBody(ThemeColors colors) {
    if (_loading && ConversationStore.instance.conversations.isEmpty) {
      return const Center(child: CircularProgressIndicator(color: AppColors.lime));
    }
    if (_error != null) {
      return _ErrorRetry(
        message: _error!,
        colors: colors,
        onRetry: _load,
      );
    }
    final list = _filtered;
    if (list.isEmpty) {
      return const EmptyState(label: '暂无任何消息');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero, // 去掉 ListView 自动加的 MediaQuery 顶部安全区空白
        itemCount: list.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 84, endIndent: 16, color: colors.divider),
        itemBuilder: (context, i) => _ConversationTile(conversation: list[i]),
      ),
    );
  }
}

/// 会话条目：头像 + 名称 + 最后一条消息 + 时间 + 未读角标。
class _ConversationTile extends StatelessWidget {
  final ImConversation conversation;

  const _ConversationTile({required this.conversation});

  /// 时间展示：今天 HH:mm；今年 MM-dd；更早 yyyy-MM-dd。
  String _formatTime(DateTime? time) {
    if (time == null) return '';
    final now = DateTime.now();
    final local = time.toLocal();
    if (local.year == now.year && local.month == now.month && local.day == now.day) {
      return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
    }
    if (local.year == now.year) {
      return '${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
    }
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final unread = conversation.unreadCount;
    return InkWell(
      onTap: () {
        // TODO: 跳转聊天页（私聊传 receiverId / 群聊传 groupId）
      },
      child: Container(
        color: colors.bg,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          children: [
            _Avatar(
              name: conversation.title,
              avatarUrl: conversation.avatar,
              isGroup: conversation.type == ImConversationType.group,
              isChannel: conversation.type == ImConversationType.channel,
            ),
            const SizedBox(width: 12),
            // 名称 + 摘要
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      // 置顶标记
                      if (conversation.pinned) ...[
                        Icon(Icons.push_pin, size: 14, color: colors.muted),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          conversation.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: colors.text,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _formatTime(conversation.lastMessageTime),
                        style: TextStyle(fontSize: 12, color: colors.muted),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          conversation.lastMessageText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, color: colors.muted),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _UnreadBadge(
                        count: unread,
                        silent: conversation.silent,
                        mutedColor: colors.muted,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 头像：有 URL 加载网络图；群聊多人图标；频道喇叭图标；其余取名称首字。
class _Avatar extends StatelessWidget {
  final String name;
  final String avatarUrl;
  final bool isGroup;
  final bool isChannel;

  const _Avatar({
    required this.name,
    required this.avatarUrl,
    required this.isGroup,
    this.isChannel = false,
  });

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (avatarUrl.isNotEmpty) {
      child = Image.network(
        avatarUrl,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _fallback(context),
      );
    } else {
      child = _fallback(context);
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(width: 56, height: 56, child: child),
    );
  }

  Widget _fallback(BuildContext context) {
    if (isChannel) {
      return Container(
        color: context.colors.divider,
        alignment: Alignment.center,
        child: Icon(Icons.campaign_outlined,
            size: 30, color: context.colors.muted),
      );
    }
    if (isGroup) {
      return Container(
        color: context.colors.divider,
        alignment: Alignment.center,
        child: Icon(Icons.groups_outlined, size: 30, color: context.colors.muted),
      );
    }
    final initial = name.isNotEmpty ? name.characters.first : '?';
    return Container(
      color: AppColors.lime,
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w600,
          color: Colors.black,
        ),
      ),
    );
  }
}

/// 未读角标：免打扰灰点；普通红底数字；99+ 封顶。
class _UnreadBadge extends StatelessWidget {
  final int count;
  final bool silent;
  final Color mutedColor;

  const _UnreadBadge({
    required this.count,
    required this.silent,
    required this.mutedColor,
  });

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    if (silent) {
      return Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(color: mutedColor, shape: BoxShape.circle),
      );
    }
    return Container(
      constraints: const BoxConstraints(minWidth: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: const Color(0xFFFA5151),
        borderRadius: BorderRadius.circular(10),
      ),
      alignment: Alignment.center,
      child: Text(
        count > 99 ? '99+' : '$count',
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
    );
  }
}

/// 加载失败重试。
class _ErrorRetry extends StatelessWidget {
  final String message;
  final ThemeColors colors;
  final VoidCallback onRetry;

  const _ErrorRetry({
    required this.message,
    required this.colors,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.wifi_off_outlined, size: 48, color: colors.muted),
            const SizedBox(height: 16),
            Text(message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: colors.muted)),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: onRetry,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppColors.lime,
                foregroundColor: Colors.black,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20)),
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

/// 过滤 chips：全部 / 特别关注 / 未读 / 群聊 / +。
class FilterChips extends StatelessWidget {
  final int selectedIndex;

  /// 点击切换回调（'+' 传 -1，不参与选中态）。
  final ValueChanged<int> onChanged;

  const FilterChips({super.key, required this.selectedIndex, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final labels = ['全部', '特别关注', '未读', '群聊', '+'];
    return Container(
      color: colors.bg,
      // left=0：左边距已由父级 Padding(left:18) 接管；右 14 与 AppHeader 右侧一致
      padding: const EdgeInsets.fromLTRB(0, 10, 14, 10),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: GestureDetector(
                  onTap: () => onChanged(i == 4 ? -1 : i),
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: i == 4 ? 18 : 12,
                      vertical: 6, // 统一高度，避免 + 号高出其他 chip
                    ),
                    decoration: BoxDecoration(
                      color: i == selectedIndex ? AppColors.lime : colors.divider,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Text(
                      labels[i],
                      style: TextStyle(
                        fontSize: i == 4 ? 15 : 13, // + 号字号稍收，与其他 chip 视觉高度一致
                        fontWeight: selectedIndex == i ? FontWeight.w700 : FontWeight.w500,
                        color: i == selectedIndex ? Colors.black : colors.muted,
                      ),
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
