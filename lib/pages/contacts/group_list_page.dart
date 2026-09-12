import 'package:flutter/material.dart';

import '../../models/im_conversation.dart';
import '../../services/im_api.dart';
import '../../shared/app_colors.dart';
import '../../shared/app_theme.dart';
import '../../shared/group_avatar.dart';
import '../../shared/widgets.dart';
import '../chat/chat_page.dart';

/// 群聊列表页（对应 H5 /contact/group/list）：
/// 全量我的群（过滤已退群）+ 本地群名搜索；点击直接进聊天室（不经群设置页）。
class GroupListPage extends StatefulWidget {
  const GroupListPage({super.key});

  @override
  State<GroupListPage> createState() => _GroupListPageState();
}

class _GroupListPageState extends State<GroupListPage> {
  final _searchCtrl = TextEditingController();
  List<ImGroup> _groups = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final groups = await ImApi.getGroupList();
      if (!mounted) return;
      // 过滤已退群（历史群不展示，对齐 H5 isGroupQuit）
      setState(() => _groups =
          groups.where((g) => !g.quit).toList());
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

  List<ImGroup> get _filtered {
    final kw = _searchCtrl.text.trim().toLowerCase();
    if (kw.isEmpty) return _groups;
    return _groups
        .where((g) => g.name.toLowerCase().contains(kw))
        .toList();
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
            child: _loading && _groups.isEmpty
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
        child: Column(
          children: [
            SizedBox(
              height: 64,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_ios_new, size: 22),
                    color: colors.surfaceText,
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                  Expanded(
                    child: Text(
                      '群聊',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                        color: colors.surfaceText,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // 搜索框（本地过滤群名）
            Container(
              height: 36,
              margin: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              decoration: BoxDecoration(
                color: colors.card,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Row(
                children: [
                  const SizedBox(width: 13),
                  Icon(Icons.search, size: 22, color: colors.muted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: _searchCtrl,
                      onChanged: (_) => setState(() {}),
                      decoration: InputDecoration(
                        hintText: '搜索群聊',
                        isCollapsed: true,
                        border: InputBorder.none,
                        hintStyle: TextStyle(fontSize: 15, color: colors.muted),
                      ),
                      style: TextStyle(fontSize: 15, color: colors.text),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildList(ThemeColors colors) {
    final list = _filtered;
    if (list.isEmpty) {
      return const EmptyState(label: '暂无群聊');
    }
    return RefreshIndicator(
      color: AppColors.lime,
      onRefresh: _load,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: list.length,
        separatorBuilder: (_, _) =>
            Divider(height: 1, indent: 82, color: colors.divider),
        itemBuilder: (context, i) {
          final g = list[i];
          return InkWell(
            // 点击直接进聊天室（对齐 H5：不经群设置页）
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ChatPage(
                  type: ImConversationType.group,
                  targetId: g.id,
                  title: g.name,
                  avatar: g.avatar,
                ),
              ),
            ),
            child: Container(
              color: colors.card,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  GroupAvatar(
                    groupId: g.id,
                    src: g.avatar,
                    name: g.name,
                    size: 46,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Text(
                      g.name.isEmpty ? '群聊${g.id}' : g.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 16, color: colors.text),
                    ),
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
