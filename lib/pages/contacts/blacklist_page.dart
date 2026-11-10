import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/im_avatar.dart';
import '../../shared/settings_dialog.dart';
import '../../shared/widgets.dart';
import 'user_profile_page.dart';

/// 黑名单列表页：
/// 数据源复用 friend/list（后端返回含拉黑好友，通讯录只过滤了展示）；
/// 每行可一键「移除」或点头像进资料页操作，移出后自动从列表消失。
class BlacklistPage extends StatefulWidget {
  const BlacklistPage({super.key});

  @override
  State<BlacklistPage> createState() => _BlacklistPageState();
}

class _BlacklistPageState extends State<BlacklistPage> {
  List<ImFriend> _blocked = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final friends = await ImApi.getFriendList();
      if (!mounted) return;
      setState(() => _blocked = friends
          .where((f) => f.blocked && f.status == ImCommonStatus.enable)
          .toList());
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('加载失败，请重试')));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 移出黑名单（确认后调 unblock，成功从列表移除）。
  Future<void> _unblock(ImFriend f) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: ctx.colors.card,
        title: Text('移出黑名单',
            style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: ctx.colors.text)),
        content: Text('移出后，${f.shownName}将恢复为普通好友，可以正常收发消息。',
            style: TextStyle(fontSize: 15, color: ctx.colors.text)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('取消', style: TextStyle(color: ctx.colors.muted)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child:
                const Text('移出', style: TextStyle(color: AppColors.lime)),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await ImApi.unblockFriend(friendUserId: f.friendUserId);
      if (!mounted) return;
      setState(() => _blocked.removeWhere(
          (e) => e.friendUserId == f.friendUserId));
      ScaffoldMessenger.maybeOf(context)
        ?..hideCurrentSnackBar()
        ..showSnackBar(const SnackBar(content: Text('已移出黑名单')));
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)
          ?..hideCurrentSnackBar()
          ..showSnackBar(const SnackBar(content: Text('操作失败，请重试')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Scaffold(
      backgroundColor: colors.bg,
      body: Column(
        children: [
          _buildHeader(colors),
          Expanded(
            child: _loading && _blocked.isEmpty
                ? const Center(
                    child: CircularProgressIndicator(color: AppColors.lime))
                : _buildList(colors),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeColors colors) {
    return Container(
      color: colors.surface,
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 64,
          child: Row(
            children: [
              IconButton(
                icon: const Icon(Icons.arrow_back_ios_new, size: 22),
                color: colors.surfaceText,
                // pop（不用 maybePop）：桌面弹框内本页是嵌套导航的第一页
                onPressed: () => Navigator.of(context).pop(),
              ),
              Expanded(
                child: Text(
                  '黑名单',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    color: colors.surfaceText,
                  ),
                ),
              ),
              const SizedBox(width: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildList(ThemeColors colors) {
    if (_blocked.isEmpty) {
      return const EmptyState(label: '黑名单是空的');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: _blocked.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 82, color: colors.divider),
        itemBuilder: (context, i) {
          final f = _blocked[i];
          return InkWell(
            // 点击进资料页（blocked 态自带红色「移除黑名单」按钮，返回后刷新）
            onTap: () async {
              await showPanelPage(
                context,
                UserProfilePage(userId: f.friendUserId),
              );
              _load();
            },
            child: Container(
              color: colors.card,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  ImAvatar(src: f.avatar, name: f.nickname, size: 46),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      f.shownName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: colors.text),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _unblock(f),
                    style: TextButton.styleFrom(
                      foregroundColor: colors.muted,
                      minimumSize: const Size(64, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: Text('移除',
                        style: TextStyle(fontSize: 14, color: colors.muted)),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
